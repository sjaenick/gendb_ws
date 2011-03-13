#!/usr/bin/env perl

use strict;
use warnings;
use Scheduler::DRMAA;
use POSIX qw(times);
use Time::HiRes qw(gettimeofday);


my $input = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
my $cmd = "/vol/gnu/bin/md5sum _FASTA_INPUT_";

my $schedclass = "Scheduler::DRMAA";

$|=1;

my $cnt;

for ($cnt =1; $cnt <= 50; $cnt++) {

    print "Running for $cnt inputs.. ";

    my $start = &compute($cnt);

    my ($seconds1, $mseconds1) = gettimeofday;

    my $exectime = $seconds1 - $start;
    print $exectime." secs.\n";
    open (F, ">>/homes/sjaenick/local.test");
    print F "$cnt $exectime\n";
    close(F);

}

sub compute {

    my $count = shift;
    my @command = split(/ /, $cmd);
    my $schedopts;

    my $scheduler = $schedclass->new(input_placeholder => '_FASTA_INPUT_',
			       output_placefolder => '_OUTPUT_',
			       temp_dir => '/vol/codine-tmp/GenDB-WS/tmp',
			       commandline => \@command);

    if ($scheduler->can("set_native_option")) {
        $scheduler->set_native_option($schedopts) if ($schedopts);
    }

    my ($seconds, $mseconds) = gettimeofday;

    my $i = 1;
    while ($count >= $i) {
        $scheduler->add_input_sequence($i, $input);
        $i++;
    }

    $scheduler->submit();

    $scheduler->iterate(sub { _on_job_finished(@_); }, sub { _on_job_failed(@_); });

    # GC sucks?
    $scheduler->DESTROY(); $scheduler = undef;
    return $seconds;
}



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
