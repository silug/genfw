#!/usr/bin/perl
# Reading ifcfg-* files, interface flags (ignore, label, trusted), and
# fatal configuration errors.
use strict;
use warnings;
use lib 't/lib';
use GenfwTest;
use Test::More;

my %ifcfg = (
    eth0 => "DEVICE=eth0\nBOOTPROTO=dhcp\n",
    eth1 => "DEVICE=eth1\nIPADDR=192.168.1.1\nNETMASK=255.255.255.0\n",
    eth2 => "DEVICE=eth2\nIPADDR=10.0.0.1\nNETMASK=255.255.255.0\n",
);

# --- Network and broadcast are calculated from IPADDR/NETMASK.
{
    my $res = run_genfw(make_fixture(
        rules => "int eth1\nout eth0\n",
        ifcfg => { eth0 => $ifcfg{eth0}, eth1 => "DEVICE=eth1\nIPADDR=172.16.5.77\nNETMASK=255.255.240.0\n" },
    ));
    is_deeply(
        [grep { /-j DROP$/ } rules_in($res, 'eth1')],
        ['-d 172.16.0.0 -j DROP', '-d 172.16.15.255 -j DROP'],
        'network and broadcast computed from a non-/24 mask',
    );
}

# --- Quoted values and BOOTPROTO=static/none are accepted.
{
    my $res = run_genfw(make_fixture(
        rules => "int eth1\nout eth0\n",
        ifcfg => { eth0 => $ifcfg{eth0}, eth1 => qq{DEVICE="eth1"\nBOOTPROTO="static"\nIPADDR="192.168.1.1"\nNETMASK="255.255.255.0"\n} },
    ));
    is_deeply($res->{warnings}, [], 'quoted ifcfg values parse without warnings');
    ok((grep { $_ eq '-d 192.168.1.0 -j DROP' } rules_in($res, 'eth1')), 'quoted values are used');
}

# --- Wrong NETWORK/BROADCAST in the file: warn and use the computed value.
{
    my $res = run_genfw(make_fixture(
        rules => "int eth1\nout eth0\n",
        ifcfg => { eth0 => $ifcfg{eth0}, eth1 => "DEVICE=eth1\nIPADDR=192.168.1.1\nNETMASK=255.255.255.0\nNETWORK=192.168.9.0\nBROADCAST=192.168.9.255\n" },
    ));
    ok((grep { /incorrect network address 192\.168\.9\.0/ } @{$res->{warnings}}), 'wrong NETWORK warns');
    ok((grep { /incorrect broadcast address 192\.168\.9\.255/ } @{$res->{warnings}}), 'wrong BROADCAST warns');
    ok((grep { $_ eq '-d 192.168.1.0 -j DROP' } rules_in($res, 'eth1')), 'computed network is used instead');
    ok((grep { $_ eq '-d 192.168.1.255 -j DROP' } rules_in($res, 'eth1')), 'computed broadcast is used instead');
}

# --- DEVICE mismatch and redefined variables warn.
{
    my $res = run_genfw(make_fixture(
        rules => "int eth1\nout eth0\n",
        ifcfg => { eth0 => $ifcfg{eth0}, eth1 => "DEVICE=eth7\nIPADDR=192.168.1.1\nNETMASK=255.255.255.0\nIPADDR=192.168.1.2\n" },
    ));
    ok((grep { /says DEVICE is eth7 not eth1/ } @{$res->{warnings}}), 'DEVICE mismatch warns');
    ok((grep { /eth1 ipaddr redefined/ } @{$res->{warnings}}), 'redefined IPADDR warns');
}

# --- Point-to-point (address == network == broadcast with /32) is skipped.
{
    my $res = run_genfw(make_fixture(
        rules => "int ppp0\nout eth0\n",
        ifcfg => { eth0 => $ifcfg{eth0}, ppp0 => "DEVICE=ppp0\nIPADDR=10.1.1.1\nNETMASK=255.255.255.255\n" },
    ));
    is_deeply([grep { /-j DROP$/ && /-d / } rules_in($res, 'ppp0')], [], 'no address filtering for a /32 interface');
    like($res->{stdout}, qr/Skipping point-to-point address 10\.1\.1\.1/, 'point-to-point skip is commented');
}

# --- Missing ifcfg file for a non-NAT interface is tolerated.
{
    my $res = run_genfw(make_fixture(
        rules => "int eth1\nout eth0\n",
        ifcfg => { eth0 => $ifcfg{eth0} },
    ));
    is($res->{status}, 0, 'missing ifcfg is not fatal without nat');
    is_deeply($res->{warnings}, [], 'missing ifcfg produces no warning without nat');
    ok((grep { $_ eq 'eth1' } chains_created($res)), 'interface chain still created');
}

# --- Missing network-scripts directory is fatal.
{
    my $res = run_genfw(make_fixture(rules => "int eth1\nout eth0\n", no_network_scripts => 1));
    isnt($res->{status}, 0, 'missing network-scripts dir: non-zero exit');
    like($res->{stderr}, qr/Failed to open .*network-scripts/, 'missing network-scripts dir: error message');
}

