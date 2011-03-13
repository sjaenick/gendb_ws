package GENDB::Remote::Client::Configuration;


=head1 NAME

GENDB::Remote::Client::Configuration

=head1 DESCRIPTION

This package manages all the information that is required to remotely execute a tool.

=head2 I<RemoteSites> table

 +--------------+---------------------------+
 | name         | TEXT NOT NULL PRIMARY KEY |
 | WSDL         | TEXT NOT NULL             |
 | CertFile     | TEXT                      |
 | CertKeyFile  | TEXT                      |
 | PollInterval | INTEGER                   |
 +--------------+---------------------------+

=head2 I<Tools> table

 +------------+-----------------------------------+
 | _id        | INTEGER PRIMARY KEY AUTOINCREMENT |
 | name       | TEXT NOT NULL                     |
 | RemoteID   | INTEGER NOT NULL                  |
 | RemoteSite | TEXT NOT NULL                     |
 +------------------------------------------------+

=head2 I<Projects> table

 +------+-----------------------------------+
 | _id  | INTEGER PRIMARY KEY AUTOINCREMENT |
 | name | TEXT NOT NULL                     |
 +------+-----------------------------------+

=head2 I<ProjectTools> table

 +-------------+------------------+
 | project_id  | INTEGER NOT NULL |
 | tool_id     | INTEGER NOT NULL |
 +-------------+------------------+

All methods manipulating data in this package die() if the underlying SQLite
database file becomes inaccessible or corrupted.

=head2 Available methods

=over 4

=cut

use strict;
use warnings;

use DBI;
use DBD::SQLite;

use constant USE_DBMS_TRIGGERS => 1;

=item * GENDB::Remote::Client::Configuration B<new>()

This method creates a new object; if the database file doesn't exist,
it is newly created and the necessary table structure generated, if
directory permissions allow.

  RETURNS: the new object

=cut

sub new {
    my ($class) = @_;

    my $self = {};
    bless($self, $class);

    my $file = $self->_db_file();

    if (! -f $file) {
        $self->_create_database();
    } elsif (! -r $file) {
        die __PACKAGE__.": unable to read existing database file $file, aborting.\n";
    } elsif (! -w $file) {
        die __PACKAGE__.": unable to write to existing database file $file, aborting.\n";
    }
   
    return $self;
}


=item * BOOL B<add_site>(%site)

Adds a new site to the database. %site has to contain at least the keys 'name'
and 'WSDL'; further optional keys are 'CertFile', 'CertKeyFile' and 'PollInterval'.

  RETURNS: true on success

=cut

sub add_site {
    my ($self, %site) = @_;

    return unless (defined($site{name}));
    return unless (defined($site{WSDL}));

    my $dbh = $self->_dbh;
    my $sql = sprintf ('INSERT INTO RemoteSites (name, WSDL, CertFile, CertKeyFile, PollInterval)
                        VALUES ("%s", "%s", "%s", "%s", "%d")',
                       $site{name}, $site{WSDL}, $site{CertFile}, $site{CertKeyFile}, $site{PollInterval});
    $dbh->do($sql);
    if ($@) {
        my $error = @_;
        die __PACKAGE__.": could not write to RemoteSites, error: ".$error;
    }
    return 1;
}


=item * BOOL B<remove_site>($site_name)

Removes a site from the database. 

  RETURNS: true on success

=cut

sub remove_site {
    my ($self, $site) = @_;

    return unless (defined($site));

    my %remote_site;
    eval { %remote_site = %{$self->get_site($site)}; };
    unless (defined($remote_site{name})) {
        die __PACKAGE__.": RemoteSite does not exist.\n";
    }

    # make sure the remote site isn't used by any tool
    my @used_tools = @{$self->site_tools($site)};
    unless ((scalar @used_tools) == 0) {
        die __PACKAGE__.": Site still referenced by a Tool.\n";
    }

    # delete site from the database
    my $dbh = $self->_dbh;
    my $sql = sprintf ('DELETE FROM RemoteSites WHERE name="%s"', $site);
    $dbh->do($sql);
    if ($@) {
        my $error = @_;
        die __PACKAGE__.": could not update RemoteSites, error: ".$error;
    }
    return 1;
}


=item * BOOL B<add_tool>(%tool)

