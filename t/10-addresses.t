#!/usr/bin/perl
# Interface address sources: the Red Hat ifcfg files and the running system
# via "ip -o -4 addr show". A fake ip on PATH supplies canned output so the
# tests do not depend on the host's interfaces.
use strict;
use warnings;
use lib 't/lib';
use GenfwTest;
use Test::More;
use File::Temp qw(tempdir);

my $rules = "int eth1 nat\ndmz eth2\nout eth0\n";
my %stable = (PERL_HASH_SEED => 0, PERL_PERTURB_KEYS => 0);

# The same three interfaces described both ways.
my %ifcfg = (
    eth0     => "DEVICE=eth0\nBOOTPROTO=dhcp\n",
    eth1     => "DEVICE=eth1\nIPADDR=192.168.1.1\nNETMASK=255.255.255.0\n",
    'eth1:1' => "DEVICE=eth1:1\nIPADDR=192.168.2.1\nNETMASK=255.255.255.0\n",
    eth2     => "DEVICE=eth2\nIPADDR=10.0.0.1\nNETMASK=255.255.255.0\n",
);
my %ip = (
    eth0 => "2: eth0    inet 203.0.113.7/24 brd 203.0.113.255 scope global dynamic noprefixroute eth0\\       valid_lft 3542sec preferred_lft 3542sec\n",
    eth1 => "3: eth1    inet 192.168.1.1/24 brd 192.168.1.255 scope global eth1\\       valid_lft forever preferred_lft forever\n"
          . "3: eth1    inet 192.168.2.1/24 brd 192.168.2.255 scope global secondary eth1:1\\       valid_lft forever preferred_lft forever\n",
    eth2 => "4: eth2    inet 10.0.0.1/24 brd 10.0.0.255 scope global eth2\\       valid_lft forever preferred_lft forever\n",
);

# --- Parity: ifcfg and ip describing the same network give the same rules.
{
    my $from_ifcfg = run_genfw(make_fixture(rules => $rules, ifcfg => \%ifcfg), env => { %stable });
    is($from_ifcfg->{status}, 0, 'ifcfg source generates');

    my ($bindir, $log) = fake_ip(%ip);
    my $from_ip = run_genfw(
        make_fixture(rules => $rules, no_network_scripts => 1),
        env => { %stable, PATH => "$bindir:$ENV{PATH}" },
    );
    is($from_ip->{status}, 0, 'ip source generates');
    is_deeply($from_ip->{warnings}, [], 'ip source produces no warnings') or diag(join "\n", @{$from_ip->{warnings}});
    like($from_ip->{stderr}, qr/^d: Interface addresses from 'ip' \(auto-detected\)/m, 'ip is chosen automatically when there are no ifcfg files');
    is($from_ip->{stdout}, $from_ifcfg->{stdout}, 'identical rulesets from ifcfg files and from ip');

    my @calls = split /\n/, read_file($log);
    is_deeply([sort @calls], [sort map { "-o -4 addr show dev $_" } qw(eth0 eth1 eth2)], 'ip is asked once per interface, IPv4 only, one-line format');

    ok((grep { /-j MASQUERADE/ } rules_in($from_ip, 'POSTROUTING', 'nat')), 'dynamic outside address means MASQUERADE, as BOOTPROTO=dhcp did');
    ok((grep { $_ eq '-d 192.168.2.0 -j DROP' } rules_in($from_ip, 'eth1')), 'secondary address contributes network filtering like an alias file');
}

# --- Explicit selection.
{
    # ifcfg files exist but say something different; "addresses ip" wins.
    my ($bindir) = fake_ip(%ip, eth2 => "4: eth2    inet 10.9.9.1/24 brd 10.9.9.255 scope global eth2\\       valid_lft forever preferred_lft forever\n");
    my $res = run_genfw(
        make_fixture(rules => "addresses ip\n$rules", ifcfg => \%ifcfg),
        env => { PATH => "$bindir:$ENV{PATH}" },
    );
    is($res->{status}, 0, 'addresses ip with ifcfg files present');
    ok((grep { $_ eq '-d 10.9.9.0 -j DROP' } rules_in($res, 'eth2')), 'addresses ip overrides the ifcfg files');
    ok(!(grep { /10\.0\.0\./ } @{$res->{rules}}), 'ifcfg addresses are not used when ip is selected');
}
{
    my ($bindir) = fake_ip(%ip);
    my $res = run_genfw(
        make_fixture(rules => "addresses ifcfg\n$rules", ifcfg => \%ifcfg),
        env => { PATH => "$bindir:$ENV{PATH}" },
    );
    ok((grep { $_ eq '-d 10.0.0.0 -j DROP' } rules_in($res, 'eth2')), 'addresses ifcfg uses the files');
    ok(!(grep { /203\.0\.113/ } @{$res->{rules}}), 'ip is not consulted when ifcfg is selected');
}
{
    my $res = run_genfw(make_fixture(rules => "addresses ifcfg\n$rules", no_network_scripts => 1));
    isnt($res->{status}, 0, 'addresses ifcfg without network-scripts is fatal');
    like($res->{stderr}, qr/Failed to open .*network-scripts/, 'and says why');
}
{
    my $res = run_genfw(make_fixture(rules => "addresses dhcpcd\n$rules", ifcfg => \%ifcfg));
    ok((grep { /Unknown address source 'dhcpcd' \(line 1\); expected 'ifcfg' or 'ip'/ } @{$res->{warnings}}), 'unknown address source warns');
    is($res->{status}, 0, 'and falls back to the default');
}

