package GENDB::Remote::Server::Tool::Blast;

=head1 NAME

GENDB::Remote::Server::Tool::Blast

=head1 DESCRIPTION

This package implements an extension to the L<GENDB::Remote::Server::Tool>
class, since assembling the Blast command line requires additional
parameters and processing that cannot be done with the L<GENDB::Remote::Server::Tool>
package. See L<GENDB::Remote::Server::Tool> for a description of the
methods.

=head1 CONFIGURATION

 <Class GENDB::Remote::Server::Tool::Blast>
    Blastall /path/to/blastall
    Blastpgp /path/to/blastpgp
 </Class>

Supported configuration keys:

 * blast_type	Type of BLAST program to use (blastn, blastp, ..)
 * db_file	Path to sequence database
 * opt_args	additional command line parameters

=cut

use strict;
use warnings;

use base qw(GENDB::Remote::Server::Tool);


sub prepare_run {
    my ($self, $input, %attributes) = @_;

    $self->{class_config} = $self->_class_config();

    my @cmd;

    unless ($self->_blast_type eq "blastpgp") {
        push @cmd, $self->_blastall_program($self->{class_config});
        push @cmd, "-p", $self->_blast_type;
    } else {
        push @cmd, $self->_blastpgp_program($self->{class_config});
    }

    push @cmd, "-i";
    push @cmd, "_FASTA_INPUT_";
    push @cmd, "-d", $self->_db_file;
    push @cmd, $self->_opt_args;

    if ((defined($attributes{db_reference})) && ($attributes{db_reference} =~ /\w+\|([^|]+)\|/)) {
        push @cmd, "-l", $self->_db_reference($attributes{db_reference})->filename();
    }

    return \@cmd;
}


sub command_line {
    my ($self) = @_;

    $self->{class_config} = $self->_class_config();

    my @cmd;

    unless ($self->_blast_type eq "blastpgp") {
        push @cmd, $self->_blastall_program($self->{class_config});
        push @cmd, "-p", $self->_blast_type;
    } else {
        push @cmd, $self->_blastpgp_program($self->{class_config});
    }

    push @cmd, "-i _FASTA_INPUT_";
    push @cmd, "-d", $self->_db_file;
    push @cmd, $self->_opt_args;

    return join(" ", @cmd);
}


# internal methods below


sub _db_reference {
    my ($self, $dbref) = @_;
    my $gi;

    if ($dbref =~ /\w+\|([^|]+)\|/) {
        $gi = $1;
    }
    return $self->_write_file($gi, 0);
}


sub _blastall_program {
    my ($self, $config) = @_;

    my $blast = $config->get("Blastall");
    unless (defined($blast)) {
        die __PACKAGE__.": Configuration error - No Blastall in ".$self->{tool_data}->{CLASS}."\n";
    }
    return $blast;
}


sub _blastpgp_program {
    my ($self, $config) = @_;

    my $blast = $config->get("Blastpgp");
    unless (defined($blast)) {
        die __PACKAGE__.": Configuration error - No Blastpgp in ".$self->{tool_data}->{CLASS}."\n";
    }
    return $blast;
}


sub _blast_type {
    my ($self) = @_;
    return $self->{tool_data}->{blast_type};
}

sub _db_file {
    my ($self) = @_;
    return $self->{tool_data}->{db_file};
}

sub _opt_args {
    my ($self) = @_;
    return $self->{tool_data}->{opt_args};
}

1;

=head1 SEE ALSO

L<GENDB::Remote::Server::Tool>

L<GENDB::Remote::Server::Configuration>

