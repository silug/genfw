#!/usr/bin/perl
# NAT flag: SNAT/MASQUERADE in nat:POSTROUTING and anti-spoofing drops in
# mangle:PREROUTING.
use strict;
use warnings;
use lib 't/lib';
use GenfwTest;
use Test::More;

my %ifcfg = (
    eth1 => "DEVICE=eth1\nIPADDR=192.168.1.1\nNETMASK=255.255.255.0\n",
    eth2 => "DEVICE=eth2\nIPADDR=10.0.0.1\nNETMASK=255.255.0.0\n",
);

# --- Static outside address: SNAT to that address.
{
    my $res = run_genfw(make_fixture(
        rules => "int eth1 nat\nout eth0\n",
        ifcfg => { %ifcfg, eth0 => "DEVICE=eth0\nIPADDR=203.0.113.5\nNETMASK=255.255.255.0\n" },
    ));
    is($res->{status}, 0, 'static outside: exits 0');
    is_deeply(
        [rules_in($res, 'POSTROUTING', 'nat')],
        ['-o eth0 -s 192.168.1.0/255.255.255.0 -j SNAT --to 203.0.113.5'],
        'static outside address gets SNAT --to',
    );
}

# --- DHCP outside address: MASQUERADE.
{
    my $res = run_genfw(make_fixture(
        rules => "int eth1 nat\nout eth0\n",
        ifcfg => { %ifcfg, eth0 => "DEVICE=eth0\nBOOTPROTO=dhcp\n" },
    ));
    is_deeply(
        [rules_in($res, 'POSTROUTING', 'nat')],
        ['-o eth0 -s 192.168.1.0/255.255.255.0 -j MASQUERADE'],
        'dynamic outside address gets MASQUERADE',
    );

    # Anti-spoof: packets arriving on the outside interface destined for the
    # inside network are logged and dropped in mangle:PREROUTING.
    is_deeply(
        [rules_in($res, 'PREROUTING', 'mangle')],
        [
            '-i eth0 -d 192.168.1.0/255.255.255.0 -m limit -j LOG --log-prefix "eth0 -> eth1: bad dest: "',
            '-i eth0 -d 192.168.1.0/255.255.255.0 -j DROP',
        ],
        'mangle PREROUTING drops outside packets addressed to the NATed network',
    );
}

# --- Without the nat flag, nothing is generated in nat or mangle.
{
    my $res = run_genfw(make_fixture(
        rules => "int eth1\nout eth0\n",
        ifcfg => { %ifcfg, eth0 => "DEVICE=eth0\nBOOTPROTO=dhcp\n" },
    ));
    is_deeply([rules_in($res, 'POSTROUTING', 'nat')], [], 'no nat flag: no POSTROUTING rules');
    is_deeply([rules_in($res, 'PREROUTING', 'mangle')], [], 'no nat flag: no mangle rules');
}

# --- Two NATed inside interfaces, one outside: a rule per inside network.
{
    my $res = run_genfw(make_fixture(
        rules => "int eth1 nat\ndmz eth2 nat\nout eth0\n",
        ifcfg => { %ifcfg, eth0 => "DEVICE=eth0\nBOOTPROTO=dhcp\n" },
    ));
    is_deeply(
        [sort +rules_in($res, 'POSTROUTING', 'nat')],
        [sort
            '-o eth0 -s 192.168.1.0/255.255.255.0 -j MASQUERADE',
            '-o eth0 -s 10.0.0.0/255.255.0.0 -j MASQUERADE',
        ],
        'each NATed interface gets its own POSTROUTING rule',
    );
}

# --- nat on an outside interface does nothing (only int/dmz -> out is NATed).
{
    my $res = run_genfw(make_fixture(
        rules => "int eth1\nout eth0 nat\n",
        ifcfg => { %ifcfg, eth0 => "DEVICE=eth0\nBOOTPROTO=dhcp\n" },
    ));
    is_deeply([rules_in($res, 'POSTROUTING', 'nat')], [], 'nat flag on outside interface generates nothing');
}

# --- Aliased inside interface on a second subnet gets its own NAT rule.
{
    my $res = run_genfw(make_fixture(
        rules => "int eth1 nat\nout eth0\n",
        ifcfg => {
            %ifcfg,
            'eth1:1' => "DEVICE=eth1:1\nIPADDR=172.16.0.1\nNETMASK=255.255.255.0\n",
            eth0 => "DEVICE=eth0\nBOOTPROTO=dhcp\n",
        },
    ));
    is_deeply(
        [sort +rules_in($res, 'POSTROUTING', 'nat')],
        [sort
            '-o eth0 -s 192.168.1.0/255.255.255.0 -j MASQUERADE',
            '-o eth0 -s 172.16.0.0/255.255.255.0 -j MASQUERADE',
        ],
        'aliased interface (ifcfg-eth1:1) contributes a NAT rule',
    );
}

# --- nat with no ifcfg for the inside interface warns.
{
    my $res = run_genfw(make_fixture(
        rules => "int eth1 nat\nout eth0\n",
        ifcfg => { eth0 => "DEVICE=eth0\nBOOTPROTO=dhcp\n" },
    ));
    ok((grep { /No addresses known for interface eth1/ } @{$res->{warnings}}),
        'warns when a NATed interface has no ifcfg file');
}

done_testing;
