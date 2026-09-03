#!/usr/bin/perl
use strict;
use warnings;

my $input_dir = $ARGV[0] || 'inputs/';
my $output_dir = $ARGV[1] || 'submit_here/';
my $pre_file = "$input_dir/reports/pre_fix/coverage.rpt";
my $post_file = "$input_dir/reports/post_fix/coverage.rpt";
my $plan_file = "$output_dir/fix_plan.txt";
my $report_file = "$output_dir/final_report.rpt";
my $summary_file = "$output_dir/machine_summary.txt";

sub parse_report {
    my ($file) = @_;
    open(my $fh, '<', $file) or die "Error: Cannot open $file: $!\n";
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

    my $weighted_sum = 0;
    foreach my $k (keys %cp) {
        $weighted_sum += ($cp{$k}{cov} * $cp{$k}{weight});
    }
    my $overall = $total_weight > 0 ? ($weighted_sum / $total_weight) : 0;

    my @holes;
    my @illegals;
    my @orphans;

    foreach my $k (sort { $a cmp $b } keys %bin) {
        my $b = $bin{$k};
        if (!exists $cp{$b->{cp}}) {
            push @orphans, $b;
        } elsif ($b->{illegal} eq 'YES' && $b->{hits} > 0) {
            push @illegals, $b;
        } elsif ($b->{illegal} eq 'NO' && $b->{hits} < $goal) {
            $b->{missing} = $goal - $b->{hits};
            push @holes, $b;
        }
    }

    my $zero_hits = scalar(grep { $_->{hits} == 0 } @holes);
    my $uncovered = scalar(@holes);
    my $illegal_hits = scalar(@illegals);
    my $orphan_count = scalar(@orphans);

    my $crit = $zero_hits + $illegal_hits;
    my $maj = $uncovered + $orphan_count;
    my $status = 'PASS';
    if ($crit > 0) {
        $status = 'FAIL';
    } elsif ($maj > 0) {
        $status = 'WARNING';
    }

    return {
        cfg => \%cfg, cp => \%cp, bin => \%bin, overall => $overall,
        total_weight => $total_weight, zero_hits => $zero_hits,
        uncovered => $uncovered, illegal_hits => $illegal_hits,
        orphans => $orphan_count, total_bins => scalar(keys %bin),
        coverpoints => scalar(keys %cp), status => $status,
        holes_list => \@holes, illegals_list => \@illegals, orphans_list => \@orphans
    };
}

my $pre = parse_report($pre_file);
my $post = parse_report($post_file);

my %pre_bins = map { $_ => 1 } keys %{$pre->{bin}};
my %post_bins = map { $_ => 1 } keys %{$post->{bin}};

my $bins_added = 0;
my $bins_removed = 0;

foreach my $b (keys %post_bins) {
    $bins_added++ unless exists $pre_bins{$b};
}
foreach my $b (keys %pre_bins) {
    $bins_removed++ unless exists $post_bins{$b};
}

my $keys_identical = ($bins_added == 0 && $bins_removed == 0) ? 1 : 0;

my @plan_actions;
if (-f $plan_file) {
    open(my $pf, '<', $plan_file);
    while (my $line = <$pf>) {
        chomp $line;
        if ($line =~ /^(\S+)\s+(\S+)\s+(\S+)$/) {
            push @plan_actions, { action => $1, cp => $2, bin => $3 };
        }
    }
    close($pf);
}

my $pred_overall = $pre->{overall};
if (scalar(@plan_actions) > 0) {
    my %pred_cp_covered;
    my %pred_cp_legal;
    foreach my $k (keys %{$pre->{cp}}) {
        $pred_cp_covered{$k} = $pre->{cp}{$k}{covered};
        $pred_cp_legal{$k} = $pre->{cp}{$k}{legal};
    }
    foreach my $act (@plan_actions) {
        if ($act->{action} eq 'DIRECTED_TEST' || $act->{action} eq 'CONSTRAINT_TUNE') {
            $pred_cp_covered{$act->{cp}}++ if exists $pred_cp_covered{$act->{cp}};
        }
    }
    my $pred_weighted_sum = 0;
    foreach my $k (keys %{$pre->{cp}}) {
        my $cov = $pred_cp_legal{$k} > 0 ? ($pred_cp_covered{$k} / $pred_cp_legal{$k}) * 100 : 100;
        $pred_weighted_sum += $cov * $pre->{cp}{$k}{weight};
    }
    $pred_overall = $pre->{total_weight} > 0 ? ($pred_weighted_sum / $pre->{total_weight}) : 0;
}

my $prediction_error = $post->{overall} - $pred_overall;

my $compliant_count = 0;
foreach my $act (@plan_actions) {
    my $key = "$act->{cp}.$act->{bin}";
    if (exists $post->{bin}{$key}) {
        my $b = $post->{bin}{$key};
        my $goal = $post->{cfg}{BIN_GOAL} || 10;
        if ($b->{hits} >= $goal || ($b->{illegal} eq 'YES' && $b->{hits} == 0)) {
            $compliant_count++;
        }
    } else {
        $compliant_count++;
    }
}
my $plan_compliance = scalar(@plan_actions) > 0 ? ($compliant_count / scalar(@plan_actions)) * 100 : 100;

