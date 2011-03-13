package GENDB::Remote::Server::JobQueue;

=head1 NAME

GENDB::Remote::Server::JobQueue

=head1 DESCRIPTION

This package provides persistent storage for all job-related information in a
SQLite database. 

Using e.g. a Web Service (L<GENDB::Remote::Server::RequestHandler>), new jobs
can be entered into the database, job results can be fetched or unneeded jobs
cancelled (if supported by the underlying execution system).

On the other side, the JobQueue will be regularly examined (e.g. by L<GENDB::Remote::Server::QMGR>)
for newly submitted jobs, which are then prepared for execution and handed over to the
execution system until they either fail or finish.


=head2 I<JobQueue> table

 +---------------------------------------------------+
 | job_id:         INTEGER PRIMARY KEY AUTOINCREMENT |
 | tool:           INTEGER NOT NULL                  |
 | status:         INTEGER                           |
 | client_cert:    TEXT                              |
 | input:          TEXT                              |
 | output_file:    TEXT                              |
 | error_file:     TEXT                              |
 | result_fetched: TEXT                              |
 +---------------------------------------------------+

All methods manipulating data in this package die() if the underlying SQLite
database file becomes inaccessible or corrupted.

=head1 Available methods

=over 4

=cut

use strict;
use warnings;
use base qw (Exporter);

use DBD::SQLite;
use Scheduler qw(:JOB_FLAGS);
use POSIX qw(strftime);

use GENDB::Remote::AuthToken::X509;


# FIXME: this should be moved to Scheduler.pm
our(@EXPORT_OK);
@EXPORT_OK = qw(JOB_CANCEL_PENDING JOB_CANCELLED);

use constant JOB_CANCEL_PENDING => 11;
use constant JOB_CANCELLED => 12;

use constant SIGUSR1 => 16;


=item * GENDB::Remote::Server::JobQueue B<new>($filename)

This method creates a new object and loads and parses the SQLite
database specified as argument. If the database file doesn't exist,
it is newly created, if directory permissions allow.

  RETURNS: the new object

=cut

sub new {
    my ($class, $file) = @_;

    unless (defined($file)) {
        die __PACKAGE__.": Missing filename.\n";
    }
    my $self = {db_file => $file};
    bless($self, $class);

    if (! -f $file) {
        $self->_create_database();
        # db file disappeared, notify qmgr to re-initialize
        $self->_signal_qmgr(SIGUSR1);
    } elsif (! -r $file) {
        die __PACKAGE__.": unable to read existing database file $file, aborting.\n";
    } elsif (! -w $file) {
        die __PACKAGE__.": unable to write to existing database file $file, aborting.\n";
    } else {
        $self->_load_database();
    }
   
    return $self;
}

=item * INTEGER B<job_status>($job_id)

This method can be used to query the status of a job. 
See L<Scheduler> for a list of possible status codes and their meanings.

  RETURNS: an integer representing the current job state

=cut

sub job_status {
   my ($self, $job_id) = @_;

    return JOB_UNKNOWN unless (defined($job_id));

    my $dbh = $self->_dbh;

    my $token = GENDB::Remote::AuthToken::X509->new();

    my $sql = sprintf ('SELECT status FROM JobQueue WHERE job_id="%d"
                        AND client_cert="%s"', $job_id, $token->auth_token());
    my $sth = $dbh->prepare($sql);
    $sth->execute();

    my $status = $sth->fetchrow_array();
    $sth->finish();

    unless (defined($status)) {
            return JOB_UNKNOWN;
    }

    return $status;
}

=item * VOID|INTEGER B<submit_job>($tool_id, $input)

Use this method to submit a single job for execution. 

  RETURNS: an integer job id 
           undef, if one of the arguments is missing

=cut

sub submit_job {
    my ($self, $tool, $input) = @_;

    return unless (defined($tool));
    return unless (defined($input));

    my $token = GENDB::Remote::AuthToken::X509->new();
    my $dbh = $self->_dbh;

    my $sql = sprintf ('INSERT INTO JobQueue (tool, status, client_cert,
                        input) VALUES ("%d", "%d", "%s", "%s")',
                        $tool, JOB_QUEUED, $token->auth_token(), $input);

    unless ($dbh->do($sql)) {
        die __PACKAGE__.": could not write to JobQueue, error: ".$dbh->errstr();
    }

    my $job_id = $dbh->func('last_insert_rowid');

    return $job_id;
}

