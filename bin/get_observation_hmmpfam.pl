#!/usr/bin/env perl

use strict;
use Carp;
use Getopt::Std;
use GPMS::Application_Frame::GENDB;
use GENDB::Exporter::RegionObservations;
use IO::Handle;
use Term::ReadKey;


use GENDB::Remote::Client;

STDOUT->autoflush(1);
STDERR->autoflush(1);
 

my $usr = 'sjaenick';
# get MySQL password
print "Your database password:";
ReadMode('noecho');
my $password = ReadLine(0);
chomp $password;
print "\n";
ReadMode('normal');
chomp($password);

# initialize project
my $app_frame = GPMS::Application_Frame::GENDB->new($usr,
						    $password);

unless(ref $app_frame){
    print "Error, could not connect to database, wrong password?\n";
    exit 1;
}

my $project_name = 'GenDB-2.1-Test';

unless($app_frame->project($project_name)){
    print "Error, could not init project $project_name\n";
    exit 1;
}

my $master = $app_frame->application_master();

my $obs = $master->Observation->init_id(968502);
my $result = run_remote($obs, $project_name);



sub run_remote {
    my ($obs, $proj_name) =  @_;

    my %attrs = %{_basic_attributes($obs)};
    my $toolname = $obs->tool->name();
    my $input = $obs->tool->is_dna_input ? $obs->region->sequence() : $obs->region->aasequence();

    my $client;

    eval {
        $client = GENDB::Remote::Client->new();
        $client->configure($proj_name, $toolname);
    };
    if ($@) {
        return 0;
    }

    my $out = $client->run($input, %attrs);
    return $out;
}



sub _basic_attributes {
    my ($observation) = @_;

    my %basic;
    foreach (@{$observation->_attributes_info()}) { 
        my %attr = %$_;
        if ($attr{type} =~ /(B|b)asic/ ) {
   	    my $name=$attr{name};
            my $value = $observation->$name();

            if (defined($value)) {
                $basic{$name} = $value;
            }
        }
    }
    return \%basic;
}
