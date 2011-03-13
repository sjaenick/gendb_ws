package GENDB::Remote::Client::API;

=head1 NAME

GENDB::Remote::Client::API

=head1 DESCRIPTION

This package contains all the necessary functions to allow for remote job
execution using SOAP to communicate with a server.

=head2 Available methods

=over 4

=cut

use strict;
use warnings;
use GENDB::Remote::Client::Configuration;
use Scheduler qw(:JOB_FLAGS);
use base qw(Scheduler);

use GENDB::Remote::Client::WebServices;

=item * GENDB::Remote::Client::API B<new>($projectname, $toolname)

creates a new object and, if both $projectname and $toolname are provided,
initializes itself based on an L<GENDB::Remote::Client::Configuration>
object.

  RETURNS: the new object

=cut

sub new {
    my ($class, $project, $toolname) = @_;
    my $self = {};
    bless($self, $class);

    if ((defined($project)) && (defined($toolname))) {
        unless ($self->configure($project, $toolname)) {
            die __PACKAGE__.": Not configured for tool/project combination.\n";
        }
    }

    return $self;
}


=item * BOOL B<configure>($projectname, $toolname)

This method checks if the configuration contains the necessary values
to remotely execute a tool identified by $toolname belonging to the
project given in $projectname and configures a class instance accordingly.

  RETURNS: true, if a project/tool combination can be executed
           false, otherwise.

=cut

sub configure {
    my ($self, $project, $toolname) = @_;

    return 0 unless (defined($project));
    return 0 unless (defined($toolname)); 

    my $config = GENDB::Remote::Client::Configuration->new();

    # check if project exists
    my $proj_id = $config->get_project($project);
    unless (defined($proj_id)) { return 0; }

    # check if tool exists
    my $tool = $config->get_tool($toolname);
    unless (ref($tool) eq 'HASH') { return 0; }    

    # do we have an appropriate remote site?
    my $remote_site = $config->get_site($tool->{RemoteSite});
    unless (ref($remote_site) eq 'HASH') { return 0; }

    # check if project and tool may be used together
    my $t_ref = $config->project_tools($project);
    unless (ref($t_ref) eq 'ARRAY') { return 0; } # no tools at all
    my @tools = @$t_ref;
    my $found = 0;
    foreach my $tool_id (@tools) {
        if ($tool_id == $tool->{_id}) { $found = 1; last; }
    }
    unless ($found == 1) { return 0; }

    $self->{TOOL_ID} = $tool->{RemoteID};
    $self->{WSDLPATH} = $remote_site->{WSDL};
    $self->{POLL_INT} = $remote_site->{PollInterval} || 60;

    # set cert for client auth. might result in 'undef', if no auth is required.
    $ENV{HTTPS_CERT_FILE} = $remote_site->{CertFile};
    $ENV{HTTPS_KEY_FILE}  = $remote_site->{CertKeyFile};

    return 1;
}



=item * STRING B<run>($observation)

This method remotely recomputes the result that has lead to a specific
observation.

=cut

sub run {
    my ($class, $observation) =  @_;

    my $client = GENDB::Remote::Client::API->new();
    unless ($client->configure($observation->_master->get_property('project'), $observation->tool->name())) {
        die __PACKAGE__.": Not configured to run ".$observation->tool->name()."\n";
    }

    # extract basic attributes from observation
    my %basic;
    foreach (@{$observation->_attributes_info()}) {
        my %attr = %$_;
        if ($attr{type} =~ /(B|b)asic/ ) {
            my $name=$attr{name};
            my $value = $observation->$name();
            if (defined($value)) { $basic{$name} = $value; }
        }
    }

    my $input = $observation->tool->is_dna_input ? $observation->region->sequence() : $observation->region->aasequence();

    my $ws = GENDB::Remote::Client::WebServices->new();
    return $ws->run($client->_wsdl, $client->_toolid, $input, %basic);
}



=item * VOID B<add>(%seq_data)

This method adds input sequences to a job. Since the input sequences are internally
stored in a hash (i.e. prone to collisions), calling this method more than once will
not add further input sequences, but instead overwrite those defined with the first
call.

  seq_data: a hash containing unique identifiers (e.g. job ids) as keys
            and sequence data as values

=cut

sub add {
    my ($self, %seq_data) = @_;
    $self->{JOBS} = \%seq_data;
}


=item * BOOL B<submit>($submit_callback, $error_callback)

