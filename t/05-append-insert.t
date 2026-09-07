#!/usr/bin/perl
# append/insert placement and ordering, including table-qualified chains.
use strict;
use warnings;
use lib 't/lib';
use GenfwTest;
use Test::More;

my %ifcfg = (
    eth0 => "DEVICE=eth0\nBOOTPROTO=dhcp\n",
    eth1 => "DEVICE=eth1\nIPADDR=192.168.1.1\nNETMASK=255.255.255.0\n",
);

sub run_rules {
    my ($rules) = @_;
    return run_genfw(make_fixture(rules => "int eth1\nout eth0\n$rules", ifcfg => \%ifcfg));
}

# --- append goes after generated rules, insert before them.
{
    my $res = run_rules(<<'RULES');
append INPUT -p tcp --dport 22 -j ACCEPT
insert INPUT -s 10.9.9.9 -j DROP
RULES
    my @input = rules_in($res, 'INPUT');
    is($input[0], '-s 10.9.9.9 -j DROP', 'insert lands first in a built-in chain');
    is($input[1], '-j established', 'generated rules follow the inserts');
    my ($ssh) = grep { $input[$_] eq '-p tcp --dport 22 -j ACCEPT' } 0 .. $#input;
    my ($lo)  = grep { $input[$_] eq '-i lo -j ACCEPT' } 0 .. $#input;
    ok($ssh > $lo, 'append lands after generated early rules');
    is($input[-1], "-m limit -j LOG --log-prefix 'INPUT fall-through: '", 'generated late rules follow appends');
}

# --- Multiple appends keep file order; multiple inserts keep file order too
#     (the script reverses them internally so the first written is first).
{
    my $res = run_rules(<<'RULES');
append INPUT -p tcp --dport 1 -j ACCEPT
append INPUT -p tcp --dport 2 -j ACCEPT
append INPUT -p tcp --dport 3 -j ACCEPT
insert INPUT -p tcp --dport 11 -j ACCEPT
insert INPUT -p tcp --dport 12 -j ACCEPT
insert INPUT -p tcp --dport 13 -j ACCEPT
RULES
    my @input = rules_in($res, 'INPUT');
    is_deeply(
        [@input[0..2]],
        ['-p tcp --dport 13 -j ACCEPT', '-p tcp --dport 12 -j ACCEPT', '-p tcp --dport 11 -j ACCEPT'],
        'inserts are emitted in reverse file order (like repeated iptables -I)',
    );
    is_deeply(
        [grep { /--dport [123] / } @input],
        ['-p tcp --dport 1 -j ACCEPT', '-p tcp --dport 2 -j ACCEPT', '-p tcp --dport 3 -j ACCEPT'],
        'appends keep file order',
    );
}

# --- insert/append on interface chains and pair chains.
{
    my $res = run_rules(<<'RULES');
insert eth1-eth0 -p tcp --dport 25 -j REJECT
append eth1-eth0 -p tcp --dport 26 -j REJECT
insert eth1 -s 192.168.1.99 -j DROP
append eth1 -s 192.168.1.98 -j DROP
RULES
    my @pair = rules_in($res, 'eth1-eth0');
    is($pair[0], '-p tcp --dport 25 -j REJECT', 'insert on a pair chain comes first');
    # On pair chains, "append" is placed after allow= rules and *before* the
    # generated established/icmp/drop tail, so appended rules stay reachable.
    my ($app) = grep { $pair[$_] eq '-p tcp --dport 26 -j REJECT' } 0 .. $#pair;
    my ($est) = grep { $pair[$_] eq '-j established' } 0 .. $#pair;
    ok(defined $app && defined $est && $app < $est, 'append on a pair chain precedes the generated tail');
    is($pair[-1], '-j DROP', 'generated DROP stays last on a pair chain');
    my @iface = rules_in($res, 'eth1');
    is($iface[0], '-s 192.168.1.99 -j DROP', 'insert on an interface chain comes first');
    is($iface[-1], '-s 192.168.1.98 -j DROP', 'append on an interface chain comes last');
}

# --- insert/append on the genfw-defined chains.
{
    my $res = run_rules(<<'RULES');
insert icmp-filter -p icmp --icmp-type echo-request -m limit --limit 5/s -j ACCEPT
append icmp-filter -j DROP
RULES
    is_deeply(
        [rules_in($res, 'icmp-filter')],
        [
            '-p icmp --icmp-type echo-request -m limit --limit 5/s -j ACCEPT',
            '-p icmp -j acceptnew',
            '-j DROP',
        ],
        'insert/append bracket the default rule in a genfw chain',
    );
}

