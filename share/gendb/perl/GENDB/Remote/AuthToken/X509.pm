package GENDB::Remote::AuthToken::X509;

=head1 NAME

GENDB::Remote::AuthToken::X509

=head1 DESCRIPTION

This module imports X.509 certificate data from the environment and makes
(some) certificate details available via the provided methods.

When running under the Apache web server (L<http://httpd.apache.org/>)
with mod_ssl (L<http://httpd.apache.org/docs/2.2/mod/mod_ssl.html>),
please note that you have to use

    SSLOptions +ExportCertData

to make the client certificate appear in the environment.

=head2 Available methods

=over 4

=cut

use strict;
use warnings;

use Crypt::OpenSSL::X509;

=item * GENDB::Remote:::AuthToken::X509 B<new>()

creates a new object and initializes it with the client certificate
data from the SSL_CLIENT_CERT environment variable.

  RETURNS: the new object

=cut

sub new {
    my ($class) = @_;
    my $self = {};
    bless($self, $class);

    unless (defined($ENV{'SSL_CLIENT_CERT'})) {
        #die __PACKAGE__.": No X509 certificate from client found, Apache misconfiguration?\n";
        return $self;
    }
    my $x509 = Crypt::OpenSSL::X509->new_from_string($ENV{'SSL_CLIENT_CERT'});
    $self->{SUBJECT} = $x509->subject();
    return $self;
}

=item * STRING B<auth_token>()

Return a token uniquely identifying a client by its X.509 certificate.

  RETURNS: a string containing the certificate subject

=cut

sub auth_token {
    my $self = shift;
    return $self->{SUBJECT} || 'none';
}

1;

=back
