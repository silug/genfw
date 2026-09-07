#!/usr/bin/perl
# End-to-end shape of the generated script for a typical two-interface
# NAT gateway: static inside interface, DHCP outside interface.
use strict;
use warnings;
use lib 't/lib';
use GenfwTest;
use Test::More;

my $dir = make_fixture(
    rules => <<'RULES',
int eth1 nat
out eth0
RULES
    ifcfg => {
        eth0 => "DEVICE=eth0\nBOOTPROTO=dhcp\n",
        eth1 => "DEVICE=eth1\nIPADDR=192.168.1.1\nNETMASK=255.255.255.0\n",
    },
);
my $res = run_genfw($dir);

is($res->{status}, 0, 'genfw exits 0');
is_deeply($res->{warnings}, [], 'no warnings') or diag(join "\n", @{$res->{warnings}});
like($res->{stdout}, qr/\A#!\/bin\/sh\n/, 'output starts with a shell shebang');

# Default policies.
my @policy = grep { /-P / } @{$res->{rules}};
is_deeply(
    [sort @policy],
    [sort 'iptables -P INPUT DROP', 'iptables -P OUTPUT ACCEPT', 'iptables -P FORWARD DROP'],
    'default policies: INPUT DROP, OUTPUT ACCEPT, FORWARD DROP',
);

# Policies must be set before the flush so a reload fails closed.
my ($first_policy) = grep { $res->{rules}[$_] =~ /-P / } 0 .. $#{$res->{rules}};
my ($flush) = grep { $res->{rules}[$_] eq 'iptables -F' } 0 .. $#{$res->{rules}};
ok(defined $flush && $first_policy < $flush, 'policies are set before flushing');

# Every table is flushed and user chains deleted.
for my $t ('', '-t nat ', '-t mangle ', '-t raw ') {
    ok((grep { $_ eq "iptables ${t}-F" } @{$res->{rules}}), "flush: iptables ${t}-F");
    ok((grep { $_ eq "iptables ${t}-X" } @{$res->{rules}}), "delete chains: iptables ${t}-X");
}
ok((grep { $_ eq 'iptables -Z' } @{$res->{rules}}), 'counters zeroed');

# Built-in genfw chains and their contents.
my @chains = chains_created($res);
is_deeply(
    [@chains[0..2]],
    ['acceptnew', 'established', 'icmp-filter'],
    'genfw-defined chains created first, in order',
);
is_deeply([rules_in($res, 'acceptnew')], ['-m state --state NEW -j ACCEPT'], 'acceptnew chain');
is_deeply([rules_in($res, 'established')], ["-m state --state 'ESTABLISHED,RELATED' -j ACCEPT"], 'established chain');
is_deeply([rules_in($res, 'icmp-filter')], ['-p icmp -j acceptnew'], 'icmp-filter chain');

# Per-pair and per-interface chains.
is_deeply(
    [sort @chains[3..$#chains]],
    [sort 'eth1-eth0', 'eth0-eth1', 'eth1', 'eth0'],
    'one chain per interface and one per ordered pair',
);

# Untrusted int -> out gets the standard filter sequence.
is_deeply(
    [rules_in($res, 'eth1-eth0')],
    [
        '-j established',
        '-j icmp-filter',
        '-p tcp --dport 113 -j REJECT --reject-with tcp-reset',
        '-p udp --dport 113 -j REJECT --reject-with icmp-port-unreachable',
        "-m limit -j LOG --log-prefix 'eth1 -> eth0: '",
        '-j DROP',
    ],
    'int -> out (untrusted): established, icmp, ident reject, log, drop',
);

# out -> int filters traffic to the inside network and broadcast address.
my @out_in = rules_in($res, 'eth0-eth1');
is($out_in[0], "-d 192.168.1.0 -m limit -j LOG --log-prefix 'eth0-eth1: network: '", 'log traffic to network address');
is($out_in[1], '-d 192.168.1.0 -j DROP', 'drop traffic to network address');
is($out_in[2], "-d 192.168.1.255 -m limit -j LOG --log-prefix 'eth0-eth1: broadcast: '", 'log traffic to broadcast address');
is($out_in[3], '-d 192.168.1.255 -j DROP', 'drop traffic to broadcast address');
is($out_in[-1], '-j DROP', 'out -> int ends in DROP');

# Per-interface chain dispatches on -o.
my @eth1 = rules_in($res, 'eth1');
ok((grep { $_ eq '-o eth1 -j ACCEPT' } @eth1), 'traffic originating on eth1 back out eth1 is accepted');
ok((grep { $_ eq '-o eth0 -j eth1-eth0' } @eth1), 'eth1 -> eth0 dispatches to pair chain');
is_deeply(
    [sort +rules_in($res, 'eth0')],
    [sort '-o eth1 -j eth0-eth1', '-o eth0 -j ACCEPT'],
    'DHCP interface has no network/broadcast filtering, only dispatch',
);

# Built-in chains.
my @input = rules_in($res, 'INPUT');
is($input[0], '-j established', 'INPUT starts with established');
is($input[1], '-i lo -j ACCEPT', 'INPUT accepts loopback');
is($input[-1], "-m limit -j LOG --log-prefix 'INPUT fall-through: '", 'INPUT logs fall-through when policy is DROP');

is_deeply(
    [rules_in($res, 'OUTPUT')],
    ['-j established', '-j icmp-filter'],
    'OUTPUT: established and icmp only, no fall-through log since policy is ACCEPT',
);

# Interface iteration order comes from a hash, so compare as a set.
my @forward = rules_in($res, 'FORWARD');
is_deeply(
    [sort @forward[0..1]],
    [sort '-i eth1 -j eth1', '-i eth0 -j eth0'],
    'FORWARD dispatches per input interface',
);
is($forward[-1], "-m limit -j LOG --log-prefix 'FORWARD fall-through: '", 'FORWARD logs fall-through');

done_testing;