=item * STRING|VOID B<get_result>($job_id)

This method can be used to get the location of a jobs output file.

  RETURNS: the file name containing the job output
           undef, if no or an invalid job id was supplied 

=cut

sub get_result {
    my ($self, $job_id) = @_;

    return unless (defined($job_id));

    my $token = GENDB::Remote::AuthToken::X509->new();
    my $dbh = $self->_dbh;

    my $sql = sprintf ('SELECT output_file FROM JobQueue WHERE job_id="%d"
                        AND client_cert="%s"', $job_id, $token->auth_token());
    my $sth = $dbh->prepare($sql);
    $sth->execute();

    my $result = $sth->fetchrow_array();
    $sth->finish();

    unless (defined($result)) {
            # no job associated with job_id in JobQueue or
            # job hasn't finished yet.
            return undef;
    }

    # save a timestamp
    my $now = strftime("%Y-%m-%d %H:%M", localtime);
    $sql = sprintf ('UPDATE JobQueue SET result_fetched="%s"
                     WHERE job_id="%d"', $now, $job_id);
    $dbh->do($sql);

    return $result;
}


=item * STRING|VOID B<get_error>($job_id)

This method can be used to get the location of a failed jobs error file.

  RETURNS: the file name containing the error message
           undef, if no or an invalid job id was supplied

=cut

sub get_error {
    my ($self, $job_id) = @_;

    return unless (defined($job_id));

    my $token = GENDB::Remote::AuthToken::X509->new();
    my $dbh = $self->_dbh;

    my $sql = sprintf ('SELECT error_file FROM JobQueue WHERE job_id="%d"
                        AND client_cert="%s"', $job_id, $token->auth_token());
    my $sth = $dbh->prepare($sql);
    $sth->execute();

    my $result = $sth->fetchrow_array();
    $sth->finish();

    unless (defined($result)) {
            # no job associated with job_id in JobQueue
            return undef;
    }

    return $result;
}

=item * VOID B<cancel_job>($job_id)

This method can be used to inform the underlying execution system that the
result for a job is no longer interesting and the job can be cancelled.

=cut

sub cancel_job {
    my ($self, $job_id) = @_;

    return unless (defined($job_id));

    my $token = GENDB::Remote::AuthToken::X509->new();
    my $dbh = $self->_dbh;

    my $sql = sprintf ('UPDATE JobQueue SET status="%d" WHERE job_id="%d"
                        AND client_cert="%s"', JOB_CANCEL_PENDING, $job_id, $token->auth_token());

    unless ($dbh->do($sql)) {
        die __PACKAGE__.": could not update JobQueue, error: ".$dbh->errstr();
    }
}


=item * REF ON ARRAY|VOID B<by_state>($job_state)

This method can be used to query the database for all jobs in a given state.

  RETURNS: reference on an array containing a reference on a hash for each
           job that has its state currently set to job_state

           undef, if no job_state was supplied as an argument

=cut

sub by_state {
    my ($self, $state) = @_;

    return unless (defined($state));
    my $dbh = $self->_dbh;

    my $sql = sprintf ('SELECT * FROM JobQueue WHERE status="%d" 
                        ORDER BY tool;', $state);
    my $sth = $dbh->prepare($sql);
    $sth->execute();

    my @jobs;

    while (my $job = $sth->fetchrow_hashref()) {
        unless (ref($job) eq "HASH") {
            $sth->finish();
            $dbh->disconnect();
            die __PACKAGE__.": unable to read JobQueue table, error: ".$dbh->errstr();
        }
        push @jobs, $job;
    }
    $sth->finish();

    return \@jobs;
}

=item * VOID B<set_state>($job_id, $job_state)

Use this method to update the state of a single job identified by its job id in
the database.

=cut

sub set_state {
    my ($self, $job_id, $state) = @_;

    return unless (defined($job_id));
    return unless (defined($state));

    my $dbh = $self->_dbh;

    my $sql = sprintf ('UPDATE JobQueue SET status="%d" WHERE job_id="%d"', $state, $job_id );

    unless ($dbh->do($sql)) {
        die __PACKAGE__.": could not update JobQueue, error: ".$dbh->errstr();
    }
}

=item * VOID B<set_output_file>($job_id, $filename)

This method is used by the execution system to to specify the location of the
output file once a job has finished, in order to allow a client to retrieve the
output the job has generated.

=cut

sub set_output_file {
    my ($self, $job_id, $outfile) = @_;

    return unless (defined($job_id));
    return unless (defined($outfile));

    my $dbh = $self->_dbh;

    my $sql = sprintf ('UPDATE JobQueue SET output_file="%s" WHERE job_id="%d"', $outfile, $job_id );

    unless ($dbh->do($sql)) {
        die __PACKAGE__.": could not update JobQueue, error: ".$dbh->errstr();
    }
}


=item * VOID B<set_error_file>($job_id, $filename)

This method is used by the execution system to to specify the location of the
error file if a job has failed and generated an error message.

=cut

sub set_error_file {
    my ($self, $job_id, $errfile) = @_;

    return unless (defined($job_id));
    return unless (defined($errfile));

    my $dbh = $self->_dbh;

    my $sql = sprintf ('UPDATE JobQueue SET error_file="%s" WHERE job_id="%d"', $errfile, $job_id );

    unless ($dbh->do($sql)) {
        die __PACKAGE__.": could not update JobQueue, error: ".$dbh->errstr();
    }
}


sub _create_database {
    my ($self) = @_;

    my $dbh = DBI->connect('dbi:SQLite:dbname='.$self->_db_file, '', '',
                           {AutoCommit => 1,
                            RaiseError => 1});

    unless (ref($dbh)) {
        die __PACKAGE__.": unable to create database: ".$dbh->errstr();
    }

    # set the permission of the database file
    chmod (0600, $self->_db_file);

    # set the auto-vacuum pragma
    $dbh->do('PRAGMA auto_vacuum = 1');

    unless ($dbh->do('CREATE TABLE JobQueue (job_id INTEGER PRIMARY KEY AUTOINCREMENT,
                      tool INTEGER NOT NULL, status INTEGER, 
                      client_cert TEXT, input TEXT, output_file TEXT, 
                      error_file TEXT, result_fetched TEXT)')) {
        die __PACKAGE__.": unable to create JobQueue table: ".$dbh->errstr;
    }
    unless ($dbh->do('CREATE UNIQUE INDEX jobid_index ON JobQueue (job_id)')) {
        die __PACKAGE__.": unable to create Index on JobQueue table: ".$dbh->errstr;
    }

    # cleanup if something went wrong
    if ($@) {
        if (ref($dbh)) {
            $dbh->disconnect();
        }
        unlink $self->_db_file;
        die $@;
    }
    $self->{dbh} = $dbh;
}


sub _load_database {
    my ($self) = @_;

    my $dbh = DBI->connect('dbi:SQLite:dbname='.$self->_db_file, '', '',
                           {AutoCommit => 1,
                            RaiseError => 1});
    unless (ref($dbh)) {
        die __PACKAGE__.": unable to load database: ".$dbh->errstr();
    }
    $self->{dbh} = $dbh;

    my $sth = $dbh->prepare('SELECT * FROM JobQueue');
    $sth->execute();
    
    my @jobs;

    while (my @job = $sth->fetchrow_array()) {
        unless (scalar(@job)) {
            $sth->finish();
            $dbh->disconnect();
            die __PACKAGE__.": unable to read JobQueue table, error: ".$dbh->errstr();
        }
        push @jobs, \@job;
    }
    $sth->finish();

    $self->{JOBS} = \@jobs;
}

sub _signal_qmgr {
    my ($self, $signal) = @_;

    return unless ((defined($signal)) && ($signal =~ /\d+/ ));

    my $config = GENDB::Remote::Server::Configuration->new($self->_configfile());
    my $pidfile = $config->block(Process => "QMGR")->get("PidFile");

    unless (defined($pidfile)) {
        die __PACKAGE__.": Configuration error - missing PidFile directive.\n";
    }

    # qmgr might be down - but we still accept new jobs
    return unless ((-e $pidfile) && (-r $pidfile));

    open (PID, "< $pidfile") or return;
    my $pid;
    {
      local $/ = undef;  # read entire file
      $pid = <PID>;
    }
    close(PID);

    return unless ((defined($pid)) && ($pid =~ /\d+/ ));

    kill($signal, $pid);
}

sub _configfile {
    return $ENV{gendb_VAR_DIR}.'/server.config';
}

# getter method for the database handle
sub _dbh {
    return $_[0]->{dbh};
}

# helper access methods
sub _db_file {
    return $_[0]->{db_file};
}

1;

=back
