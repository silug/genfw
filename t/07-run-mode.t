#!/usr/bin/perl
# "-i" mode runs iptables directly instead of printing a script. A fake
# iptables on PATH records what would have been executed.
use strict;
use warnings;
use lib 't/lib';
use GenfwTest;
use Test::More;

my %ifcfg = (
    eth0 => "DEVICE=eth0\nBOOTPROTO=dhcp\n",
    eth1 => "DEVICE=eth1\nIPADDR=192.168.1.1\nNETMASK=255.255.255.0\n",
);
my $rules = "int eth1 nat\nout eth0\nappend INPUT -m comment --comment word -j ACCEPT\n";

# Interface iteration order comes from hash order, which differs between
# perl processes unless the seed is pinned. Pin it so two runs can be
# compared line by line.
my %stable = (PERL_HASH_SEED => 0, PERL_PERTURB_KEYS => 0);

# Script mode output, for comparison.
my $script = run_genfw(make_fixture(rules => $rules, ifcfg => \%ifcfg), env => { %stable });

{
    my ($bindir, $log) = fake_iptables();
    my $res = run_genfw(
        make_fixture(rules => $rules, ifcfg => \%ifcfg),
        opts => ['-i', '-d'],
        env  => { %stable, PATH => "$bindir:$ENV{PATH}" },
    );
    is($res->{status}, 0, '-i exits 0');
    is($res->{stdout}, '', '-i prints nothing to stdout');

    my @ran = grep { length } split /\n/, read_file($log);
    ok(@ran > 0, 'fake iptables was invoked');

    # Every command from script mode should have been executed, in order.
    # Script mode shell-quotes arguments; -i passes them as argv, so strip
    # quoting for the comparison.
    my @expected = map { my $s = $_; $s =~ s/^iptables //; $s =~ s/'//g; $s } @{$script->{rules}};
    is_deeply(\@ran, \@expected, '-i executes the same commands as script mode emits');

    # Arguments containing spaces (generated log prefixes) must reach
    # iptables as a single argv element, not be re-split by a shell.
    my $argv = read_file("$log.argv");
    like($argv, qr/\[--log-prefix\]\[INPUT fall-through: \]/, 'log prefix with spaces is one argv element');
    like($argv, qr/\[--state\]\[ESTABLISHED,RELATED\]/, 'comma-separated state list is one argv element');
}

# iptables failures are warnings, not fatal.
{
    my ($bindir, $log) = fake_iptables();
    my $res = run_genfw(
        make_fixture(rules => $rules, ifcfg => \%ifcfg),
        opts => ['-i', '-d'],
        env  => { PATH => "$bindir:$ENV{PATH}", GENFW_FAKE_EXIT => 3 },
    );
    is($res->{status}, 0, 'iptables failures do not abort genfw');
    my @failed = grep { /failed with exit value 3/ } @{$res->{warnings}};
    my @ran = grep { length } split /\n/, read_file($log);
    is(scalar @failed, scalar @ran, 'every failed iptables call produces a warning');
}

# Script mode without -d reads from /etc/sysconfig; we can't test that
# directly, but -d alone must not require -i.
{
    my $res = run_genfw(make_fixture(rules => $rules, ifcfg => \%ifcfg), opts => ['-d']);
    like($res->{stdout}, qr/^#!\/bin\/sh/, 'script mode emits a shell script');
    like($res->{stdout}, qr/^# /m, 'script mode includes comments');
}

# DEBUG in the environment behaves like -d.
{
    my $res = run_genfw(make_fixture(rules => $rules, ifcfg => \%ifcfg), opts => [], env => { DEBUG => 1 });
    is($res->{status}, 0, 'DEBUG=1 reads config from the current directory');
    like($res->{stderr}, qr/^d: /m, 'DEBUG=1 emits debug tracing');
    like($res->{stderr}, qr/\$VAR1 = \{/, 'DEBUG=1 dumps the interface table');
}

done_testing;
