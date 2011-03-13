package GENDB::Remote::Server::QMGR;

=head1 NAME

GENDB::Remote::Server::QMGR

=head1 DESCRIPTION

This module executes jobs using a configurable scheduler class. Running
as a daemon in the background, it scans the job queue database for newly
submitted jobs upon receiving a keyboard interrupt signal (SIGINT), 
collects those jobs and forks a child process to execute them. The scheduler
child process will exit when all jobs assigned to it have either successfully
completed or failed and their results been saved to the job queue.

=head1 CONFIGURATION

See L<GENDB::Remote::Server::Configuration> for an explanation and example
of the required configuration.

=head1 Available methods

=over 4

=cut

use strict;
use warnings;

use GENDB::Remote::Server::Configuration;
use GENDB::Remote::Server::JobQueue qw(JOB_CANCEL_PENDING JOB_CANCELLED);
use GENDB::Remote::Server::Tool;
use Scheduler qw(:JOB_FLAGS);

use POSIX;
use IO::Select;
use File::Temp;

=item * GENDB::Remote::Server::QMGR B<new>($configfile)

This method constructs the new object and forks a process
in the background which then initializes itself based on the
configuration file given as a parameter.

  RETURNS: the new object

=cut

sub new {
    my ($class, $cfgfile) = @_;
    my $self = { _SIGNALLED => 0 };
    bless($self, $class);

    my $pid = fork();

    unless (defined($pid)) { $self->_log_and_die( "Cannot fork(), exiting..\n"); }

    if ($pid != 0) {    # parent
        return $self;
    } else {            # child
        my $pid2 = fork();
        unless (defined($pid2)) { $self->_log_and_die( "Cannot fork(), exiting..\n"); }

        if ($pid2 != 0) { exit; }  # 1st child exiting to avoid zombies

        setsid() or die "cannot setsid()\n";
        chdir('/');
        open STDIN,  '</dev/null';
        open STDOUT, '>/dev/null';
        open STDERR, '>/dev/null';
        $| = 1;  # autoflush
        $0 = 'qmgr'; # try to set daemon name
        $SIG{INT} = sub { $self->_wakeup };
        $SIG{USR1} = sub {  $self->_log("JobQueue recreated, reconnecting.."); $self->_initialize };
        $SIG{TERM} = sub { $self->_cleanup };
        $SIG{CHLD} = sub { $self->_update_job_count };

        $self->{_CFG_FILE} = $cfgfile;

        $self->_initialize();

        # keep track of the number of (submitted && unfinished) jobs 
        # key = scheduler_pid, value = #jobs
        my %sched_jobs = ();
        $self->{_SCHEDULER_JOBS} = \%sched_jobs;

        $self->_create_pidfile();

        $self->_log("daemon startup - performing initial queue scan.\n");
        $self->_submit_pending();

        while (1) { 

            # block until SIGINT is received.
            IO::Select->select(undef,undef,undef);

            if ($self->{_SIGNALLED} == 1) {
                $self->{_SIGNALLED} = 0;

                if ($self->_job_count() <= $self->_max_jobs()) {
                    $self->_log("received SIGINT, processing queue\n");
                    $self->_submit_pending();
                } else {
                    $self->_log("Too many unfinished jobs (".$self->_job_count()."), ignoring wakeup request.\n");
                }
                $self->_cancel_pending();
            }
        }
    }
}