Adds a new tool to the database. %tool has to contain at least the keys 'name',
'RemoteID' and 'RemoteSite', with RemoteSite being equal to the 'name' field of
one entry in the "RemoteSites" table.

  RETURNS: true on success

=cut

sub add_tool {
    my ($self, %tool) = @_;

    return unless (defined($tool{name}));
    return unless (defined($tool{RemoteID}));
    return unless (defined($tool{RemoteSite}));

    return unless ($tool{RemoteID} =~ /\d+/);

    # make sure the remote site already exists
    my %remote_site;
    eval { %remote_site = %{$self->get_site($tool{RemoteSite})}; };
    unless (defined($remote_site{name})) {
        die __PACKAGE__.": Referenced RemoteSite does not exist.\n";
    }

    # check if a tool with the same name already exists
    if (defined($self->get_tool($tool{name}))) {
        return;
    }

    my $dbh = $self->_dbh;
    my $sql = sprintf ('INSERT INTO Tools (name, RemoteID, RemoteSite)
                        VALUES ("%s", "%d", "%s")',
                        $tool{name}, $tool{RemoteID}, $tool{RemoteSite});
    $dbh->do($sql);
    if ($@) {
        my $error = @_;
        die __PACKAGE__.": could not write to Tools, error: ".$error;
    }
    return 1;
}


=item * BOOL B<remove_tool>($tool_name)

Deletes a tool from the database.

  RETURNS: true on success

=cut

sub remove_tool {
    my ($self, $tool_name) =  @_;

    return unless (defined($tool_name));

    my %tool;
    eval { %tool = %{$self->get_tool($tool_name)}; };
    unless (defined($tool{name})) {
        die __PACKAGE__.": Tool does not exist.\n";
    }
 
    # make sure the tool isn't used by any project
    my @projects = @{$self->tool_projects($tool_name)};
    unless ((scalar @projects) == 0) {
        die __PACKAGE__.": Tool still referenced by a project.\n";
    }

    # delete tool from database
    my $dbh = $self->_dbh;
    my $sql = sprintf ('DELETE FROM Tools WHERE name="%s"', $tool_name);
    $dbh->do($sql);
    if ($@) {
        my $error = @_;
        die __PACKAGE__.": could not update Tools, error: ".$error;
    }
    return 1;
}


=item * BOOL B<add_project>($project_name)

Creates a new project.

  RETURNS: true on success.

=cut

sub add_project {
    my ($self, $proj_name) = @_;

    return unless (defined($proj_name));

    # make sure the name doesnt already exist
    if (defined($self->get_project($proj_name))) {
        return;
    }

    my $dbh = $self->_dbh;
    my $sql = sprintf ('INSERT INTO Projects (name) VALUES ("%s")',
                       $proj_name);
    $dbh->do($sql);
    if ($@) {
        my $error = @_;
        die __PACKAGE__.": could not write to Projects, error: ".$error;
    }
    return 1;
}


=item * BOOL B<remove_project>($project_id)

Deletes a project and all corresponding project/tool-associations from the database.

  RETURNS: true on success.

=cut

sub remove_project {
    my ($self, $proj_id) = @_;

    return unless (defined($proj_id));

    my $dbh = $self->_dbh;
    my $sql = sprintf ('DELETE FROM ProjectTools WHERE project_id="%d"', $proj_id);
    $dbh->do($sql);
    if ($@) {
        my $error = @_;
        die __PACKAGE__.": could not update ProjectTools, error: ".$error;
    }

    $sql = sprintf ('DELETE FROM Projects WHERE _id="%d"', $proj_id);
    $dbh->do($sql);
    if ($@) {
        my $error = @_;
        die __PACKAGE__.": could not update Projects, error: ".$error;
    }
    return 1;
}


=item * REF ON HASH|VOID B<get_site>($site_name)

Retrieve the information about a site from the database.

  RETURNS: reference on a hash containing the stored information using
           the column names of the RemoteSites table as keys

           undef, if the site doesn't exist

=cut

sub get_site {
    my ($self, $name) = @_;
    return $self->_get('RemoteSites', 'name', $name);
}


=item * REF ON HASH|VOID B<get_tool>($tool_name)

Retrieve the information about a tool from the database.

  RETURNS: reference on a hash containing the stored information using
           the column names of the Tools table as keys

           undef, if the tool doesn't exist

=cut

sub get_tool {
    my ($self, $name) = @_;
    return $self->_get('Tools', 'name', $name);
}