# --- Table-qualified chains.
{
    my $res = run_rules(<<'RULES');
append nat:PREROUTING -i eth1 -p tcp --dport 80 -j REDIRECT --to 3128
insert nat:POSTROUTING -o eth0 -s 192.168.1.5 -j ACCEPT
append mangle:FORWARD -j TTL --ttl-set 64
append raw:PREROUTING -i eth0 -j NOTRACK
append nat:OUTPUT -p tcp --dport 80 -j REDIRECT --to 3128
RULES
    is($res->{status}, 0, 'table-qualified rules exit 0');
    is_deeply(
        [rules_in($res, 'PREROUTING', 'nat')],
        ['-i eth1 -p tcp --dport 80 -j REDIRECT --to 3128'],
        'append nat:PREROUTING',
    );
    is_deeply(
        [rules_in($res, 'POSTROUTING', 'nat')],
        ['-o eth0 -s 192.168.1.5 -j ACCEPT'],
        'insert nat:POSTROUTING with no nat flag yields just the inserted rule',
    );
    is_deeply([rules_in($res, 'FORWARD', 'mangle')], ['-j TTL --ttl-set 64'], 'append mangle:FORWARD');
    is_deeply([rules_in($res, 'PREROUTING', 'raw')], ['-i eth0 -j NOTRACK'], 'append raw:PREROUTING');
    is_deeply([rules_in($res, 'OUTPUT', 'nat')], ['-p tcp --dport 80 -j REDIRECT --to 3128'], 'append nat:OUTPUT');
    # The filter-table OUTPUT chain must not have picked up the nat rule.
    ok(!(grep { /REDIRECT/ } rules_in($res, 'OUTPUT')), 'nat:OUTPUT does not leak into filter OUTPUT');
}

# --- insert into nat:POSTROUTING precedes the generated NAT rule.
{
    my $res = run_genfw(make_fixture(
        rules => "int eth1 nat\nout eth0\ninsert nat:POSTROUTING -o eth0 -s 192.168.1.5 -j ACCEPT\n",
        ifcfg => \%ifcfg,
    ));
    is_deeply(
        [rules_in($res, 'POSTROUTING', 'nat')],
        ['-o eth0 -s 192.168.1.5 -j ACCEPT', '-o eth0 -s 192.168.1.0/255.255.255.0 -j MASQUERADE'],
        'insert precedes the generated MASQUERADE',
    );
}

# --- Explicit "filter:" prefix is equivalent to no prefix.
{
    my $res = run_rules(<<'RULES');
append filter:INPUT -p tcp --dport 8022 -j ACCEPT
insert filter:INPUT -p tcp --dport 8023 -j ACCEPT
append INPUT -p tcp --dport 8024 -j ACCEPT
RULES
    my @input = rules_in($res, 'INPUT');
    ok((grep { /--dport 8022/ } @input), 'append filter:INPUT is honored');
    is($input[0], '-p tcp --dport 8023 -j ACCEPT', 'insert filter:INPUT lands first like insert INPUT');
    my ($a) = grep { $input[$_] =~ /--dport 8022/ } 0 .. $#input;
    my ($b) = grep { $input[$_] =~ /--dport 8024/ } 0 .. $#input;
    ok($a < $b, 'filter:INPUT and INPUT appends share one ordered list');
    ok(!(grep { /-t filter / } @{$res->{rules}}), 'no rule is emitted with an explicit -t filter');
}

# --- Arguments with shell metacharacters are single-quoted in script output.
{
    my $res = run_rules(<<'RULES');
append INPUT -m comment --comment has\ spaces -j ACCEPT
append INPUT -m string --string it's -j DROP
RULES
    my @input = rules_in($res, 'INPUT');
    # "has\ spaces" is split on whitespace by the parser, so the backslash
    # survives as a literal and is quoted; this documents current behavior.
    ok((grep { /--comment 'has\\'/ } @input), 'backslash is quoted, not interpreted');
    TODO: {
        local $TODO = q{iptables() substitutes ' with ''' instead of '\'' so the shell drops the quote};
        ok((grep { /--string 'it'\\''s'/ } @input), "embedded single quote is escaped as '\\''");
    }
}

done_testing;
