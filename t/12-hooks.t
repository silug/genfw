#!/usr/bin/perl
# The dispatcher hooks in hooks/ must call "systemctl try-restart
# genfw.service" on the events that mean an interface came up, and nothing
# on any other event. A fake systemctl on PATH records what they run.
use strict;
use warnings;
use lib 't/lib';
use GenfwTest;
use Test::More;
use File::Temp qw(tempdir);
use File::Spec;
use Cwd qw(abs_path);

my ($vol, $dir) = File::Spec->splitpath(abs_path(__FILE__));
my $hooks = File::Spec->catdir($dir, '..', 'hooks');

my $bindir = tempdir('genfw-fakesystemctl-XXXXXX', TMPDIR => 1, CLEANUP => 1);
my $log = "$bindir/systemctl.log";
GenfwTest::write_file("$bindir/systemctl", "#!/bin/sh\nprintf '%s\\n' \"\$*\" >> '$log'\nexit \${GENFW_FAKE_EXIT:-0}\n");
chmod 0755, "$bindir/systemctl";

# run($hook, \@args, \%env) -> (exit status, systemctl calls)
sub run_hook {
    my ($hook, $args, $env) = @_;
    unlink $log;
    local %ENV = (%ENV, PATH => "$bindir:$ENV{PATH}", %{ $env || {} });
    system("$hooks/$hook", @$args);
    my $status = $? >> 8;
    my @calls = -f $log ? grep { length } split /\n/, read_file($log) : ();
    return ($status, \@calls);
}

for my $hook (qw(NetworkManager-dispatcher networkd-dispatcher if-up)) {
    ok(-x "$hooks/$hook", "hooks/$hook is executable");
    like(read_file("$hooks/$hook"), qr/\A#!\/bin\/sh\n/, "hooks/$hook is a POSIX sh script");
}

# NetworkManager: $1 interface, $2 action.
{
    for my $action (qw(up vpn-up)) {
        my ($status, $calls) = run_hook('NetworkManager-dispatcher', ['eth0', $action]);
        is($status, 0, "NetworkManager $action: exits 0");
        is_deeply($calls, ['try-restart genfw.service'], "NetworkManager $action: try-restarts genfw.service");
    }
    for my $action (qw(pre-up down pre-down vpn-down dhcp4-change dhcp6-change connectivity-change hostname dns-change device-add device-delete reapply)) {
        my ($status, $calls) = run_hook('NetworkManager-dispatcher', ['eth0', $action]);
        is($status, 0, "NetworkManager $action: exits 0");
        is_deeply($calls, [], "NetworkManager $action: does nothing");
    }
    # A failing systemctl is reported to NetworkManager, which logs it.
    my ($status) = run_hook('NetworkManager-dispatcher', ['eth0', 'up'], { GENFW_FAKE_EXIT => 5 });
    is($status, 5, 'NetworkManager up: systemctl failure propagates');
}

# networkd-dispatcher: STATE in the environment.
{
    my ($status, $calls) = run_hook('networkd-dispatcher', [], { STATE => 'routable', IFACE => 'eth0' });
    is($status, 0, 'networkd routable: exits 0');
    is_deeply($calls, ['try-restart genfw.service'], 'networkd routable: try-restarts genfw.service');
    for my $state (qw(dormant no-carrier off carrier degraded configuring configured)) {
        ($status, $calls) = run_hook('networkd-dispatcher', [], { STATE => $state, IFACE => 'eth0' });
        is_deeply($calls, [], "networkd $state: does nothing");
    }
    ($status, $calls) = run_hook('networkd-dispatcher', [], {});
    is_deeply($calls, [], 'networkd with no STATE: does nothing');
}

# ifupdown: MODE and IFACE in the environment.
{
    my ($status, $calls) = run_hook('if-up', [], { MODE => 'start', IFACE => 'eth0' });
    is_deeply($calls, ['try-restart genfw.service'], 'ifupdown start: try-restarts genfw.service');
    ($status, $calls) = run_hook('if-up', [], { MODE => 'stop', IFACE => 'eth0' });
    is_deeply($calls, [], 'ifupdown stop: does nothing');
    ($status, $calls) = run_hook('if-up', [], { IFACE => 'eth0' });
    is_deeply($calls, ['try-restart genfw.service'], 'ifupdown with no MODE (older ifupdown): treated as start');
}

# The unit files exist and say what the hooks rely on.
{
    my $root = File::Spec->catdir($dir, '..');
    my $early = read_file("$root/genfw.service");
    my $late  = read_file("$root/genfw-online.service");
    like($early, qr/^Before=network-pre\.target/m, 'genfw.service runs before network-pre.target');
    like($early, qr/^Wants=network-pre\.target/m, 'genfw.service pulls in network-pre.target');
    like($early, qr/^RemainAfterExit=yes/m, 'genfw.service stays active so try-restart has something to restart');
    like($late,  qr/^After=network-online\.target genfw\.service/m, 'genfw-online.service runs after the network is online and after the early pass');
    like($late,  qr/^Wants=network-online\.target/m, 'genfw-online.service pulls in network-online.target');
    like($late,  qr/^Requires=genfw\.service/m, 'genfw-online.service starts the early pass if it is not active');
    unlike($late, qr/^Requisite=/m, 'genfw-online.service does not use Requisite, which fails instead of starting');
    for my $unit ($early, $late) {
        like($unit, qr{^ExecStart=/usr/sbin/genfw -i$}m, 'unit runs genfw -i');
        like($unit, qr/^WantedBy=multi-user\.target/m, 'unit is enabled into multi-user.target');
    }
}

done_testing;
