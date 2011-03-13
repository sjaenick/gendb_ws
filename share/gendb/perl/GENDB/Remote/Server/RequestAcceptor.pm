package GENDB::Remote::Server::RequestAcceptor;

=head1 NAME

GENDB::Remote::Server::RequestAcceptor

=head1 DESCRIPTION

This module provides the glue layer between Apache/mod_perl and
the L<GENDB::Remote::Server::RequestHandler> module. 

It is required to provide L<GENDB::Remote::Server::RequestHandler>
with the correct URN (Uniform Resource Name) that will be used
for the exchange of SOAP messages.

=cut

use strict;
use warnings;

use SOAP::Transport::HTTP;

my $server = SOAP::Transport::HTTP::Apache
    -> dispatch_with({'urn:GenDB' => 'GENDB::Remote::Server::RequestHandler'});


sub handler { $server->handler(@_) }

1;
