#!/usr/bin/env perl

use strict;
use warnings;
use SOAP::Transport::HTTP;

my $srv = SOAP::Server->new();
$srv->myuri('https://cab.cebitec.uni-bielefeld.de:8889/perl/')
    ->dispatch_with({'urn:GenDB' => 'GENDB::Remote::Server::RequestHandler'})
    ->handle();

sub handler { $srv->handler(@_) }

#$srv->handle(@_);

