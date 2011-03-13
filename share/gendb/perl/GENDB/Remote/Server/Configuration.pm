package GENDB::Remote::Server::Configuration;

=head1 NAME

GENDB::Remote::Server::Configuration

=head1 DESCRIPTION

This module provides access to the configuration data required by the
L<GENDB::Remote::Server::RequestHandler> and L<GENDB::Remote::Server::QMGR>
packages as well as the class-specific configuration for the
L<GENDB::Remote::Server::Tool> classes.

=head1 CONFIGURATION

The configuration file uses the same syntax that is also used by the
Apache web server. A valid configuration file may contain the following
statements:

 # (mandatory) location of the JobQueue SQLite database
 JobQueueDB /path/to/jobqueue

 # (mandatory) location of the ToolList SQLite database
 ToolDB /path/to/toollist

 # (mandatory) directory for temporary files
 TempDirectory /path/to/temp/directory

 # (optional) log accounting data to this file
 AccountingFile /path/to/accdata.log

 <Process QMGR>
    # (mandatory) location of the pid file
    PidFile /path/to/qmgr.pid
    # (mandatory) logfile location
    LogFile /path/to/qmgr.log

    # (mandatory) where should the job output files be stored
    OutputDirectory /path/to/output/directory

    # (optional) how many concurrent jobs should be allowed
    MaxSubmittedJobs 100
 </Process>

 # (optional|mandatory) depending on class
 <Class GENDB::Remote::Server::Tool::Blast>
    Blastall /vol/biotools/bin/blastall
    FormatDB /vol/biotools/bin/formatdb
 </Class>


=head2 Available methods

=over 4

=cut

use strict;
use warnings;
use Config::ApacheFormat;

=item * GENDB::Remote::Server::Configuration B<new>($filename)

Creates a new configuration object and initializes it with the
configuration data.

  RETURNS: the new configuration object

=cut

sub new {
    my ($class, $file) = @_;
    my $config = Config::ApacheFormat->new(duplicate_directives => 'combine',
                                           case_sensitive => 1,
                                           inheritance_support => 0);
    $config->read($file);

    my $self = {};
    bless ($self, $class);
    $self = $config;
    return $self;
}


# inherited from Config::ApacheFormat

=item * STRING|VOID B<get>($directive)

Returns the value of an configuration directive.

  RETURNS: the value of an entry 

=cut

=item * GENDB::Remote::Server::Configuration B<block>(Blocktype => Blockname)

Returns a GENDB::Remote::Server::Configuration object that can
be used to access parameters inside a block.

=cut

1;

=back
