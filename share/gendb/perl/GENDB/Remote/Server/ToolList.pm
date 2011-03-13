package GENDB::Remote::Server::ToolList;


=head1 NAME

GENDB::Remote::Server::ToolList

=head1 DESCRIPTION

This package handles the configuration of the tools that are allowed for 
execution on the server side. 

The tool configuration is stored in a SQLite database and can be both
queried and manipulated using the methods this package provides.

The database file contains only a single table:

=head2 I<ToolList> table

 +-----------------------------------------------+
 | tool_id:    INTEGER PRIMARY KEY AUTOINCREMENT |
 | tool_name:  TEXT NOT NULL                     |
 | tool_descr: TEXT                              |
 | tool_data:  TEXT                              |
 | enabled:    BOOLEAN NOT NULL                  |
 +-----------------------------------------------+

All methods accessing tool data in this package die() if the underlying SQLite
database file becomes inaccessible or corrupted.

=head2 Available methods

=over 4

=cut

use strict;
use warnings;

use DBI;
use DBD::SQLite;


=item * GENDB::Remote::Server::ToolList B<new>($filename)

This method creates a new object; if the database file doesn't exist,
it is newly created and the necessary table structure generated, if
directory permissions allow.

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
    } elsif (! -r $file) {
        die __PACKAGE__.": unable to read existing database file $file, aborting.\n";
    } elsif (! -w $file) {
        die __PACKAGE__.": unable to write to existing database file $file, aborting.\n";
    }
   
    return $self;
}


=item * VOID|INTEGER B<add>($tool_name, $description, $tool_data, $enabled)

This method adds a new tool to the database. 

  RETURNS: the ID of the newly added tool, or
           undef if any necessary arguments are undefined 

=cut

sub add { 
    my ($self, $tool_name, $tool_descr, $tool_data, $enabled) = @_;

    return unless (defined($tool_name));
    return unless (defined($tool_descr));
    return unless (defined($tool_data));
    return unless (defined($enabled));

    my $dbh = $self->_dbh;

    my $sql = sprintf ('INSERT INTO ToolList (tool_name, tool_descr,
                      tool_data, enabled) VALUES ("%s", "%s", "%s", "%s")',
                       $tool_name, $tool_descr, $tool_data, $enabled);
    $dbh->do($sql);
    my $tool_id = $dbh->func('last_insert_rowid');

    if ($@) {
        my $error = @_;
        die __PACKAGE__.": could not write to ToolList, error: ".$error;
    }

    return $tool_id;
}


=item * VOID|BOOL B<remove>($tool_id)

This method removes a single tool identified by its unique tool id from
the database.

  RETURNS: true, if the tool was successfully deleted or didn't exist;
           undef, if no tool id was supplied as an argument.

=cut

sub remove {
    my ($self, $id) = @_;

    # no tool_id supplied, nothing to do
    return unless (defined($id));

    my $dbh = $self->_dbh;

    my $sql = sprintf ('DELETE FROM ToolList WHERE tool_id="%d"', $id);
    $dbh->do($sql);
    if ($@) {
        my $error = @_;
        die __PACKAGE__.": could not delete from ToolList, error: ".$error;
    }

    return 1;
}


=item * VOID|BOOL B<disable>($tool_id)

This method will disable a single tool identified by its tool id.

  RETURNS: true, if the tool was found and disabled; 
           false, if the tool doesn't exist;
           undef, if no tool id was supplied as an argument.

=cut

sub disable {
    my ($self, $id) = @_;

    # no tool_id supplied, nothing to do
    return unless (defined($id));

    my $dbh = $self->_dbh;

    my $sql = sprintf ('UPDATE ToolList SET enabled=0 WHERE tool_id="%d"', $id);
    my $ret = $dbh->do($sql);
    if ($@) {
        my $error = @_;
        die __PACKAGE__.": could not update ToolList, error: ".$error;
    }

    return $ret;
}


=item * VOID|BOOL B<enable>($tool_id)

This method will enable single tool identified by its tool id.

  RETURNS: true, if the tool was found and enabled; 
           false, if the tool doesn't exist;
           undef, if no tool id was supplied as an argument.

