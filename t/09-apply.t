#!/usr/bin/perl
# Load generated rulesets into a real iptables-restore, inside a private
# network namespace so no privileges and no live firewall are involved, then
# read them back with iptables-save. This is the check that the output is
# something iptables actually accepts, quoting included.
use strict;
use warnings;
use lib 't/lib';
use GenfwTest;
use Test::More;
use Cwd qw(abs_path);
use File::Spec;
use File::Temp qw(tempfile);

for my $tool (qw(iptables-restore iptables-save unshare)) {
    plan skip_all => "$tool not found in PATH" unless grep { -x "$_/$tool" } split /:/, $ENV{PATH};
}

# Returns (exit status, iptables-save output) after loading $text in a fresh
# network namespace.
sub load_and_save {
    my ($text) = @_;
    my ($fh, $file) = tempfile('genfw-apply-XXXXXX', TMPDIR => 1, UNLINK => 1);
    print $fh $text;
    close $fh;
    my $out = qx(unshare -rn sh -c 'iptables-restore < "$file" && iptables-save' 2>&1);
    return ($? >> 8, $out);
}

# Probe with a trivial ruleset. Some environments let unshare succeed and
# iptables-restore exit 0 while the kernel quietly refuses to create tables
# in a nested namespace (legacy iptables inside a container, for one), so
# require the round trip to actually work before trusting any result.
{
    my ($status, $out) = load_and_save("*filter\n:INPUT ACCEPT [0:0]\nCOMMIT\n");
    plan skip_all => 'iptables-restore/iptables-save do not round-trip in an unprivileged namespace here'
        unless $status == 0 && $out =~ /^\*filter$/m && $out =~ /^:INPUT ACCEPT /m;
}

# --- The sample configuration.
{
    my ($vol, $dir) = File::Spec->splitpath(abs_path(__FILE__));
    my $res = run_genfw(File::Spec->catdir($dir, 'sample'));
    is($res->{status}, 0, 'sample generates');

    my ($status, $saved) = load_and_save($res->{stdout});
    is($status, 0, 'iptables-restore loads the sample ruleset') or diag($saved);

    my $generated = scalar @{ $res->{rules} };
    my $loaded = scalar grep { /^-A / } split /\n/, $saved;
    is($loaded, $generated, "iptables-save reports every rule that was generated ($generated)");

    like($saved, qr/^:INPUT DROP /m, 'INPUT policy survived');
    like($saved, qr/^:FORWARD DROP /m, 'FORWARD policy survived');
    like($saved, qr/^:inside-world - /m, 'labelled pair chain exists');
    like($saved, qr/^-A POSTROUTING .* -j MASQUERADE$/m, 'NAT rule survived');
    like($saved, qr/--log-prefix "world -> inside: "/, 'log prefix with spaces survived intact');
}

# --- Awkward arguments: quotes and backslashes must round-trip.
{
    my $res = run_genfw(make_fixture(
        rules => "int eth1\nout eth0\n"
               . "append INPUT -m comment --comment it's -j ACCEPT\n"
               . "append INPUT -m comment --comment 'quoted' -j ACCEPT\n"
               . "append INPUT -m comment --comment back\\slash -j ACCEPT\n"
               . "append INPUT -m comment --comment say\"hi\" -j ACCEPT\n",
        ifcfg => {
            eth0 => "DEVICE=eth0\nBOOTPROTO=dhcp\n",
            eth1 => "DEVICE=eth1\nIPADDR=192.168.1.1\nNETMASK=255.255.255.0\n",
        },
    ));
    is($res->{status}, 0, 'awkward config generates');

    my ($status, $saved) = load_and_save($res->{stdout});
    is($status, 0, 'iptables-restore loads a ruleset with quotes and backslashes') or diag($saved);

    # iptables-save escapes ' as \' and \ as \\ inside comments.
    like($saved, qr/--comment "it\\'s"/, "embedded ' round-trips");
    like($saved, qr/--comment "\\'quoted\\'"/, 'surrounding quotes from the rules file round-trip as literals');
    like($saved, qr/--comment "back\\\\slash"/, 'backslash round-trips');
    like($saved, qr/--comment "say\\"hi\\""/, 'embedded " round-trips');
}

done_testing;
