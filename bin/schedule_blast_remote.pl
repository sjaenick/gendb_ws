#!/usr/bin/env perl

use strict;
use Carp;
use Getopt::Std;
use GPMS::Application_Frame::GENDB;
use GENDB::Exporter::RegionObservations;
use IO::Handle;
use Term::ReadKey;

use GENDB::Scheduler::Remote;

use Time::HiRes qw(gettimeofday);


use GENDB::Remote::Client::API;

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

my $project_name = 'GenDB_CS';

unless($app_frame->project($project_name)){
    print "Error, could not init project $project_name\n";
    exit 1;
}

my $master = $app_frame->application_master();

my $job = $master->Job->init_id(4591);
my $total = 0;
my $cnt;

my @jobs; 
push @jobs, $job;

my $schedclass = 'GENDB::Scheduler::Remote';
unless ($schedclass->available()) { die "not available.\n"; }


for ($cnt =1; $cnt <= 50; $cnt++) {

   my ($seconds1, $mseconds1) = gettimeofday;

   my $scheduler = $schedclass->new();
   $scheduler->add_jobs(@jobs);
   $scheduler->execute(0, $project_name);
   my ($seconds2, $mseconds2) = gettimeofday;

   my $duration = $seconds2-$seconds1;

   open (F, ">>/homes/sjaenick/schedule_remote.test");
   print F "$duration\n";
   close(F);

   print "$cnt done.\n";

   $scheduler = undef;

   $total += $duration;
}

print "total $total secs\n";
print "avg   ". $total/20 ."\n";

