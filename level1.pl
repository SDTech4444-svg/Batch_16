#!/usr/bin/perl
use strict;
use warnings;

my $input_dir = $ARGV[0] || 'inputs/';
my $output_dir = $ARGV[1] || 'submit_here/';
my $report_file = "$input_dir/reports/pre_fix/coverage.rpt";
my $out_file = "$output_dir/level1_baseline.rpt";

open(my $fh, '<', $report_file) or die "Error: Cannot open $report_file: $!\n";

my %cfg;  
my %cp;   
my %bin;  
my $skipped = 0;

while (my $line = <$fh>) {
    $line =~ s/\r//g;
    $line =~ s/#.*//; 
    $line =~ s/^\s+//;
    $line =~ s/\s+$//;
    next if $line eq '';

    while ($line =~ /\b(BIN_GOAL|OVERALL_TARGET_PERCENT|COVERPOINT_TARGET_PERCENT|MAX_ALLOWED_UNCOVERED_BINS|TESTS_RUN|HITS_PER_TEST_ESTIMATE)\s+([\d\.]+)\b/g) {
        $cfg{$1} = $2;
    }

    my @f = split /\s+/, $line;
    next unless @f;

    if ($f[0] eq 'COVERPOINT' && @f >= 6) {
        $cp{$f[1]} = { kind => 'COVERPOINT', module => $f[3], weight => $f[5], bins => 0, legal => 0, covered => 0, cov => 0 };
    }
    elsif ($f[0] eq 'CROSS' && @f >= 8) {
        if ($line =~ /^CROSS\s+(\S+)\s+OF\s+(.+?)\s+MODULE\s+(\S+)\s+WEIGHT\s+([\d\.]+)/) {
            $cp{$1} = { kind => 'CROSS', module => $3, weight => $4, bins => 0, legal => 0, covered => 0, cov => 0 };
        } else {
            $skipped++;
        }
    }
    elsif ($f[0] eq 'BIN' && @f >= 7) {
        if (exists $bin{"$f[1].$f[2]"}) {
            $skipped++; 
        } else {
            $bin{"$f[1].$f[2]"} = { cp => $f[1], name => $f[2], hits => $f[4], illegal => $f[6] };
        }
    }
    elsif ($f[0] =~ /^(BIN_GOAL|OVERALL_TARGET_PERCENT|COVERPOINT_TARGET_PERCENT|MAX_ALLOWED_UNCOVERED_BINS|TESTS_RUN|HITS_PER_TEST_ESTIMATE)$/) {
        # Already extracted by global regex
    }
    else {
        $skipped++;
    }
}
close($fh);

my $total_bins = 0;
my $legal_bins = 0;
my $illegal_bins = 0;
my $covered_bins = 0;
my $zero_hit_bins = 0;
my $total_hits = 0;
my @orphans;

foreach my $k (keys %bin) {
    my $b = $bin{$k};
    $total_bins++;
    $total_hits += $b->{hits};
    
    if ($b->{hits} == 0 && $b->{illegal} eq 'NO') {
        $zero_hit_bins++;
    }
    
    if ($b->{illegal} eq 'NO') {
        $legal_bins++;
        if ($b->{hits} >= ($cfg{BIN_GOAL} || 0)) {
            $covered_bins++;
        }
    } else {
        $illegal_bins++;
    }
    
    if (!exists $cp{$b->{cp}}) {
        push @orphans, $b;
        next;
    }
    
    $cp{$b->{cp}}{bins}++;
    if ($b->{illegal} eq 'NO') {
        $cp{$b->{cp}}{legal}++;
        if ($b->{hits} >= ($cfg{BIN_GOAL} || 0)) {
            $cp{$b->{cp}}{covered}++;
        }
    }
}

my $orphan_count = scalar(@orphans);
my $empty_cp = 0;
my $total_weight = 0;
my $weighted_cov_sum = 0;

foreach my $k (sort keys %cp) {
    my $c = $cp{$k};
    if ($c->{bins} == 0) {
        $empty_cp++;
        $c->{cov} = 0;
    } else {
        if ($c->{legal} == 0) {
            $c->{cov} = 100;
        } else {
            $c->{cov} = ($c->{covered} / $c->{legal}) * 100;
        }
    }
    
    $total_weight += $c->{weight};
    $weighted_cov_sum += ($c->{cov} * $c->{weight});
}

my $overall_cov = $total_weight > 0 ? ($weighted_cov_sum / $total_weight) : 0;

open(my $out, '>', $out_file) or die "Error: Cannot open $out_file: $!\n";

printf $out "BATCH=16\n";
printf $out "INPUT_STATUS=PASS\n";
printf $out "BIN_GOAL=%.2f\n", $cfg{BIN_GOAL} || 0;
printf $out "OVERALL_TARGET_PERCENT=%.2f\n", $cfg{OVERALL_TARGET_PERCENT} || 0;
printf $out "COVERPOINT_TARGET_PERCENT=%.2f\n", $cfg{COVERPOINT_TARGET_PERCENT} || 0;
printf $out "MAX_ALLOWED_UNCOVERED_BINS=%.2f\n", $cfg{MAX_ALLOWED_UNCOVERED_BINS} || 0;
printf $out "TESTS_RUN=%.2f\n", $cfg{TESTS_RUN} || 0;
printf $out "HITS_PER_TEST_ESTIMATE=%.2f\n", $cfg{HITS_PER_TEST_ESTIMATE} || 0;

my $num_cps = scalar(grep { $cp{$_}{kind} eq 'COVERPOINT' } keys %cp);
my $num_crs = scalar(grep { $cp{$_}{kind} eq 'CROSS' } keys %cp);

printf $out "COVERPOINTS=%d\n", $num_cps;
printf $out "CROSSES=%d\n", $num_crs;
printf $out "TOTAL_BINS=%d\n", $total_bins;
printf $out "LEGAL_BINS=%d\n", $legal_bins;
printf $out "ILLEGAL_BINS=%d\n", $illegal_bins;
printf $out "COVERED_BINS=%d\n", $covered_bins;
printf $out "ZERO_HIT_BINS=%d\n", $zero_hit_bins;
printf $out "ORPHAN_BINS=%d\n", $orphan_count;
printf $out "EMPTY_COVERPOINTS=%d\n", $empty_cp;
printf $out "TOTAL_HITS=%d\n", $total_hits;
printf $out "TOTAL_WEIGHT=%.2f\n", $total_weight;
printf $out "OVERALL_COVERAGE_PERCENT=%.2f\n", $overall_cov;
printf $out "SKIPPED_RECORDS=%d\n\n", $skipped;

foreach my $k (sort keys %cp) {
    my $c = $cp{$k};
    printf $out "COVERPOINT=%s KIND=%s MODULE=%s WEIGHT=%.2f BINS=%d LEGAL=%d COVERED=%d COVERAGE=%.2f\n",
        $k, $c->{kind}, $c->{module}, $c->{weight}, $c->{bins}, $c->{legal}, $c->{covered}, $c->{cov};
}

print $out "\n";
foreach my $o (sort { $a->{cp} cmp $b->{cp} or $a->{name} cmp $b->{name} } @orphans) {
    printf $out "ORPHAN BIN=%s COVERPOINT=%s HITS=%d\n", $o->{name}, $o->{cp}, $o->{hits};
}

close($out);
print "Level 1 complete. Report saved to $out_file\n";