# --- ignore flag.
{
    my $res = run_genfw(make_fixture(
        rules => "int eth1\nout eth0\ndmz eth2 ignore\n",
        ifcfg => \%ifcfg,
    ));
    my @chains = chains_created($res);
    ok(!(grep { /eth2/ } @chains), 'ignored interface gets no chains');
    ok(!(grep { /eth2/ } @{$res->{rules}}), 'ignored interface appears in no rule');
    ok((grep { $_ eq 'eth1-eth0' } @chains), 'other interfaces unaffected');
}

# --- label flag.
{
    my $res = run_genfw(make_fixture(
        rules => "int eth1 label=inside\nout eth0 label=world\n",
        ifcfg => \%ifcfg,
    ));
    is_deeply(
        [sort grep { !/^(acceptnew|established|icmp-filter)$/ } chains_created($res)],
        [sort 'inside', 'world', 'inside-world', 'world-inside'],
        'labels replace interface names in chain names',
    );
    ok((grep { /--log-prefix "inside -> world: "/ } rules_in($res, 'inside-world')), 'labels used in log prefixes');
    ok((grep { $_ eq '-i eth1 -j inside' } rules_in($res, 'FORWARD')), 'real interface name still used for -i');
    ok((grep { $_ eq '-o eth0 -j inside-world' } rules_in($res, 'inside')), 'real interface name still used for -o');
}
{
    my $res = run_genfw(make_fixture(rules => "int eth1 label=\nout eth0\n", ifcfg => \%ifcfg));
    ok((grep { $_ eq 'eth1-eth0' } chains_created($res)), 'empty label falls back to interface name');
}

# --- Flag parsing: unknown flags warn and are ignored; boolean flags take
#     no value; duplicate labels warn and the first wins; empty allow= is
#     harmless.
{
    my $res = run_genfw(make_fixture(
        rules => "int eth1 nat frobnicate trusted=yes label=in label=other allow=\nout eth0\n",
        ifcfg => \%ifcfg,
    ));
    is($res->{status}, 0, 'bad flags are not fatal');
    ok((grep { /Ignoring unsupported flag 'frobnicate' on interface eth1/ } @{$res->{warnings}}), 'unknown flag warns');
    ok((grep { /Ignoring unsupported flag 'trusted=yes' on interface eth1/ } @{$res->{warnings}}), 'boolean flag with a value warns');
    ok((grep { $_ eq '-j DROP' } rules_in($res, 'in-eth0')), 'trusted=yes did not make the interface trusted');
    ok((grep { /Ignoring duplicate label 'other' on interface eth1 \(using 'in'\)/ } @{$res->{warnings}}), 'duplicate label warns');
    ok((grep { $_ eq 'in' } chains_created($res)), 'first label wins');
    ok(!(grep { $_ eq 'other' } chains_created($res)), 'second label is not used');
    ok((grep { /-j MASQUERADE/ } rules_in($res, 'POSTROUTING', 'nat')), 'valid flags on the same line still apply');
    ok(!(grep { /allow/ } @{$res->{warnings}}), 'empty allow= produces no warning');
    is(scalar(@{$res->{warnings}}), 3, 'exactly the three expected warnings') or diag(join "\n", @{$res->{warnings}});
}

# --- Chain name length limit.
{
    my $res = run_genfw(make_fixture(
        rules => "int eth1 label=a_very_long_label_name\nout eth0 label=another_long_one\n",
        ifcfg => \%ifcfg,
    ));
    isnt($res->{status}, 0, 'over-long pair chain name is fatal');
    like($res->{stderr}, qr/more than 30 characters/, 'over-long chain name: error message');
}

# --- trusted flag.
{
    my $res = run_genfw(make_fixture(
        rules => "int eth1 trusted\nout eth0\n",
        ifcfg => \%ifcfg,
    ));
    is_deeply(
        [rules_in($res, 'eth1-eth0')],
        ['-j established', '-j acceptnew'],
        'trusted int -> out: established then acceptnew, no drop',
    );
    ok((grep { $_ eq '-i eth1 -j ACCEPT' } rules_in($res, 'INPUT')), 'trusted int interface is accepted in INPUT');
    ok((grep { $_ eq '-j DROP' } rules_in($res, 'eth0-eth1')), 'trusted does not open the reverse direction');
}
{
    my $res = run_genfw(make_fixture(
        rules => "int eth1 trusted\ndmz eth2\nout eth0\n",
        ifcfg => \%ifcfg,
    ));
    is_deeply(
        [grep { !/^-d / } rules_in($res, 'eth1-eth2')],
        ['-j established', '-j acceptnew'],
        'trusted int -> dmz is open',
    );
    ok((grep { $_ eq '-j DROP' } rules_in($res, 'eth2-eth1')), 'untrusted dmz -> int is dropped');
}
{
    my $res = run_genfw(make_fixture(
        rules => "int eth1\ndmz eth2 trusted\nout eth0\n",
        ifcfg => \%ifcfg,
    ));
    is_deeply([rules_in($res, 'eth2-eth0')], ['-j established', '-j acceptnew'], 'trusted dmz -> out is open');
    ok((grep { $_ eq '-j DROP' } rules_in($res, 'eth2-eth1')), 'trusted dmz -> int is still dropped');
    ok(!(grep { $_ eq '-i eth2 -j ACCEPT' } rules_in($res, 'INPUT')), 'trusted dmz is not accepted in INPUT');
}

done_testing;
