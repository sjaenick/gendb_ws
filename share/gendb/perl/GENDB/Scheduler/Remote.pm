package GENDB::Scheduler::Remote;

=head1 NAME

GENDB::Scheduler::Remote

=head1 DESCRIPTION

This module executes jobs on a remote location by extracting the input data and
submitting both input data and information about the tool to be run to
the remote site using SOAP.

=head2 Available methods

=over 4

=cut

use strict;
use warnings;
use Scheduler qw(:JOB_FLAGS);
use IO::Scalar;
use GENDB::Remote::Client::API;
use base qw(Scheduler);



=item * BOOL B<available>()

Checks whether this scheduler class can be used. Since this scheduler implementation is not based on any external resource it is always available.

  RETURNS: a boolean indicating whether this scheduler may be used

=cut

sub available {
    return 1;
}

=item * BOOL B<can_tool>(tool)

Checks whether this scheduler class can be used to execute a specific tool.

  RETURNS: a boolean indicating whether this scheduler is capable of
  executing a specific tool

=cut

sub can_tool {
    my ($class, $tool) = @_;

    my $proj_name = $tool->_master->get_property('project');

    my $client = GENDB::Remote::Client::API->new();
    return $client->configure($proj_name, $tool->name());
}



=item * BOOL B<job_based>()

Scheduler may work either based on command line or on L<GENDB::DB::Job> tool objects.

  RETURNS: a boolean indicating whether this scheduler is job based.
  Always returns true for this scheduler class.

=cut

sub job_based {
    return 1;
}


=item * GENDB::Scheduler::Remote B<new>(parameters)

Constructs a new scheduler object. All parameters are passed to the L<Scheduler> super class.

  parameters: see L<scheduler>
  RETURNS: the new scheduler object

=cut

sub new {
    my ($class, %parameters) = @_;

    my $self = $class->SUPER::new(%parameters);
    $self->{jobs} = [];
    bless $self, ref $class || $class;

    return $self;
}



=item * VOID B<execute>($annotate, $project)

This method can be used to execute the jobs.

  $annotate: a boolean flag indicating whether the automatic annotator of a tool should be started after a tool run has finished
  $project: the name of the project the jobs are run in. This information is required by some tool implementations and the L<GENDB::DB::Job> interface.

=cut

sub execute {
    my ($self, $annotate, $project_name) = @_;

    $self->{ANNOTATE} = $annotate;
    $self->{PROJECT} = $project_name;

    my @joblist = @{$self->{jobs}};
    my $toolname = $joblist[0]->tool->name();

    # we create two hashes here - %jobs maps local job ids to their
    # input, %job_by_id maps local ids to the jobs 
    #
    my %jobs;
    my %job_by_id;
    foreach my $job (@joblist) {
        my ($name, $sequence) = $job->tool->scheduled_prepare($job);
        my $local_id = $job->id();
        $jobs{$local_id} = $sequence;
        $job_by_id{$local_id} = $job;
    }

    $self->{JOB_BY_ID} = \%job_by_id;

    my $client = GENDB::Remote::Client::API->new();
    $client->configure($project_name, $toolname);
    $client->add(%jobs);

    my $submit_ret = $client->submit(sub { $self->_on_submit(@_); }, sub { $self->_on_error(@_); });

    if ($submit_ret == 1) {
        $client->iterate(sub { $self->_on_finished(@_); }, sub { $self->_on_error(@_); });
    }

    # flush caches to reduce memory footprint
    $joblist[0]->tool->_master->flush_class_cache('Observation');
}



=item * BOOL B<can_cancel>()

Scheduler classes may implement a mechanism for cancelling submitted jobs. The I<can_cancel> method can be used to check whether this ability is implemented in a scheduler implementation.

Warning: Most (none ?) implementations currently B<DO NOT> support cancelling of jobs.

  RETURNS: a boolean indicating whether this scheduler can cancel jobs.

=cut

sub can_cancel {
    return 0;
}


sub _run_annotator {
   my ($self, $job) = @_;

   my $tool = $job->tool();

   if (ref $tool->auto_annotator && $self->{ANNOTATE}) {
       eval {
           $tool->auto_annotate($job->region, $self->{PROJECT});
           # we're done
           $job->finished($self->{PROJECT});
       };

       # check eval result
       if ($@) {
           $self->log("Error: auto-annotating in job ".$job->id." for project ". $self->{PROJECT} ." failed: $@\n");
           $job->failed($self->{PROJECT});
           $job->error_message("Annotate failed: $@");
       }
   } else {
       # we're done
       $job->finished($self->{PROJECT});
   }
}


sub _on_submit {
    my ($self) = @_;

    my @joblist = @{$self->{jobs}};

    # mark jobs as running
    foreach my $job (@joblist) {
        $job->submitted($self->{PROJECT});
        $job->running($self->{PROJECT});
    }
}


sub _on_finished {
    my ($self, $local_id, $output) = @_;

    my %jobs = %{$self->{JOB_BY_ID}};
    my $job = $jobs{$local_id};

    my $OUT = IO::Scalar->new(\$output);

    eval {
        $job->tool->scheduled_parse($job, $OUT) &&
        $job->finished($self->{PROJECT});
    };
    if ($@) { 
        $job->failed($self->{PROJECT}); 
    } else {
        $self->_run_annotator($job);
    }


}


sub _on_error {
    my ($self, $local_id) = @_;

    my %jobs = %{$self->{JOB_BY_ID}};
    my $job = $jobs{$local_id};

    $job->failed($self->{PROJECT});
}


1;

=back