=item * REF ON HASH|VOID B<get_tool_by_id>($tool_id)

Retrieve the information about a tool from the database.

  RETURNS: reference on a hash containing the stored information using
           the column names of the Tools table as keys

           undef, if the tool doesn't exist

=cut

sub get_tool_by_id {
    my ($self, $id) = @_;
    return $self->_get('Tools', '_id', $id);
}

sub _get {
    my ($self, $table, $key, $value) = @_;

    return unless (defined($key));
    return unless (defined($value));
    return unless (defined($table));

    my $dbh = $self->_dbh;
    my $sql = sprintf ('SELECT * FROM %s WHERE "%s"="%s"', $table, $key, $value);
    my $sth = $dbh->prepare($sql);
    $sth->execute();

    my $result = $sth->fetchrow_hashref();

    unless (ref($result) eq "HASH") {
        $sth->finish();
        return undef;
    }
    $sth->finish();

    return $result;
}


=item * INTEGER|VOID B<get_project>($project_name)

Retrieve the ID of a project from the database.

  RETURNS: ID of a project as an integer
           undef, if the project doesn't exist

=cut

sub get_project {
    my ($self, $projname) = @_;

    return unless (defined($projname));

    my $dbh = $self->_dbh;
    my $sql = sprintf ('SELECT (_id) FROM Projects WHERE name="%s"', $projname);
    my $sth = $dbh->prepare($sql);
    $sth->execute();

    my $proj_id = $sth->fetchrow_array();
    $sth->finish();

    return $proj_id;
}


=item * BOOL B<add_tool_to_project>($project_name, %tool)

Creates an association between a project and a tool

  RETURNS: true, on success.

=cut

sub add_tool_to_project {
    my ($self, $projname, %tool) = @_;

    return unless (defined($projname));
    return unless (defined($tool{_id}));

    my $proj_id = $self->get_project($projname);

    my $dbh = $self->_dbh;
    my $sql = sprintf ('INSERT INTO ProjectTools (project_id, tool_id)
                        VALUES ("%d", "%d")',
                       $proj_id, $tool{_id});
    $dbh->do($sql);
    if ($@) {
        my $error = @_;
        die __PACKAGE__.": could not write to ProjectTools, error: ".$error;
    }
    return 1;
}


=item * BOOL B<remove_tool_from_project>($project_name, %tool)

Deletes an association between a project and a tool

  RETURNS: true, on success.

=cut

sub remove_tool_from_project {
    my ($self, $projname, %tool) = @_;

    return unless (defined($projname));
    return unless (defined($tool{_id}));

    my $proj_id = $self->get_project($projname);

    my $dbh = $self->_dbh;
    my $sql = sprintf ('DELETE FROM ProjectTools WHERE project_id="%d" AND tool_id="%d"', $proj_id, $tool{_id});
    $dbh->do($sql);
    if ($@) {
        my $error = @_;
        die __PACKAGE__.": could not write to ProjectTools, error: ".$error;
    }
    return 1;

}


=item * REF ON ARRAY|VOID B<project_tools>($project_name)

Use this method to obtain a list of all tools associated with a certain project.

  RETURNS: a reference on an array containing the tool IDs.

=cut

sub project_tools {
    my ($self, $projname) = @_;

    return unless (defined($projname));

    my $proj_id = $self->get_project($projname);
    return unless (defined($proj_id));

    my $dbh = $self->_dbh;
    my $sql = sprintf ('SELECT * FROM ProjectTools WHERE project_id="%d"',
                        $proj_id);
    my $sth = $dbh->prepare($sql);
    $sth->execute();

    my @tool_ids;

    while (my $assoc = $sth->fetchrow_hashref()) {
        unless (ref($assoc) eq 'HASH') {
            $sth->finish();
            $dbh->disconnect();
            die __PACKAGE__.": unable to read ProjectTools table, error: ".$dbh->errstr();
        }
        push @tool_ids, $assoc->{tool_id};
    }
    return \@tool_ids;
}


=item * REF ON ARRAY|VOID B<tool_projects>($toolname)

Use this method to obtain a list of all projects associated with a certain tool.

  RETURNS: a reference on an array containing the project ids.

=cut

