#!/usr/bin/perl
# Where the configuration directory comes from: -c, then /etc/genfw, then
# the historical /etc/sysconfig/genfw. The /etc precedence is tested by
# bind-mounting a fixture over /etc in a private mount namespace, which
# needs unshare(1) and is skipped where that is not allowed.
use strict;
use warnings;
use lib 't/lib';
use GenfwTest;
use Test::More;
use File::Temp qw(tempdir);
use Cwd qw(getcwd);

my %ifcfg = (
    eth0 => "DEVICE=eth0\nBOOTPROTO=dhcp\n",
    eth1 => "DEVICE=eth1\nIPADDR=192.168.1.1\nNETMASK=255.255.255.0\n",
);

# --- -c points somewhere other than ./genfw in debug mode.
{
    my $dir = make_fixture(
        rules => "int eth1\nout eth0\nappend INPUT -p tcp --dport 1 -j ACCEPT\n",
        ifcfg => \%ifcfg,
        files => {
            'alt/rules'               => "int eth1\nout eth0\nappend INPUT -p tcp --dport 2 -j ACCEPT\ninclude extra.rules\n",
            'alt/rules.d/more.rules'  => "append INPUT -p tcp --dport 3 -j ACCEPT\n",
            'alt/extra.rules'         => "append INPUT -p tcp --dport 4 -j ACCEPT\n",
        },
    );
    my $res = run_genfw($dir, opts => ['-d', '-c', "$dir/alt"]);
    is($res->{status}, 0, '-c with -d generates');
    my @input = rules_in($res, 'INPUT');
    ok(!(grep { /--dport 1 / } @input), './genfw/rules is not read when -c is given');
    ok((grep { /--dport 2 / } @input), 'rules come from the -c directory');
    ok((grep { /--dport 3 / } @input), 'rules.d comes from the -c directory');
    ok((grep { /--dport 4 / } @input), 'relative include resolves against the -c directory');
    ok((grep { $_ eq '-d 192.168.1.0 -j DROP' } rules_in($res, 'eth1')), 'network-scripts still come from the current directory in debug mode');
}

# --- -c without -d: the normal code path, with ip for addresses so nothing
#     depends on the host.
{
    my $dir = make_fixture(
        files => { 'conf/rules' => "addresses ip\nint eth1\nout eth0\n" },
        no_network_scripts => 1,
    );
    my ($bindir) = fake_ip(
        eth1 => "3: eth1    inet 192.168.1.1/24 brd 192.168.1.255 scope global eth1\\       valid_lft forever preferred_lft forever\n",
    );
    my $res = run_genfw($dir, opts => ['-c', "$dir/conf"], env => { PATH => "$bindir:$ENV{PATH}" });
    is($res->{status}, 0, '-c without -d generates');
    is_deeply($res->{warnings}, [], 'no warnings') or diag(join "\n", @{$res->{warnings}});
    ok((grep { $_ eq '-d 192.168.1.0 -j DROP' } rules_in($res, 'eth1')), 'rules and addresses both found');
    like($res->{stdout}, qr/^\*filter$/m, 'output is a ruleset, not debug-mode text');
}

# --- Errors.
{
    my $dir = make_fixture(rules => "int eth1\nout eth0\n", ifcfg => \%ifcfg);
    my $res = run_genfw($dir, opts => ['-d', '-c', "$dir/nowhere"]);
    isnt($res->{status}, 0, '-c with a missing directory is fatal');
    like($res->{stderr}, qr{Configuration directory \S+/nowhere does not exist}, 'and names it');

    $res = run_genfw($dir, opts => ['-d', '-x']);
    isnt($res->{status}, 0, 'an unknown option is fatal');
    like($res->{stderr}, qr/Usage: genfw \[-c config-dir\] \[-d\] \[-i\]/, 'with a usage line');

    my $empty = make_fixture(files => { 'conf/.keep' => '' });
    $res = run_genfw($empty, opts => ['-d', '-c', "$empty/conf"]);
    isnt($res->{status}, 0, 'a config directory without rules is fatal');
    like($res->{stderr}, qr{No rules found in \S+/conf!}, 'and the error names the directory searched');
}

# --- Default locations, by bind-mounting a fixture over /etc.
SKIP: {
    skip 'unshare not found', 8 unless grep { -x "$_/unshare" } split /:/, $ENV{PATH};
    my $probe = tempdir('genfw-etc-XXXXXX', TMPDIR => 1, CLEANUP => 1);
    my $out = qx(unshare -rm sh -c 'mount --bind "$probe" /etc && ls /etc' 2>&1);
    skip 'cannot bind-mount over /etc in an unprivileged mount namespace here', 8
        if $? != 0 || $out =~ /\S/;

    my $genfw = genfw_path();

    # Build a fake /etc: network-scripts for the ifcfg source, plus the rules
    # directories requested, each with a distinguishable rule.
    my $etc = sub {
        my (%dirs) = @_;
        my $root = tempdir('genfw-etc-XXXXXX', TMPDIR => 1, CLEANUP => 1);
        for my $iface (keys %ifcfg) {
            GenfwTest::write_file("$root/sysconfig/network-scripts/ifcfg-$iface", $ifcfg{$iface});
        }
        for my $d (keys %dirs) {
            GenfwTest::write_file("$root/$d/rules", "int eth1\nout eth0\nappend INPUT -p tcp --dport $dirs{$d} -j ACCEPT\n");
        }
        return $root;
    };
    my $run = sub {
        my ($root) = @_;
        my $errfile = "$root.stderr";
        my $stdout = qx(unshare -rm sh -c 'mount --bind "$root" /etc && exec perl "$genfw"' 2>"$errfile");
        my $status = $? >> 8;
        my @warnings = grep { length && !/^d: / } split /\n/, read_file($errfile);
        my @rules = grep { /^-A / } split /\n/, $stdout;
        return ($status, \@rules, \@warnings);
    };

    # Only the historical directory: used, silently.
    {
        my ($status, $rules, $warnings) = $run->($etc->('sysconfig/genfw' => 1001));
        is($status, 0, 'only /etc/sysconfig/genfw: generates');
        ok((grep { /--dport 1001 / } @$rules), 'only /etc/sysconfig/genfw: its rules are used');
        is_deeply($warnings, [], 'only /etc/sysconfig/genfw: no warning');
    }
    # Only the canonical directory.
    {
        my ($status, $rules) = $run->($etc->('genfw' => 1002));
        is($status, 0, 'only /etc/genfw: generates');
        ok((grep { /--dport 1002 / } @$rules), 'only /etc/genfw: its rules are used');
    }
    # Both: /etc/genfw wins and the other is reported.
    {
        my ($status, $rules, $warnings) = $run->($etc->('genfw' => 1003, 'sysconfig/genfw' => 1004));
        ok((grep { /--dport 1003 / } @$rules) && !(grep { /--dport 1004 / } @$rules), 'both present: /etc/genfw wins');
        ok((grep { m{Using configuration in /etc/genfw; ignoring /etc/sysconfig/genfw} } @$warnings), 'both present: warns about the ignored directory');
    }
    # Neither: the error names the canonical location.
    {
        my ($status, $rules, $warnings) = $run->($etc->());
        isnt($status, 0, 'neither present: fatal');
    }
}

done_testing;
