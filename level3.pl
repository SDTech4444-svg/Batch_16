#!/usr/bin/perl
use strict;
use warnings;
use POSIX qw(ceil);

my $input_dir = $ARGV[0] || 'inputs/';
my $output_dir = $ARGV[1] || 'submit_here/';
my $report_file = "$input_dir/reports/pre_fix/coverage.rpt";
my $out_file = "$output_dir/level3_priority.rpt";

open(my $fh, '<', $report_file) or die "Error: Cannot open $report_file: $!\n";

my %cfg;
my %cp;
my %bin;

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
        }
    }
    elsif ($f[0] eq 'BIN' && @f >= 7) {
        if (!exists $bin{"$f[1].$f[2]"}) {
            $bin{"$f[1].$f[2]"} = { cp => $f[1], name => $f[2], hits => $f[4], illegal => $f[6] };
        }
    }
}
close($fh);

my $goal = $cfg{BIN_GOAL} || 0;
my $total_weight = 0;

foreach my $k (keys %bin) {
    my $b = $bin{$k};
    if (exists $cp{$b->{cp}}) {
        $cp{$b->{cp}}{bins}++;
        if ($b->{illegal} eq 'NO') {
            $cp{$b->{cp}}{legal}++;
            if ($b->{hits} >= $goal) {
                $cp{$b->{cp}}{covered}++;
            }
        }
    }
}

foreach my $k (keys %cp) {
    my $c = $cp{$k};
    if ($c->{bins} > 0 && $c->{legal} > 0) {
        $c->{cov} = ($c->{covered} / $c->{legal}) * 100;
    } else {
        $c->{cov} = $c->{legal} == 0 ? 100 : 0;
    }
    $total_weight += $c->{weight};
}

my @holes;
my %cp_holes;
my %cp_missing;
my %mod_holes;
my %mod_missing;

my $total_missing_hits = 0;
my $total_extra_tests = 0;
my $zero_hit_missing = 0;
my $hit_estimate = $cfg{HITS_PER_TEST_ESTIMATE} || 1;

foreach my $k (sort keys %bin) {
    my $b = $bin{$k};
    next unless exists $cp{$b->{cp}};
    
    if ($b->{illegal} eq 'NO' && $b->{hits} < $goal) {
        my $missing = $goal - $b->{hits};
        my $weight = $cp{$b->{cp}}{weight};
        my $score = $weight * $missing;
        my $zero_hit = ($b->{hits} == 0) ? 'YES' : 'NO';
        
        if ($zero_hit eq 'YES') {
            $score *= 2;
            $zero_hit_missing += $missing;
        }
        
        my $tests_needed = ceil($missing / $hit_estimate);
        $total_extra_tests += $tests_needed;
        $total_missing_hits += $missing;
        
        my $module = $cp{$b->{cp}}{module};
        $cp_holes{$b->{cp}}++;
        $cp_missing{$b->{cp}} += $missing;
        $mod_holes{$module}++;
        $mod_missing{$module} += $missing;
        
        push @holes, {
            cp => $b->{cp},
            bin => $b->{name},
            module => $module,
            weight => $weight,
            hits => $b->{hits},
            missing => $missing,
            zero_hit => $zero_hit,
            tests_needed => $tests_needed,
            score => $score
        };
    }
}

@holes = sort {
    $b->{score} <=> $a->{score}
    or $b->{missing} <=> $a->{missing}
    or $a->{cp} cmp $b->{cp}
    or $a->{bin} cmp $b->{bin}
} @holes;

my %cp_gain;
my $best_gain = -1;
my $best_cp = '';
my $worst_cp = '';
my $lowest_cov = 101;

foreach my $k (sort keys %cp) {
    my $c = $cp{$k};
    my $gain = $c->{weight} * (100 - $c->{cov}) / ($total_weight > 0 ? $total_weight : 1);
    $cp_gain{$k} = $gain;
    
    if ($gain > $best_gain) {
        $best_gain = $gain;
        $best_cp = $k;
    }
    
    if ($c->{cov} < $lowest_cov) {
        $lowest_cov = $c->{cov};
        $worst_cp = $k;
    }
}

my $tests_run = $cfg{TESTS_RUN} || 0;
my $extra_tests_percent = ($tests_run > 0) ? ($total_extra_tests / $tests_run) * 100 : 0;
my $zero_hit_share = ($total_missing_hits > 0) ? ($zero_hit_missing / $total_missing_hits) * 100 : 0;

open(my $out, '>', $out_file) or die "Error: Cannot open $out_file: $!\n";

my $rank = 1;
foreach my $h (@holes) {
    printf $out "RANK=%d COVERPOINT=%s BIN=%s MODULE=%s WEIGHT=%.2f HITS=%d MISSING=%d ZERO_HIT=%s TESTS_NEEDED=%d SCORE=%.2f\n",
        $rank++, $h->{cp}, $h->{bin}, $h->{module}, $h->{weight}, $h->{hits}, $h->{missing}, $h->{zero_hit}, $h->{tests_needed}, $h->{score};
}
print $out "\n";

foreach my $k (sort keys %cp) {
    my $c = $cp{$k};
    my $h_count = $cp_holes{$k} || 0;
    my $m_hits = $cp_missing{$k} || 0;
    printf $out "COVERPOINT=%s HOLES=%d MISSING_HITS=%d COVERAGE=%.2f COVERAGE_GAIN=%.2f\n",
        $k, $h_count, $m_hits, $c->{cov}, $cp_gain{$k};
}
print $out "\n";

foreach my $m (sort keys %mod_holes) {
    printf $out "MODULE=%s HOLES=%d MISSING_HITS=%d\n",
        $m, $mod_holes{$m}, $mod_missing{$m};
}
print $out "\n";

printf $out "TOTAL_HOLES=%d\n", scalar(@holes);
printf $out "TOTAL_MISSING_HITS=%d\n", $total_missing_hits;
printf $out "TOTAL_EXTRA_TESTS=%d\n", $total_extra_tests;
printf $out "EXTRA_TESTS_PERCENT=%.2f\n", $extra_tests_percent;
printf $out "ZERO_HIT_SHARE_PERCENT=%.2f\n", $zero_hit_share;
printf $out "BEST_CLOSURE_COVERPOINT=%s\n", $best_cp;
printf $out "BEST_CLOSURE_GAIN=%.2f\n", $best_gain;
printf $out "WORST_COVERPOINT=%s\n", $worst_cp;

close($out);
print "Level 3 complete. Report saved to $out_file\n";