sub _submit_pending {
    my ($self) = @_;
    local $SIG{INT} = 'IGNORE'; # temporarily disable the sighandler

    # get queued jobs and mark as submitted
    my @queued_jobs = @{$self->_jobqueue->by_state(JOB_QUEUED)};

    $self->_log("queue scan found ". scalar(@queued_jobs)  ." jobs\n");

    if ((scalar(@queued_jobs)) == 0) {
        return;
    } 

    foreach (@queued_jobs) { 
        $self->_jobqueue->set_state($_->{job_id}, JOB_RUNNING);
        eval {
            $self->_accwrite($_->{tool}, $_->{client_cert});
        };
        # we wont execute jobs if we cant save accounting information
        if ($@) {
            $self->_jobqueue->set_state($_->{job_id}, JOB_FAILED);
        }
    }

    # sort the jobs into "slots" by tool
    my %scheduler_slots;
    foreach my $job (@queued_jobs) {
        my $tool = $job->{tool};
        my @slot_queue;

        my $queue_ref = $scheduler_slots{$tool};
        if (defined($queue_ref)) {
            @slot_queue = @$queue_ref;
        }

        push @slot_queue, $job;
        $scheduler_slots{$tool} = \@slot_queue;
    }

    foreach my $slot (keys %scheduler_slots) {
        my $scheduler_pid = $self->_start_scheduler_process($scheduler_slots{$slot});
        if ($scheduler_pid != 0) {  # this is the returning parent
            my %scheduler_jobs = %{$self->_scheduler_jobs()};
            my @job_count = @{$scheduler_slots{$slot}};
            $scheduler_jobs{$scheduler_pid} = scalar(@job_count);
            $self->{_SCHEDULER_JOBS} = \%scheduler_jobs;
        }
    }
}


sub _start_scheduler_process {
    my ($self, $joblist) = @_;

    my @jobs = @$joblist;

    my $toolid = $jobs[0]{tool};

    my $tool = GENDB::Remote::Server::Tool->init($toolid);

    unless ($tool->available()) {
        foreach (@jobs) {
            $self->_log("Error - Unknown Tool ID, failing job $_->{job_id}.\n");
        }
        $self->_set_jobs_failed(\@jobs);
        return 0;
    }
    
    my $cmdline = $tool->command_line();
    my $toolname = $tool->name();
    my $sched_class = $tool->scheduler_class();
    my $schedopts = $tool->scheduler_options();
    $tool = undef; # don't keep the database handle across the fork()

    # create a child process for the scheduler
    my $sched_pid = fork();

    unless (defined($sched_pid)) { 
        $self->_log("cannot fork() scheduler process, failing jobs..\n"); 
 
        foreach (@jobs) {
            $self->_log("failing job $_->{job_id}.\n");
        }
        $self->_set_jobs_failed(\@jobs);
        return 0;
    }

    if ($sched_pid != 0) { # parent
        $self->_log("created scheduler instance pid $sched_pid for tool $toolname\n");
        return $sched_pid;   # parent returns, child continues
    }

    $SIG{INT} = 'IGNORE';
    $SIG{TERM} = 'IGNORE';

    # we have to _initialize again() to get new DBI handles after forking
    $self->_initialize();

    $self->_log("Using ".$sched_class." (options: ".$schedopts.") for tool ".$toolname.".\n");

    eval "use $sched_class;";
    if ($@) {
        $self->_set_jobs_failed(\@jobs);
        $self->_log_and_die( "Cannot load ".$sched_class." scheduler\n");
    }

    unless ($sched_class->available()) {
        $self->_set_jobs_failed(\@jobs);
        $self->_log_and_die($sched_class." scheduler isn't available\n");
    }

    my @command = split(/ /, $cmdline);
 
    my $scheduler = $sched_class->new(input_placeholder => '_FASTA_INPUT_',
			       		     output_placefolder => '_OUTPUT_',
				             temp_dir => $self->_tempdir(),
				       	     commandline => \@command);

    if ($scheduler->can("set_native_option")) {
        $scheduler->set_native_option($schedopts) if ($schedopts);
    }

    if ($scheduler->can("job_based")) {
        if ($scheduler->job_based) {
            $self->_set_jobs_failed(\@jobs);
            $self->_log_and_die( "Cannot use a job based scheduler\n");
        }
    } else {
        $self->_set_jobs_failed(\@jobs);
        $self->_log_and_die( "Refusing to use scheduler with non-standard API\n");
    }

    if ($scheduler->can("support_asynchronous")) {
        if (!($scheduler->support_asynchronous)) {
            $self->_set_jobs_failed(\@jobs);
            $self->_log_and_die( "Need an asynchronous scheduler\n");
        }
    } else {
        $self->_set_jobs_failed(\@jobs);
        $self->_log_and_die( "Refusing to use scheduler with non-standard API\n");
    }


    foreach (@jobs) {
        $scheduler->add_input_sequence($_->{job_id}, $_->{input});
    }

    eval {
        $scheduler->submit();
    };
    if ($@) {
        $self->_set_jobs_failed(\@jobs);
    }

    $scheduler->iterate(sub { $self->_on_job_finished(@_); }, sub { $self->_on_job_failed(@_); });

    $self->_log("scheduler instance pid $$ done and exiting\n");
    exit 0; # child process exiting
}