my $closure_pass = 1;
$closure_pass = 0 if $post->{zero_hits} > 0;
$closure_pass = 0 if $post->{illegal_hits} > 0;
$closure_pass = 0 if $post->{uncovered} > ($post->{cfg}{MAX_ALLOWED_UNCOVERED_BINS} || 2);
$closure_pass = 0 if $post->{overall} < ($post->{cfg}{OVERALL_TARGET_PERCENT} || 95);
$closure_pass = 0 unless $keys_identical;

my $closure_str = $closure_pass ? 'PASS' : 'FAIL';

open(my $out, '>', $report_file) or die "Error: Cannot open $report_file: $!\n";

print $out "=== BEFORE ===\n";
foreach my $k (sort keys %{$pre->{cp}}) {
    my $c = $pre->{cp}{$k};
    printf $out "COVERPOINT=%s COVERAGE=%.2f\n", $k, $c->{cov};
}
printf $out "OVERALL_BEFORE=%.2f\n\n", $pre->{overall};

print $out "=== DETECTED ISSUES ===\n";
foreach my $h (@{$pre->{holes_list}}) {
    printf $out "HOLE COVERPOINT=%s BIN=%s HITS=%d MISSING=%d\n", $h->{cp}, $h->{name}, $h->{hits}, $h->{missing};
}
foreach my $i (@{$pre->{illegals_list}}) {
    printf $out "ILLEGAL_HIT COVERPOINT=%s BIN=%s HITS=%d\n", $i->{cp}, $i->{name}, $i->{hits};
}
foreach my $o (@{$pre->{orphans_list}}) {
    printf $out "ORPHAN COVERPOINT=%s BIN=%s HITS=%d\n", $o->{cp}, $o->{name}, $o->{hits};
}
print $out "\n";

print $out "=== CORRECTION / RECOMMENDATION ===\n";
foreach my $act (@plan_actions) {
    printf $out "ACTION=%s COVERPOINT=%s BIN=%s\n", $act->{action}, $act->{cp}, $act->{bin};
}
print $out "\n";

print $out "=== AFTER ===\n";
foreach my $k (sort keys %{$post->{cp}}) {
    my $c = $post->{cp}{$k};
    printf $out "COVERPOINT=%s COVERAGE=%.2f\n", $k, $c->{cov};
}
printf $out "OVERALL_AFTER=%.2f\n", $post->{overall};
printf $out "BINS_ADDED=%d\n", $bins_added;
printf $out "BINS_REMOVED=%d\n", $bins_removed;
printf $out "REMAINING_HOLES=%d\n\n", $post->{uncovered};

print $out "=== CLOSURE ===\n";
printf $out "OVERALL_BEFORE=%.2f  OVERALL_AFTER=%.2f  TARGET=%.2f\n", $pre->{overall}, $post->{overall}, $post->{cfg}{OVERALL_TARGET_PERCENT} || 95;
printf $out "PREDICTED_OVERALL=%.2f  PREDICTION_ERROR=%.2f\n", $pred_overall, $prediction_error;
printf $out "ZERO_HIT_BINS_BEFORE=%d  ZERO_HIT_BINS_AFTER=%d\n", $pre->{zero_hits}, $post->{zero_hits};
printf $out "UNCOVERED_BINS_BEFORE=%d  UNCOVERED_BINS_AFTER=%d\n", $pre->{uncovered}, $post->{uncovered};
printf $out "MAX_ALLOWED_UNCOVERED_BINS=%.2f\n", $post->{cfg}{MAX_ALLOWED_UNCOVERED_BINS} || 2;
printf $out "ILLEGAL_HITS_BEFORE=%d  ILLEGAL_HITS_AFTER=%d\n", $pre->{illegal_hits}, $post->{illegal_hits};
printf $out "ORPHAN_BINS_BEFORE=%d  ORPHAN_BINS_AFTER=%d\n", $pre->{orphans}, $post->{orphans};
printf $out "TOTAL_BINS_BEFORE=%d  TOTAL_BINS_AFTER=%d\n", $pre->{total_bins}, $post->{total_bins};
printf $out "BINS_ADDED=%d  BINS_REMOVED=%d\n", $bins_added, $bins_removed;
printf $out "COVERPOINTS_BEFORE=%d  COVERPOINTS_AFTER=%d\n", $pre->{coverpoints}, $post->{coverpoints};
printf $out "PLAN_COMPLIANCE_PERCENT=%.2f\n", $plan_compliance;
printf $out "BEFORE_STATUS=%s  AFTER_STATUS=%s\n", $pre->{status}, $post->{status};
printf $out "CLOSURE=%s\n", $closure_str;

close($out);

open(my $sum, '>', $summary_file) or die "Error: Cannot open $summary_file: $!\n";
print $sum "CLOSURE=$closure_str\n";
print $sum "OVERALL_AFTER=" . sprintf("%.2f", $post->{overall}) . "\n";
print $sum "PLAN_COMPLIANCE=" . sprintf("%.2f", $plan_compliance) . "\n";
close($sum);

print "Level 5 complete. Report saved to $report_file\n";
