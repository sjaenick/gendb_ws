#!/usr/bin/env perl

use strict;
use Carp;
use Getopt::Std;
use GPMS::Application_Frame::GENDB;
use GENDB::Exporter::RegionObservations;
use IO::Handle;
use Term::ReadKey;

#use GENDB::Scheduler::Remote;
use Scheduler::DRMAA;

use Time::HiRes qw(gettimeofday);


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

my $cmdline = '/vol/biotools/bin/gendb_blastall -p blastn -i _FASTA_INPUT_ -d /vol/biodb/asn1/nt -F F -I T';
my @command = split(/ /, $cmdline);

my $input = $job->tool->is_dna_input ? $job->region->sequence() : $job->region->aasequence();
my $schedclass = 'Scheduler::DRMAA';
unless ($schedclass->available()) { die "not available.\n"; }


for ($cnt =1; $cnt <= 50; $cnt++) {

   my ($seconds1, $mseconds1) = gettimeofday;

   my $scheduler = $schedclass->new(input_placeholder => '_FASTA_INPUT_',
					output_placefolder => '_OUTPUT_',
					temp_dir => '/vol/codine-tmp/GenDB-WS/tmp/',
					commandline => \@command);
   $scheduler->set_native_option('-q *@@smallhosts');
   $scheduler->add_input_sequence($cnt, $input);
   $scheduler->submit();

   $scheduler->iterate(sub { _on_job_finished(@_); }, sub { _on_job_failed(@_); });

   my ($seconds2, $mseconds2) = gettimeofday;

   my $duration = $seconds2-$seconds1;

   open (F, ">>/homes/sjaenick/schedule_local.test");
   print F "$duration\n";
   close(F);

   print "$cnt done.\n";

   $scheduler->DESTROY(); 
   $scheduler = undef;

   $total += $duration;
}

print "total $total secs\n";
print "avg   ". $total/20 ."\n";


sub _on_job_finished {
    my ($id, $fh) = @_;
    my $output;
    if (ref $fh) {
        local $/ = undef;
        $output = <$fh>;
    } 
    #print $output;
    
    return 1;
}

sub _on_job_failed {
    print "FAIL!\n";
}

