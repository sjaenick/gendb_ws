#!/usr/bin/env perl

use strict;
use warnings;
use GENDB::Remote::Client::API;
use POSIX qw(times);
use Time::HiRes qw(gettimeofday);


my $input = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
my $toolid = 1;

my $schedclass = "GENDB::Scheduler::Remote";

$|=1;

my $cnt;

for ($cnt =1; $cnt <= 50; $cnt++) {

    print "Running for $cnt inputs.. ";

    my $start = &compute($cnt);

    my ($seconds1, $mseconds1) = gettimeofday;

    my $exectime = $seconds1 - $start;
    print $exectime." secs.\n";
    open (F, ">>/homes/sjaenick/remote.test");
    print F "$cnt $exectime\n";
    close(F);

}

sub compute {
    my $count = shift;

    my %jobs;
    my $i = 1;
    while ($count >= $i) {
        $jobs{$i} = $input;
        $i++;
    }

    my $client = GENDB::Remote::Client::API->new();
    $client->configure("TEST", "MD5SUM");

    # start time measurement here, excluding sqlite processing etc.
    my ($seconds, $mseconds) = gettimeofday;

    $client->add(%jobs);
    $client->submit(sub { _on_submit(@_); }, sub { _on_error(@_); });
    $client->iterate(sub { _on_finished(@_); }, sub { _on_error(@_); });
    return $seconds;
}

sub _on_submit {
  return 1;
}

sub _on_finished {
  my ($id, $out) = @_;
  return 1;
}

sub _on_error {
    print "FAIL!\n";
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