# --- Edge cases in ip output.
{
    my ($bindir) = fake_ip(
        eth0 => $ip{eth0},
        # Point-to-point /32 addresses: no brd, network == broadcast == address.
        ppp0 => "5: ppp0    inet 10.1.1.1 peer 10.1.1.2/32 scope global ppp0\\       valid_lft forever preferred_lft forever\n"
              . "5: ppp0    inet 10.1.1.9/32 scope global ppp0\\       valid_lft forever preferred_lft forever\n",
        # No brd on a /8 (like lo): broadcast is computed.
        eth1 => "3: eth1    inet 10.0.0.1/8 scope global eth1\\       valid_lft forever preferred_lft forever\n",
    );
    my $res = run_genfw(
        make_fixture(rules => "int eth1\nint ppp0\nout eth0\n", no_network_scripts => 1),
        env => { PATH => "$bindir:$ENV{PATH}" },
    );
    is($res->{status}, 0, 'edge cases generate');
    is_deeply($res->{warnings}, [], 'edge cases produce no warnings') or diag(join "\n", @{$res->{warnings}});
    ok((grep { $_ eq '-d 10.255.255.255 -j DROP' } rules_in($res, 'eth1')), 'broadcast computed from the prefix when ip prints no brd');
    ok((grep { $_ eq '-d 10.0.0.0 -j DROP' } rules_in($res, 'eth1')), 'network computed from a /8');
    ok(!(grep { /^-d / } rules_in($res, 'ppp0')), 'no network/broadcast filtering for /32 addresses');
    like($res->{stdout}, qr/Skipping point-to-point address 10\.1\.1\.9/, 'a /32 address is recognised as point-to-point');
    like($res->{stderr}, qr/Skipping unexpected ip output for ppp0/, 'the "peer" form is skipped with a debug note rather than misparsed');
}

# --- A device ip does not know is like a missing ifcfg file.
{
    my ($bindir) = fake_ip(eth0 => $ip{eth0});
    my $res = run_genfw(
        make_fixture(rules => "int eth1\nout eth0\n", no_network_scripts => 1),
        env => { PATH => "$bindir:$ENV{PATH}" },
    );
    is($res->{status}, 0, 'unknown device is not fatal');
    is_deeply($res->{warnings}, [], 'unknown device gives no warning without nat');
    ok((grep { $_ eq 'eth1' } chains_created($res)), 'its chains are still created');

    $res = run_genfw(
        make_fixture(rules => "int eth1 nat\nout eth0\n", no_network_scripts => 1),
        env => { PATH => "$bindir:$ENV{PATH}" },
    );
    ok((grep { /No addresses known for interface eth1/ } @{$res->{warnings}}), 'unknown device with nat warns, as a missing ifcfg did');
}

# --- No ip command at all.
{
    my $bindir = tempdir('genfw-noip-XXXXXX', TMPDIR => 1, CLEANUP => 1);
    for my $tool (qw(perl sh cat grep)) {
        my ($path) = grep { -x "$_/$tool" } split /:/, $ENV{PATH};
        symlink("$path/$tool", "$bindir/$tool") if $path;
    }
    my $res = run_genfw(
        make_fixture(rules => "int eth1\nout eth0\n", no_network_scripts => 1),
        env => { PATH => $bindir },
    );
    is($res->{status}, 0, 'missing ip command is not fatal');
    ok((grep { /The ip command was not found/ } @{$res->{warnings}}), 'missing ip command warns');
}

done_testing;