sub _on_job_finished {
    my ($self, $id, $fh) = @_;

    my $output;

    if (ref $fh) {
        local $/ = undef;
        $output = <$fh>;
    } else {
        # job finished, but cannot retrieve result
        $self->_jobqueue->set_state($id, JOB_FAILED);
        return 1;
    }

    my $out = File::Temp->new(DIR => $self->{_OUTPUTDIR},
                              TEMPLATE => "output_XXXXXXXX",
                              UNLINK => 0);
    print $out $output;
    my $out_fname = $out->filename();
    $out->close() or $self->_log_and_die("Couldn't close file handle on $out_fname\n");

    $self->_jobqueue->set_output_file($id, $out_fname);
    $self->_jobqueue->set_state($id, JOB_FINISHED);

    return 1;
}


sub _on_job_failed {
    my ($self, $id, $errmsg) = @_;

    $self->_jobqueue->set_state($id, JOB_FAILED);

    if (defined($errmsg)) {
        my $err = File::Temp->new(DIR => $self->{_OUTPUTDIR},
                                  TEMPLATE => "error_XXXXXXXX",
                                  UNLINK => 0);
        print $err $errmsg;
        my $err_fname = $err->filename();
        $err->close() or $self->_log_and_die("Couldn't close file handle on $err_fname\n");

        $self->_jobqueue->set_error_file($id, $err_fname);
    }

    return 1;
}


sub _cancel_pending {
    my ($self) = @_;
    local $SIG{INT} = 'IGNORE'; # temporarily disable the sighandler

    my @jobs = @{$self->_jobqueue->by_state(JOB_CANCEL_PENDING)};

    # mark jobs as cancelled
    foreach (@jobs) { $self->_jobqueue->set_state($_, JOB_CANCELLED); }

    # wrt DRMAA, we cannot cancel jobs that have already been scheduled
    # for execution, so we can only cancel pending jobs so far..

    return 1;
}


sub _update_job_count {
    my ($self) = @_;
    my $child = waitpid(-1, WNOHANG);

    my %sched_jobs = %{$self->_scheduler_jobs()};
    delete $sched_jobs{$child};
    $self->{_SCHEDULER_JOBS} = \%sched_jobs;
}


sub _job_count {
    my ($self) = @_;
    my $count = 0;
    my %schedjobs = %{$self->_scheduler_jobs()};
    foreach (keys %schedjobs) {
        $count += $schedjobs{$_};
    }

    return $count;
}


sub _scheduler_jobs {
    my ($self) = @_;
    return $self->{_SCHEDULER_JOBS};
}


sub _cfgfile {
    my ($self) = @_;
    return $self->{_CFG_FILE};
}


sub _jobqueue {
    my ($self) = @_;
    return $self->{_JOBQUEUE};
}


sub _tempdir {
    my ($self) = @_;
    return $self->{_TEMPDIR};
}


sub _wakeup {
    my ($self) = @_;
    $self->{_SIGNALLED} = 1;
}


sub _cleanup {
    my ($self) = @_;
    $self->_log("received SIGTERM, exiting..\n");
    unlink($self->{_PIDFILE}); 
    exit 0;
}


sub _create_pidfile {
    my ($self) = @_;

    my $pidfile = $self->{CONFIG}->block(Process => "QMGR")->get("PidFile");
    $self->{_PIDFILE} = $pidfile;

    unless (defined($pidfile)) {
        $self->_log_and_die("Configuration error - Missing PidFile directive.\n");
    }

    open(PID, "> $pidfile") || $self->_log_and_die("cannot create pid file\n");
    print PID $$;
    close PID;
    $self->_log("qmgr started\n");
}


