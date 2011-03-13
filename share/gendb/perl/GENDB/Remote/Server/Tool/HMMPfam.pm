package GENDB::Remote::Server::Tool::HMMPfam;

=head1 NAME

GENDB::Remote::Server::Tool::HMMPfam

=head1 DESCRIPTION

This package implements an extension to the L<GENDB::Remote::Server::Tool>
class, since assembling the HMMPfam command line requires additional
parameters and processing that cannot be done with the L<GENDB::Remote::Server::Tool>
package. See L<GENDB::Remote::Server::Tool> for a description of the
methods.

=head1 CONFIGURATION

 <Class GENDB::Remote::Server::Tool::HMMPfam>
    HMMPfam /path/to/hmmpfam
    HMMFetch /path/to/hmmfetch
 </Class>

Supported configuration keys:

 * db_file    Path to database file
 * opt_args   additional command line parameters

=cut

use strict;
use warnings;

use base qw(GENDB::Remote::Server::Tool);


sub prepare_run {
    my ($self, $input, %attributes) = @_;

    $self->{class_config} = $self->_class_config();

    my @fetch_cmd;
    push @fetch_cmd, $self->_hmmfetch_program($self->{class_config});
    push @fetch_cmd, $self->_dbfile;
    if (defined($attributes{model_acc})) {
        push @fetch_cmd, $attributes{model_acc};
    } else {
        die __PACKAGE__.": Mandatory attribute model_acc missing.\n";
    }

    my $fetch_result = $self->_run_hmmfetch(join(' ', @fetch_cmd));

    # skip possible multiple entries from file
    $fetch_result =~ s!^//.+!//!mso;

    my $modelfile = $self->_write_file($fetch_result);    

    # the hmmpfam command
    my @cmd;
    push @cmd, $self->_hmmpfam_program($self->{class_config});
    push @cmd, $self->_optargs;
    push @cmd, $modelfile->filename();
    push @cmd, "_FASTA_INPUT_";

    return \@cmd;
}


sub command_line {
    my ($self) = @_;

    $self->{class_config} = $self->_class_config();

    my @cmd;
    push @cmd, $self->_hmmpfam_program($self->{class_config});
    push @cmd, $self->_optargs;
    push @cmd, $self->_dbfile;
    push @cmd, "_FASTA_INPUT_";

    return join(" ", @cmd);
}


# internal methods below

sub _run_hmmfetch {
    my ($self, $cmd) = @_;
    open (HMMFETCH, "$cmd |") || die "Cannot execute HMMFetch command.\n";
    my $result;
    while (<HMMFETCH>) {
        $result .= $_;
    }
    close(HMMFETCH);
    return $result;
}


sub _hmmpfam_program {
    my ($self, $config) = @_;

    my $hmmpfam = $config->get("HMMPfam");
    unless (defined($hmmpfam)) {
        die __PACKAGE__.": Configuration error - No HMMPfam in ".$self->{tool_data}->{CLASS}."\n";
    }
    return $hmmpfam;
}


sub _hmmfetch_program {
    my ($self, $config) = @_;

    my $hmmfetch = $config->get("HMMFetch");
    unless (defined($hmmfetch)) {
        die __PACKAGE__.": Configuration error - No HMMFetch in ".$self->{tool_data}->{CLASS}."\n";
    }
    return $hmmfetch;
}


sub _dbfile {
    my ($self) = @_;
    return $self->{tool_data}->{db_file};
}

sub _optargs {
    my ($self) = @_;
    return $self->{tool_data}->{opt_args};
}

1;

=head1 SEE ALSO

L<GENDB::Remote::Server::Tool>

L<GENDB::Remote::Server::Configuration>