=cut

sub enable {
    my ($self, $id) = @_;

    # no tool_id supplied, nothing to do
    return unless (defined($id));

    my $dbh = $self->_dbh;

    my $sql = sprintf ('UPDATE ToolList SET enabled=1 WHERE tool_id="%d"', $id);
    my $ret = $dbh->do($sql);
    if ($@) {
        my $error = @_;
        die __PACKAGE__.": could not update ToolList, error: ".$error;
    }

    return $ret;
}


=item * REF ON HASH|VOID B<by_id>($tool_id)

This method can be used to obtain all information stored about a single tool.

  RETURNS: a reference on a hash using the column names of the ToolList table
           as keys and the information about a tool as values, or
  
           undef, if no tool id was supplied as an argument.

=cut

sub by_id {
    my ($self, $id) = @_;

    # no tool_id supplied, nothing to do
    return unless (defined($id));

    my $dbh = $self->_dbh;

    my $sql = sprintf ('SELECT * FROM ToolList WHERE tool_id="%d"', $id);
    my $sth = $dbh->prepare($sql);
    $sth->execute();

    my $tool = $sth->fetchrow_hashref();
 
    unless (ref($tool) eq "HASH") {
        $sth->finish();
        return undef;
    }
    $sth->finish();

    return $tool;
}


=item * REF ON HASH|VOID B<by_name>($tool_name)

This method can be used to obtain all information stored about a single tool.

  RETURNS: a reference on a hash using the column names of the ToolList table
           as keys and the information about a tool as values, or
 
           undef, if no tool name was supplied as an argument or the tool 
           doesn't exist.

=cut

sub by_name {
    my ($self, $name) = @_;

    # no tool_name supplied, nothing to do
    return unless (defined($name));

    my $dbh = $self->_dbh;

    my $sql = sprintf ('SELECT * FROM ToolList WHERE tool_name="%s"', $name);
    my $sth = $dbh->prepare($sql);
    $sth->execute();

    my $tool = $sth->fetchrow_hashref();

    unless (ref($tool) eq "HASH") {
        $sth->finish();
        return undef;
    }
    $sth->finish();

    return $tool;
}


=item * REF ON ARRAY B<list>()

This method can be used to query the database for all tools currently configured.

  RETURNS: a reference on an array containing a reference on a hash for each
           tool

=cut

sub list {
    my ($self) = @_;

    my $dbh = $self->_dbh;

    my $sth = $dbh->prepare('SELECT * FROM ToolList');
    $sth->execute();

    my @tool_list;

    while (my $tool = $sth->fetchrow_hashref()) {
        unless (ref($tool) eq "HASH") {
            $sth->finish();
            $dbh->disconnect();
            die __PACKAGE__.": unable to read ToolList table, error: ".$dbh->errstr();
        }
        push @tool_list, $tool;
    }
    $sth->finish();

    return \@tool_list;
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

    unless ($dbh->do('CREATE TABLE ToolList (tool_id INTEGER PRIMARY KEY AUTOINCREMENT,
                  tool_name TEXT NOT NULL, tool_descr TEXT, tool_data TEXT, enabled BOOLEAN NOT NULL)')) {
        die __PACKAGE__.": unable to create ToolList table: ".$dbh->errstr;
    }
    unless ($dbh->do('CREATE UNIQUE INDEX name_index ON ToolList (tool_name)')) {
        die __PACKAGE__.": unable to create Index on ToolList table: ".$dbh->errstr;
    }
    unless ($dbh->do('CREATE UNIQUE INDEX id_index ON ToolList (tool_id)')) {
        die __PACKAGE__.": unable to create Index on ToolList table: ".$dbh->errstr;
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
                            RaiseError => 1,
                            FetchHashKeyName => 'NAME_lc'});
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
    my ($self) = @_;

    unless (defined($self->{db_file})) {
        die __PACKAGE__.": Location of database file unknown.\n";
    }
    return $self->{db_file};
}

1;

=back

=head1 SEE ALSO

L<GENDB::Remote::Server::Tool>