sub _max_jobs {
    my ($self) = @_;
    return $self->{_MAX_JOBS};
}


sub _set_jobs_failed {
    my ($self, $jobs_ref) = @_;
    my @jobs = @$jobs_ref;
    foreach(@jobs) {
        $self->_jobqueue->set_state($_->{job_id}, JOB_FAILED);
    }
}


sub _initialize {
    my ($self) = @_;

    $self->{CONFIG} = GENDB::Remote::Server::Configuration->new($self->_cfgfile());
    unless (defined($self->{CONFIG})) {
        $self->_log_and_die("Cannot parse config file ".$self->_cfgfile.".\n");
    }

    $self->{_OUTPUTDIR} = $self->{CONFIG}->block(Process => "QMGR")->get("OutputDirectory");
    $self->{_JOBQUEUE} = GENDB::Remote::Server::JobQueue->new($self->{CONFIG}->get("JobQueueDB"));
    $self->{_MAX_JOBS} = $self->{CONFIG}->block(Process => "QMGR")->get("MaxSubmittedJobs");
    $self->{_TEMPDIR} = $self->{CONFIG}->get("TempDirectory");

    unless (defined($self->{_OUTPUTDIR})) {
        $self->_log_and_die("Configuration error - Missing OutputDirectory directive.\n");
    }
    unless ((-d $self->{_OUTPUTDIR}) && (-w $self->{_OUTPUTDIR})) {
        $self->_log_and_die($self->{_OUTPUTDIR}. " is not a directory or cannot be written to.\n");
    }
    
    unless (defined($self->{_MAX_JOBS})) {
        $self->_log_and_die("Configuration error - Missing MaxSubmittedJobs directive.\n");
    }
    unless ($self->{_MAX_JOBS} =~ /\d+/ ) {
        $self->_log_and_die("Configuration error - MaxSubmittedJobs not numeric.\n");
    }

    unless (defined($self->{_TEMPDIR})) {
        $self->_log_and_die("Configuration error - Missing TempDirectory directive.\n");
    }
    unless ((-d $self->{_TEMPDIR}) && (-w $self->{_TEMPDIR})) {
        $self->_log_and_die($self->{_TEMPDIR}. " is not a directory or cannot be written to.\n");
    }

    return 1;
}

sub _accwrite {
    my ($self, $toolid, $cert) = @_;

    return unless (defined($toolid));
    return unless (defined($cert));

    my $logfile = $self->{CONFIG}->get("AccountingFile");
    return unless (defined($logfile));

    open(F, ">> $logfile") or $self->_log_and_die( "Could not write to accounting file.\n");
    print F strftime("%Y-%m-%d %H:%M:%S  ", localtime) . "EXEC: Tool: " .$toolid. " User: ".$cert." \n";
    close(F);
}


sub _log {
    my ($self, $logmsg) = @_;

    return unless (defined($logmsg));

    my $logfile = $self->{CONFIG}->block(Process => "QMGR")->get("LogFile");

    unless (defined($logfile)) {
        die __PACKAGE__.": Configuration error - Missing LogFile directive.\n";
    }

    $logmsg = strftime("%Y-%m-%d %H:%M:%S  ", localtime) . $logmsg;
    if (!( $logmsg =~ /.*\n/ )) { $logmsg .= "\n"; }

    open(F, ">> $logfile") or die "Could not write to log file.\n";
    print F $logmsg;
    close(F);
}


sub _log_and_die {
    my ($self, $logmsg) = @_;

    return unless (defined($logmsg));

    my $logfile = $self->{CONFIG}->block(Process => "QMGR")->get("LogFile");

    unless (defined($logfile)) {
        die __PACKAGE__.": Configuration error - Missing LogFile directive.\n";
    }

    $logmsg = strftime("%Y-%m-%d %H:%M:%S  ", localtime) . $logmsg;

    open(F, ">> $logfile");
    print F $logmsg;
    close(F);
    die $logmsg;
}


1;

=back

=head1 SEE ALSO

L<GENDB::Remote::Server::Configuration>

L<GENDB::Remote::Server::JobQueue>

