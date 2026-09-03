#!/usr/bin/perl
use strict;
use warnings;

my $input_dir = $ARGV[0] || 'inputs/';
my $output_dir = $ARGV[1] || 'submit_here/';
my $report_file = "$input_dir/reports/pre_fix/coverage.rpt";
my $out_file = "$output_dir/level2_violations.rpt";

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

my $total_weight = 0;
my $weighted_cov_sum = 0;

foreach my $k (keys %bin) {
    my $b = $bin{$k};
    if (exists $cp{$b->{cp}}) {
        $cp{$b->{cp}}{bins}++;
        if ($b->{illegal} eq 'NO') {
            $cp{$b->{cp}}{legal}++;
            if ($b->{hits} >= ($cfg{BIN_GOAL} || 0)) {
                $cp{$b->{cp}}{covered}++;
            }
        }
    }
}

foreach my $k (keys %cp) {
    my $c = $cp{$k};
    if ($c->{bins} == 0) {
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

my @violations;
my $critical_count = 0;
my $major_count = 0;
my $uncovered_bins = 0;
my $zero_hit_bins = 0;
my $illegal_bin_hits = 0;
my $orphan_bins = 0;
my $cp_below_target = 0;
my $total_missing_hits = 0;
my $goal = $cfg{BIN_GOAL} || 0;

foreach my $k (sort { $a cmp $b } keys %bin) {
    my $b = $bin{$k};
    my $module = exists $cp{$b->{cp}} ? $cp{$b->{cp}}{module} : 'UNKNOWN';
    
    if (!exists $cp{$b->{cp}}) {
        push @violations, sprintf("VIOLATION TYPE=ORPHAN_BIN COVERPOINT=%s BIN=%s MODULE=%s HITS=%d GOAL=%.2f MISSING=%d SEVERITY=MAJOR DETAIL=coverpoint_not_declared",
            $b->{cp}, $b->{name}, $module, $b->{hits}, $goal, 0);
        $major_count++;
        $orphan_bins++;
    }
    elsif ($b->{illegal} eq 'NO' && $b->{hits} < $goal) {
        my $missing = $goal - $b->{hits};
        my $severity = $b->{hits} == 0 ? 'CRITICAL' : 'MAJOR';
        push @violations, sprintf("VIOLATION TYPE=UNCOVERED_BIN COVERPOINT=%s BIN=%s MODULE=%s HITS=%d GOAL=%.2f MISSING=%d SEVERITY=%s DETAIL=missing_hits",
            $b->{cp}, $b->{name}, $module, $b->{hits}, $goal, $missing, $severity);
        $uncovered_bins++;
        $total_missing_hits += $missing;
        if ($b->{hits} == 0) {
            $critical_count++;
            $zero_hit_bins++;
        } else {
            $major_count++;
        }
    }
    elsif ($b->{illegal} eq 'YES' && $b->{hits} > 0) {
        push @violations, sprintf("VIOLATION TYPE=ILLEGAL_BIN_HIT COVERPOINT=%s BIN=%s MODULE=%s HITS=%d GOAL=%.2f MISSING=%d SEVERITY=CRITICAL DETAIL=illegal_stimulus_generated",
            $b->{cp}, $b->{name}, $module, $b->{hits}, $goal, 0);
        $critical_count++;
        $illegal_bin_hits++;
    }
}

my @cp_violations;
my $cp_target = $cfg{COVERPOINT_TARGET_PERCENT} || 0;
foreach my $k (sort keys %cp) {
    my $c = $cp{$k};
    if ($c->{cov} < $cp_target) {
        my $gap = $cp_target - $c->{cov};
        push @cp_violations, sprintf("COVERPOINT_VIOLATION TYPE=COVERPOINT_BELOW_TARGET COVERPOINT=%s COVERAGE=%.2f TARGET=%.2f GAP=%.2f SEVERITY=MAJOR",
            $k, $c->{cov}, $cp_target, $gap);
        $major_count++;
        $cp_below_target++;
    }
}

my @design_violations;
my $ov_target = $cfg{OVERALL_TARGET_PERCENT} || 0;
if ($overall_cov < $ov_target) {
    my $gap = $ov_target - $overall_cov;
    push @design_violations, sprintf("DESIGN_VIOLATION TYPE=OVERALL_BELOW_TARGET MEASURED=%.2f TARGET=%.2f GAP=%.2f SEVERITY=MAJOR",
        $overall_cov, $ov_target, $gap);
    $major_count++;
}

my $total_violations = scalar(@violations) + scalar(@cp_violations) + scalar(@design_violations);
my $baseline_status = 'PASS';
if ($critical_count > 0) {
    $baseline_status = 'FAIL';
} elsif ($major_count > 0) {
    $baseline_status = 'WARNING';
}

open(my $out, '>', $out_file) or die "Error: Cannot open $out_file: $!\n";

foreach my $v (@violations) { print $out "$v\n"; }
print $out "\n" if @violations;
foreach my $cv (@cp_violations) { print $out "$cv\n"; }
print $out "\n" if @cp_violations;
foreach my $dv (@design_violations) { print $out "$dv\n"; }
print $out "\n" if @design_violations;

printf $out "TOTAL_VIOLATIONS=%d\n", $total_violations;
printf $out "CRITICAL_COUNT=%d  MAJOR_COUNT=%d\n", $critical_count, $major_count;
printf $out "UNCOVERED_BINS=%d  ZERO_HIT_BINS=%d\n", $uncovered_bins, $zero_hit_bins;
printf $out "ILLEGAL_BIN_HITS=%d  ORPHAN_BINS=%d\n", $illegal_bin_hits, $orphan_bins;
printf $out "COVERPOINTS_BELOW_TARGET=%d\n", $cp_below_target;
printf $out "TOTAL_MISSING_HITS=%d\n", $total_missing_hits;
printf $out "BASELINE_STATUS=%s\n", $baseline_status;

close($out);
print "Level 2 complete. Report saved to $out_file\n";