This method submits previously added jobs to a remote site where they are scheduled
for execution. 

  submit_callback: a callback function executed when all jobs have been 
                   submitted.

  error_callback: a callback executed with a job id as parameter when 
                   submitting a job fails.

  RETURNS: true on success, false otherwise.

=cut

sub submit {
    my ($self, $submit_callback, $error_callback) = @_;

    my %jobs = %{$self->{JOBS}};

    my @local_ids;
    my @input;

    foreach (keys %jobs) {
        push @local_ids, $_;
        push @input, $jobs{$_};
    }
  
    my $ws = GENDB::Remote::Client::WebServices->new();
    my $result = $ws->submit($self->{WSDLPATH}, $self->{TOOL_ID}, \@input);

    unless (defined($result)) {
        foreach (@local_ids) {
            &$error_callback($_);
        }
        return 0;
    }

    my @remote_job_ids = @{$result};

    # less/more IDs than jobs sent
    unless (scalar(@remote_job_ids) == scalar(@local_ids)) {
        $ws->cancel($self->{WSDLPATH}, \@remote_job_ids);
        foreach (@local_ids) {
            &$error_callback($_);
        }
        return 0;
    }

    # a hash translating remote ids to local job ids
    my %remote2local;
    while (my $remote = shift(@remote_job_ids)) { 
        my $local = shift(@local_ids);
        $remote2local{$remote} = $local;
   
    }
    $self->{_R2L} = \%remote2local;

    # let the caller know that the jobs have been submitted..
    &$submit_callback();

    return 1;
}


=item * VOID B<iterate>($finished_callback, $error_callback)

This method iterates over the list of submitted jobs, polling
for the results until a job has either finished or failed. The
method does not return unless all jobs have either finished or
failed.

  finished_callback: a callback invoked for each successfully finished 
                     job. The local job id and the job output are passed
                     as parameters.

  error_callback: a callback invoked for each failed job, getting the 
                     local job id as a parameter

=cut

sub iterate {
    my ($self, $finished_callback, $error_callback) = @_;

    my %remote2local = %{$self->{_R2L}};

    my $ws = GENDB::Remote::Client::WebServices->new();

    # poll for results
    while (keys %remote2local) {

        sleep($self->{POLL_INT}); # removing this line considered harmful

        my @unfinished = keys %remote2local;
        my $status_result;

        $status_result = $ws->status($self->{WSDLPATH}, \@unfinished);

        unless (defined($status_result)) {
            foreach my $remote_id (@unfinished) {
                my $local_id = $remote2local{$remote_id};
                &$error_callback($local_id);
            }
            next;
        }

        my @status_response = @{$status_result};

        # response shorter than number of jobs we asked for
        unless (scalar(@status_response) == scalar(@unfinished)) {
            foreach my $remote_id (@unfinished) {
                my $local_id = $remote2local{$remote_id};
                &$error_callback($local_id);
            }
        }


        my %rjob2status = %{$self->_a2h(\@unfinished, \@status_response)};

        foreach my $rjob (@unfinished) {
            my $job_status = $rjob2status{$rjob};
            my $local_job = $remote2local{$rjob};

            if ($job_status eq JOB_FINISHED) {
                delete $remote2local{$rjob};
                my $output = $self->_get_result($rjob);

                unless (defined($output)) { 
                    &$error_callback($local_job); 
                } else {
                    &$finished_callback($local_job, $output);
                }

            } elsif ($job_status eq JOB_FAILED) { 
                delete $remote2local{$rjob};
                &$error_callback($local_job);

            } elsif ($job_status eq JOB_UNKNOWN) {
                delete $remote2local{$rjob};
                &$error_callback($local_job);
            }
        }
    } # end of big loop

}


sub _wsdl {
    my ($self) = @_;
    return $self->{WSDLPATH};
}


sub _toolid {
    my ($self) = @_;
    return $self->{TOOL_ID};
}


sub _a2h { 
    my ($self, $a1, $a2) = @_;
    my @a = @{$a1};
    my @b = @{$a2};
    my %hash;
   
    foreach my $x (@a) {
        $hash{$x} = shift(@b);
    }
    return \%hash;
}


sub _get_result {
    my ($self, $id) = @_;
    my @ids = ( $id );

    my $ws = GENDB::Remote::Client::WebServices->new();
    my $result = $ws->result($self->{WSDLPATH}, \@ids);
    
    unless (defined($result)) {
        return undef;
    }

    my @status = @{$result};

    my %res = %{$status[0]};

    # undef for failed jobs
    return $res{output};
}


1;

=back
