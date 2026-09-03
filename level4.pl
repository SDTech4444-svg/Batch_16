#!/usr/bin/perl
use strict;
use warnings;
use POSIX qw(ceil);

my $input_dir = $ARGV[0] || 'inputs/';
my $output_dir = $ARGV[1] || 'submit_here/';
my $report_file = "$input_dir/reports/pre_fix/coverage.rpt";
my $out_file = "$output_dir/level4_fix_plan.rpt";
my $txt_file = "$output_dir/fix_plan.txt";

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

sub get_overall {
    my $weighted_sum = 0;
    foreach my $k (keys %cp) {
        my $c = $cp{$k};
        my $current_cov = 0;
        if ($c->{bins} > 0 && $c->{legal} > 0) {
            $current_cov = ($c->{covered} / $c->{legal}) * 100;
        } else {
            $current_cov = $c->{legal} == 0 ? 100 : 0;
        }
        $weighted_sum += ($current_cov * $c->{weight});
    }
    return $total_weight > 0 ? ($weighted_sum / $total_weight) : 0;
}

my $coverage_before = get_overall();
my $hit_est = $cfg{HITS_PER_TEST_ESTIMATE} || 1;

my @holes;
my @illegals;
my @orphans;

foreach my $k (keys %bin) {
    my $b = $bin{$k};
    if (!exists $cp{$b->{cp}}) {
        push @orphans, $b;
    } elsif ($b->{illegal} eq 'YES' && $b->{hits} > 0) {
        push @illegals, $b;
    } elsif ($b->{illegal} eq 'NO' && $b->{hits} < $goal) {
        my $missing = $goal - $b->{hits};
        my $score = $cp{$b->{cp}}{weight} * $missing;
        $score *= 2 if $b->{hits} == 0;
        $b->{missing} = $missing;
        $b->{score} = $score;
        push @holes, $b;
    }
}

@holes = sort {
    $b->{score} <=> $a->{score} or
    $b->{missing} <=> $a->{missing} or
    $a->{cp} cmp $b->{cp} or
    $a->{name} cmp $b->{name}
} @holes;

@illegals = sort { $a->{cp} cmp $b->{cp} or $a->{name} cmp $b->{name} } @illegals;
@orphans  = sort { $a->{cp} cmp $b->{cp} or $a->{name} cmp $b->{name} } @orphans;

my @plan;
my %type_count;
my %type_tests;
my %mod_count;
my %mod_tests;

my $total_actions = 0;
my $total_tests = 0;
my $current_overall = $coverage_before;

foreach my $h (@holes) {
    my $tests = ceil($h->{missing} / $hit_est);
    my $action_type = $h->{hits} == 0 ? 'DIRECTED_TEST' : 'CONSTRAINT_TUNE';
    my $mod = $cp{$h->{cp}}{module};
    my $reason = $h->{hits} == 0 ? 'zero_hits_recorded' : 'below_hit_goal';
    
    $cp{$h->{cp}}{covered}++;
    $current_overall = get_overall();
    
    push @plan, {
        action => $action_type, cp => $h->{cp}, bin => $h->{name},
        module => $mod, hits => $h->{hits}, missing => $h->{missing},
        tests => $tests, pred => $current_overall, reason => $reason
    };
    
    $type_count{$action_type}++;
    $type_tests{$action_type} += $tests;
    $mod_count{$mod}++;
    $mod_tests{$mod} += $tests;
    $total_actions++;
    $total_tests += $tests;
}

foreach my $i (@illegals) {
    my $mod = $cp{$i->{cp}}{module};
    push @plan, {
        action => 'REMOVE_ILLEGAL_STIMULUS', cp => $i->{cp}, bin => $i->{name},
        module => $mod, hits => $i->{hits}, missing => 0,
        tests => 0, pred => $current_overall, reason => 'illegal_bin_hit'
    };
    $type_count{'REMOVE_ILLEGAL_STIMULUS'}++;
    $mod_count{$mod}++;
    $total_actions++;
}

foreach my $o (@orphans) {
    push @plan, {
        action => 'FIX_COVERAGE_MODEL', cp => $o->{cp}, bin => $o->{name},
        module => 'UNKNOWN', hits => $o->{hits}, missing => 0,
        tests => 0, pred => $current_overall, reason => 'undeclared_coverpoint'
    };
    $type_count{'FIX_COVERAGE_MODEL'}++;
    $mod_count{'UNKNOWN'}++;
    $total_actions++;
}

open(my $out, '>', $out_file) or die "Error: Cannot open $out_file: $!\n";
open(my $txt, '>', $txt_file) or die "Error: Cannot open $txt_file: $!\n";

foreach my $p (@plan) {
    printf $out "FIX ACTION=%s COVERPOINT=%s BIN=%s MODULE=%s HITS=%d MISSING=%d TESTS_NEEDED=%d PREDICTED_OVERALL=%.2f REASON=%s\n",
        $p->{action}, $p->{cp}, $p->{bin}, $p->{module}, $p->{hits}, $p->{missing}, $p->{tests}, $p->{pred}, $p->{reason};
    
    print $txt "$p->{action} $p->{cp} $p->{bin}\n";
}
print $out "\n";

foreach my $t (sort keys %type_count) {
    printf $out "ACTION=%s COUNT=%d TESTS_NEEDED=%d\n", $t, $type_count{$t}, $type_tests{$t} || 0;
}
print $out "\n";

foreach my $m (sort keys %mod_count) {
    printf $out "MODULE=%s ACTIONS=%d TESTS_NEEDED=%d\n", $m, $mod_count{$m}, $mod_tests{$m} || 0;
}
print $out "\n";

my $meets = $current_overall >= ($cfg{OVERALL_TARGET_PERCENT} || 0) ? 'YES' : 'NO';

printf $out "TOTAL_ACTIONS=%d\n", $total_actions;
printf $out "TOTAL_TESTS_NEEDED=%d\n", $total_tests;
printf $out "COVERAGE_BEFORE=%.2f\n", $coverage_before;
printf $out "PREDICTED_OVERALL_COVERAGE=%.2f\n", $current_overall;
printf $out "PREDICTED_UNCOVERED_BINS=0\n";
printf $out "PREDICTED_ILLEGAL_HITS=0\n";
printf $out "OVERALL_TARGET_PERCENT=%.2f\n", $cfg{OVERALL_TARGET_PERCENT} || 0;
printf $out "PLAN_MEETS_TARGET=%s\n", $meets;

close($out);
close($txt);
print "Level 4 complete. Report saved to $out_file\n";