sub tool_projects {
    my ($self, $toolname) = @_;

    return unless (defined($toolname));

    my %tool;
    eval { %tool = %{$self->get_tool($toolname)}; };
    unless (defined($tool{name})) {
        die __PACKAGE__.": Tool does not exist.\n";
    }

    my $dbh = $self->_dbh;
    my $sql = sprintf ('SELECT * FROM ProjectTools WHERE tool_id="%d"',
                        $tool{_id});
    my $sth = $dbh->prepare($sql);
    $sth->execute();

    my @proj_ids;

    while (my $assoc = $sth->fetchrow_hashref()) {
        unless (ref($assoc) eq 'HASH') {
            $sth->finish();
            $dbh->disconnect();
            die __PACKAGE__.": unable to read ProjectTools table, error: ".$dbh->errstr();
        }
        push @proj_ids, $assoc->{proj_id};
    }
    return \@proj_ids;
}


=item * REF ON ARRAY B<list_sites>()

List all configured remote sites

  RETURNS: a reference on an array containing a reference on a
           hash for each site

=cut

sub list_sites {
    my ($self) = @_;
    my $dbh = $self->_dbh;
    my $sth = $dbh->prepare('SELECT * FROM RemoteSites');
    $sth->execute();

    my @sites;

    while (my $site = $sth->fetchrow_hashref()) {
        unless (ref($site) eq "HASH") {
            $sth->finish();
            $dbh->disconnect();
            die __PACKAGE__.": unable to read RemoteSites table, error: ".$dbh->errstr();
        }
        push @sites, $site;
    }
    $sth->finish();

    return \@sites;
}


=item * REF ON ARRAY B<list_tools>()

List all configured remote tools

  RETURNS: a reference on an array containing a reference on a
           hash for each tool

=cut

sub list_tools {
    my ($self) = @_;
    my $dbh = $self->_dbh;
    my $sth = $dbh->prepare('SELECT * FROM Tools');
    $sth->execute();

    my @tools;

    while (my $tool = $sth->fetchrow_hashref()) {
        unless (ref($tool) eq "HASH") {
            $sth->finish();
            $dbh->disconnect();
            die __PACKAGE__.": unable to read Tools table, error: ".$dbh->errstr();
        }
        push @tools , $tool;
    }
    $sth->finish();

    return \@tools;
}


=item * REF ON ARRAY B<list_projects>()

List all configured projects

  RETURNS: a reference on an array containing the project names

=cut

sub list_projects {
    my ($self) = @_;
    my $dbh = $self->_dbh;
    my $sth = $dbh->prepare('SELECT * FROM Projects');
    $sth->execute();

    my @projects;

    while (my $project = $sth->fetchrow_hashref()) {
        unless (ref($project) eq "HASH") {
            $sth->finish();
            $dbh->disconnect();
            die __PACKAGE__.": unable to read Projects table, error: ".$dbh->errstr();
        }
        push @projects , $project->{name};
    }
    $sth->finish();

    return \@projects;
}


=item * REF ON ARRAY|VOID B<site_tools>($sitename)

Use this method to obtain a list of all tools associated with a certain site.

  RETURNS: a reference on an array containing the tool ids.

=cut

sub site_tools {
    my ($self, $sitename) = @_;

    return unless (defined($sitename));

    my $dbh = $self->_dbh;
    my $sql = sprintf ('SELECT * FROM Tools WHERE RemoteSite="%s"',
                        $sitename);
    my $sth = $dbh->prepare($sql);
    $sth->execute();

    my @tools;

    while (my $assoc = $sth->fetchrow_hashref()) {
        unless (ref($assoc) eq 'HASH') {
            $sth->finish();
            $dbh->disconnect();
            die __PACKAGE__.": unable to read Tools table, error: ".$dbh->errstr();
        }
        push @tools, $assoc->{name};
    }
    return \@tools;
}


