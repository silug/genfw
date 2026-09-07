#!/usr/bin/perl
# The allow= flag grammar: port[/proto][:src[:dst[:iface]]], comma-separated.
use strict;
use warnings;
use lib 't/lib';
use GenfwTest;
use Test::More;

# allow= resolves names through /etc/services and /etc/protocols. Without
# them (a bare container without Fedora's "setup" or Debian's "netbase"
# package) nothing here can pass.
plan skip_all => 'getservbyname() cannot resolve ssh/tcp: /etc/services missing? (install setup or netbase)'
    unless getservbyname('ssh', 'tcp') && getservbyname('domain', 'udp') && getprotobyname('gre');

my %ifcfg = (
    eth0 => "DEVICE=eth0\nBOOTPROTO=dhcp\n",
    eth1 => "DEVICE=eth1\nIPADDR=192.168.1.1\nNETMASK=255.255.255.0\n",
    eth2 => "DEVICE=eth2\nIPADDR=10.0.0.1\nNETMASK=255.255.255.0\n",
);

# Run with a dmz interface carrying the given allow= flag and return the
# acceptnew rules generated for out -> dmz, plus the full result.
sub allow_rules {
    my ($flag) = @_;
    my $res = run_genfw(make_fixture(
        rules => "out eth0\ndmz eth2 $flag\n",
        ifcfg => { eth0 => $ifcfg{eth0}, eth2 => $ifcfg{eth2} },
    ));
    my @accept = grep { /-j acceptnew$/ } rules_in($res, 'eth0-eth2');
    return (\@accept, $res);
}

{
    my ($r) = allow_rules('allow=ssh/tcp');
    is_deeply($r, ['-p tcp --dport ssh -j acceptnew'], 'port/proto by service name');
}
{
    my ($r) = allow_rules('allow=22/tcp');
    is_deeply($r, ['-p tcp --dport 22 -j acceptnew'], 'numeric port/proto');
}
{
    # A bare service name defined for both tcp and udp yields both.
    my ($r) = allow_rules('allow=domain');
    is_deeply(
        [sort @$r],
        [sort '-p tcp --dport domain -j acceptnew', '-p udp --dport domain -j acceptnew'],
        'bare service name expands to every protocol in /etc/services',
    );
}
{
    my ($r) = allow_rules('allow=gre');
    is_deeply($r, ['-p gre -j acceptnew'], 'bare protocol name from /etc/protocols, no port');
}
{
    my ($r, $res) = allow_rules('allow=22');
    is_deeply($r, [], 'bare numeric port is not allowed');
    ok((grep { /ambiguous allow '22'/ } @{$res->{warnings}}), 'bare numeric port warns as ambiguous');
}
{
    my ($r, $res) = allow_rules('allow=nosuchservice');
    is_deeply($r, [], 'unknown bare name generates nothing');
    ok((grep { /ambiguous allow 'nosuchservice'/ } @{$res->{warnings}}), 'unknown bare name warns');
}
{
    my ($r, $res) = allow_rules('allow=nosuchservice/tcp');
    is_deeply($r, [], 'unknown service with proto generates nothing');
    ok((grep { /invalid port\/proto 'nosuchservice\/tcp'/ } @{$res->{warnings}}), 'unknown service/proto warns');
}
{
    my ($r) = allow_rules('allow=ssh/tcp,80/tcp,domain/udp');
    is_deeply(
        $r,
        [
            '-p tcp --dport ssh -j acceptnew',
            '-p tcp --dport 80 -j acceptnew',
            '-p udp --dport domain -j acceptnew',
        ],
        'comma-separated list, in order',
    );
}
{
    my ($r) = allow_rules('allow=ssh/tcp:198.51.100.0/24');
    is_deeply($r, ['-p tcp --dport ssh -s 198.51.100.0/24 -j acceptnew'], 'source address restriction');
}
{
    my ($r) = allow_rules('allow=ssh/tcp::10.0.0.5');
    is_deeply($r, ['-p tcp --dport ssh -d 10.0.0.5 -j acceptnew'], 'destination address restriction (empty source)');
}
{
    my ($r) = allow_rules('allow=ssh/tcp:198.51.100.1:10.0.0.5');
    is_deeply($r, ['-p tcp --dport ssh -s 198.51.100.1 -d 10.0.0.5 -j acceptnew'], 'source and destination');
}
{
    # Source interface restriction: eth0 matches, eth1 does not.
    my $res = run_genfw(make_fixture(
        rules => "out eth0\nint eth1\ndmz eth2 allow=ssh/tcp:::eth0\n",
        ifcfg => \%ifcfg,
    ));
    is_deeply(
        [grep { /acceptnew$/ } rules_in($res, 'eth0-eth2')],
        ['-p tcp --dport ssh -j acceptnew'],
        'allow restricted to eth0 appears in eth0 -> dmz',
    );
    is_deeply(
        [grep { /acceptnew$/ } rules_in($res, 'eth1-eth2')],
        [],
        'allow restricted to eth0 is absent from eth1 -> dmz',
    );
}
{
    # allow rules come after network/broadcast filtering and before
    # established/icmp/drop.
    my $res = run_genfw(make_fixture(
        rules => "out eth0\ndmz eth2 allow=ssh/tcp\n",
        ifcfg => { eth0 => $ifcfg{eth0}, eth2 => $ifcfg{eth2} },
    ));
    is_deeply(
        [rules_in($res, 'eth0-eth2')],
        [
            "-d 10.0.0.0 -m limit -j LOG --log-prefix 'eth0-eth2: network: '",
            '-d 10.0.0.0 -j DROP',
            "-d 10.0.0.255 -m limit -j LOG --log-prefix 'eth0-eth2: broadcast: '",
            '-d 10.0.0.255 -j DROP',
            '-p tcp --dport ssh -j acceptnew',
            '-j established',
            '-j icmp-filter',
            '-p tcp --dport 113 -j REJECT --reject-with tcp-reset',
            '-p udp --dport 113 -j REJECT --reject-with icmp-port-unreachable',
            "-m limit -j LOG --log-prefix 'eth0 -> eth2: '",
            '-j DROP',
        ],
        'allow rules sit between address filtering and the standard tail',
    );
}
{
    # Multiple allow= flags on one interface are all honored.
    my ($r) = allow_rules('allow=ssh/tcp allow=80/tcp');
    is_deeply(
        $r,
        ['-p tcp --dport ssh -j acceptnew', '-p tcp --dport 80 -j acceptnew'],
        'multiple allow= flags on one line',
    );
}
{
    # allow= is read from the *destination* interface, so it has no effect
    # on traffic leaving that interface.
    my $res = run_genfw(make_fixture(
        rules => "out eth0\ndmz eth2 allow=ssh/tcp\n",
        ifcfg => { eth0 => $ifcfg{eth0}, eth2 => $ifcfg{eth2} },
    ));
    is_deeply([grep { /acceptnew$/ } rules_in($res, 'eth2-eth0')], [], 'allow= does not open the reverse direction');
}

done_testing;