sub _create_database {
    my ($self) = @_;

    my $dbh = DBI->connect('dbi:SQLite:dbname='.$self->_db_file, '', '',
                           {AutoCommit => 1,
                            RaiseError => 1});
    unless (ref($dbh)) {
        die __PACKAGE__.": unable to create database: ".$DBI::errstr;
    }

    # set the permission of the database file
    chmod (0600, $self->_db_file);

    # set the auto-vacuum pragma
    $dbh->do('PRAGMA auto_vacuum = 1');

    unless ($dbh->do('CREATE TABLE RemoteSites (name TEXT NOT NULL PRIMARY KEY, WSDL TEXT NOT NULL, CertFile TEXT,
                                                CertKeyFile TEXT, PollInterval INTEGER DEFAULT \'60\')')) {
        die __PACKAGE__.": unable to create RemoteSites table: ".$dbh->errstr;
    }
    unless ($dbh->do('CREATE UNIQUE INDEX site_index ON RemoteSites (name)')) {
        die __PACKAGE__.": unable to create Index on RemoteSites table: ".$dbh->errstr;
    }

    unless ($dbh->do('CREATE TABLE Tools (_id INTEGER PRIMARY KEY AUTOINCREMENT,
                                          name TEXT NOT NULL,
                                          RemoteID INTEGER NOT NULL, 
                                          RemoteSite TEXT NOT NULL)')) {
        die __PACKAGE__.": unable to create Tools table: ".$dbh->errstr;
    }
    unless ($dbh->do('CREATE UNIQUE INDEX tool_index ON Tools (_id)')) {
        die __PACKAGE__.": unable to create Index on Tools table: ".$dbh->errstr;
    }
    unless ($dbh->do('CREATE UNIQUE INDEX tool_name_index ON Tools (name)')) {
        die __PACKAGE__.": unable to create Index on Tools table: ".$dbh->errstr;
    }

    # SQLite doesnt know foreign keys and 'FOR EACH STATEMENT'; since triggers
    # are specific to a DBMS, we make this optional. The perl functions in this
    # package already enforce the same functionality, but "normally" this would
    # belong into the database.

    if (USE_DBMS_TRIGGERS eq 1) {
        $dbh->do(<<"EOF");

        CREATE TRIGGER fk_insert_Tool
        BEFORE INSERT ON Tools
        FOR EACH ROW BEGIN
            SELECT RAISE(ABORT, 'remote site for new tool does not exist')
            WHERE (SELECT name FROM RemoteSites WHERE name = NEW.RemoteSite) IS NULL;
        END;

        CREATE TRIGGER fk_delete_Tool
        BEFORE DELETE ON Tools
        FOR EACH ROW BEGIN
            SELECT RAISE(ABORT, 'tool still referenced by a project')
            WHERE (SELECT tool_id FROM ProjectTools WHERE tool_id = OLD._id) IS NOT NULL;
        END;

        CREATE TRIGGER fk_delete_RemoteSite
        BEFORE DELETE ON RemoteSites
        FOR EACH ROW BEGIN
            SELECT RAISE(ABORT, 'remote site still referenced by tools')
            WHERE (SELECT RemoteSite FROM Tools WHERE RemoteSite = OLD.name) IS NOT NULL;
        END;

EOF
    }

    unless ($dbh->do('CREATE TABLE Projects (_id INTEGER PRIMARY KEY AUTOINCREMENT,
                                          name TEXT NOT NULL)')) {
        die __PACKAGE__.": unable to create Projects table: ".$dbh->errstr;
    }
    unless ($dbh->do('CREATE UNIQUE INDEX projects_index ON Projects (name)')) {
        die __PACKAGE__.": unable to create Index on Tools table: ".$dbh->errstr;
    }


    unless ($dbh->do('CREATE TABLE ProjectTools (project_id INTEGER NOT NULL,
                                          tool_id INTEGER NOT NULL)')) {
        die __PACKAGE__.": unable to create ProjectTools table: ".$dbh->errstr;
    }
    unless ($dbh->do('CREATE UNIQUE INDEX projecttoolss_index ON ProjectTools (project_id, tool_id)')) {
        die __PACKAGE__.": unable to create Index on ProjectTools table: ".$dbh->errstr;
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


sub _connect {
    my ($self) = @_;

    my $dbh = DBI->connect('dbi:SQLite:dbname='.$self->_db_file, '', '',
                           {AutoCommit => 1,
                            RaiseError => 1});
    unless (ref($dbh)) {
        die __PACKAGE__.": unable to load database: ".$DBI::errstr;
    }
    $self->{dbh} = $dbh;

}


# getter method for the database handle
sub _dbh {
    my ($self) = @_;
    unless (ref($self->{dbh})) {
        $self->_connect;
    }
    return $self->{dbh};
}

# helper access methods
sub _db_file {
    return $ENV{gendb_VAR_DIR}.'/client.config';
}

1;

=back

=head1 SEE ALSO

L<GENDB::Remote::Client::API>

