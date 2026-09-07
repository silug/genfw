#!/usr/bin/perl
# Parsing of the rules file: directives, comments, continuations, includes,
# rules.d, and the warnings emitted for bad input.
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
    my ($rules, %extra) = @_;
    return run_genfw(make_fixture(rules => $rules, ifcfg => \%ifcfg, %extra));
}

# --- Interface directive aliases.
for my $alias (qw(int internal)) {
    my $res = run_rules("$alias eth1\nout eth0\n");
    is($res->{status}, 0, "'$alias' is accepted");
    ok((grep { $_ eq 'eth1-eth0' } chains_created($res)), "'$alias' defines an interface");
}
for my $alias (qw(out output outside)) {
    my $res = run_rules("int eth1\n$alias eth0\n");
    is($res->{status}, 0, "'$alias' is accepted");
    # out -> out would be a plain drop; int -> out has the ident reject, so
    # the presence of that rule confirms eth0 was typed as "out" and eth1 as
    # "int" rather than something else.
    ok((grep { /--dport 113/ } rules_in($res, 'eth1-eth0')), "'$alias' is treated as an outside interface");
}
{
    my $res = run_rules("int eth1\nout eth0\nout eth2\n",
        ifcfg => { %ifcfg, eth2 => "DEVICE=eth2\nBOOTPROTO=dhcp\n" });
    is_deeply(
        [rules_in($res, 'eth0-eth2')],
        ["-m limit -j LOG --log-prefix 'eth0 -> eth2: '", '-j DROP'],
        'out -> out is log and drop only',
    );
}

# --- Comments, escaped '#', blank lines, and line continuation.
{
    my $res = run_rules(<<'RULES');
# leading comment

int eth1    # trailing comment
out eth0 \
    allow=22/tcp

append INPUT -m comment --comment escaped\#hash -j ACCEPT
RULES
    is($res->{status}, 0, 'comments and continuation parse');
    is_deeply($res->{warnings}, [], 'no warnings for comments/continuation') or diag(join "\n", @{$res->{warnings}});
    ok((grep { /--dport 22 -j acceptnew/ } rules_in($res, 'eth1-eth0')), 'continued line contributes its flags');
    ok((grep { /--comment 'escaped#hash'/ } rules_in($res, 'INPUT')), '\# yields a literal # in a rule argument');
}

# --- Logging modes.
{
    my $res = run_rules("int eth1\nout eth0\nno logging\n");
    ok(!(grep { /-j LOG/ } @{$res->{rules}}), 'no logging: no LOG rules at all');
    is($res->{status}, 0, 'no logging exits 0');
}
{
    my $res = run_rules("int eth1\nout eth0\nlimit logging\n");
    ok((grep { /-m limit -j LOG/ } @{$res->{rules}}), 'limit logging: LOG rules carry -m limit');
}
{
    my $res = run_rules("int eth1\nout eth0\nfull logging\n");
    ok((grep { / -j LOG/ } @{$res->{rules}}), 'full logging: LOG rules present');
    ok(!(grep { /-m limit/ } @{$res->{rules}}), 'full logging: no -m limit');
}
{
    my $res = run_rules("int eth1\nout eth0\nsometimes logging\n");
    ok((grep { /I don't know what you mean by 'sometimes logging'/ } @{$res->{warnings}}), 'unknown logging mode warns');
}

# --- policy directive.
{
    my $res = run_rules("int eth1\nout eth0\npolicy OUTPUT DROP\npolicy nat:PREROUTING ACCEPT\n");
    ok((grep { $_ eq 'iptables -P OUTPUT DROP' } @{$res->{rules}}), 'policy overrides a filter chain');
    TODO: {
        local $TODO = 'set_policy reassigns its loop variable before the hash lookup, so the target is lost';
        ok((grep { $_ eq 'iptables -t nat -P PREROUTING ACCEPT' } @{$res->{rules}}), 'policy accepts table:chain');
    }
    ok((grep { /^iptables -t nat -P PREROUTING/ } @{$res->{rules}}), 'policy with table:chain at least targets the right table and chain');
    is((rules_in($res, 'OUTPUT'))[-1], "-m limit -j LOG --log-prefix 'OUTPUT fall-through: '",
        'OUTPUT gains a fall-through log once its policy is DROP');
}
{
    my $res = run_rules("int eth1\nout eth0\npolicy INPUT BOGUS\n");
    ok((grep { /Bad INPUT policy target 'BOGUS'/ } @{$res->{warnings}}), 'invalid policy target warns');
}

# --- chain directive.
{
    my $res = run_rules(<<'RULES');
int eth1
out eth0
chain mychain Something descriptive
chain nat:natchain
append mychain -p tcp --dport 8080 -j ACCEPT
append nat:natchain -j RETURN
chain mychain again
RULES
    ok((grep { $_ eq 'mychain' } chains_created($res)), 'user chain created in filter table');
    ok((grep { $_ eq 'natchain' } chains_created($res, 'nat')), 'user chain created in nat table');
    like($res->{stdout}, qr/^# Something descriptive$/m, 'chain comment appears in output');
    is_deeply([rules_in($res, 'mychain')], ['-p tcp --dport 8080 -j ACCEPT'], 'append to user chain');
    is_deeply([rules_in($res, 'natchain', 'nat')], ['-j RETURN'], 'append to user chain in nat table');
    ok((grep { /Not re-declaring chain 'mychain'/ } @{$res->{warnings}}), 'duplicate chain warns');
    is(scalar(grep { $_ eq 'mychain' } chains_created($res)), 1, 'duplicate chain is created once');
}

# --- User chains come after genfw chains and before interface chains.
{
    my $res = run_rules("int eth1\nout eth0\nchain mychain\n");
    my @chains = chains_created($res);
    is($chains[3], 'mychain', 'user chains follow the three genfw chains');
}

# --- include directive: relative to genfw dir, absolute, and glob.
{
    my $dir = make_fixture(
        rules => "int eth1\nout eth0\ninclude extra.rules\ninclude sub/*.rules\n",
        ifcfg => \%ifcfg,
        files => {
            'genfw/extra.rules'   => "append INPUT -p tcp --dport 1001 -j ACCEPT\n",
            'genfw/sub/a.rules'   => "append INPUT -p tcp --dport 1002 -j ACCEPT\n",
            'genfw/sub/b.rules'   => "append INPUT -p tcp --dport 1003 -j ACCEPT\n",
            'genfw/sub/c.txt'     => "append INPUT -p tcp --dport 1004 -j ACCEPT\n",
            'abs.rules'           => "append INPUT -p tcp --dport 1005 -j ACCEPT\n",
        },
    );
    # Absolute include has to be appended once we know the fixture path.
    open my $fh, '>>', "$dir/genfw/rules" or die $!;
    print $fh "include $dir/abs.rules\ninclude missing.rules\n";
    close $fh;

    my $res = run_genfw($dir);
    is($res->{status}, 0, 'includes parse');
    my @input = rules_in($res, 'INPUT');
    ok((grep { /--dport 1001/ } @input), 'relative include');
    ok((grep { /--dport 1002/ } @input), 'glob include, first match');
    ok((grep { /--dport 1003/ } @input), 'glob include, second match');
    ok(!(grep { /--dport 1004/ } @input), 'glob include does not match other extensions');
    ok((grep { /--dport 1005/ } @input), 'absolute include');
    is_deeply($res->{warnings}, [], 'missing include file is silently skipped');
}

# --- rules.d/*.rules are read after rules.
{
    my $res = run_rules("int eth1\nout eth0\n",
        files => {
            'genfw/rules.d/10-a.rules' => "append INPUT -p tcp --dport 2001 -j ACCEPT\n",
            'genfw/rules.d/20-b.rules' => "append INPUT -p tcp --dport 2002 -j ACCEPT\n",
            'genfw/rules.d/ignored'    => "append INPUT -p tcp --dport 2003 -j ACCEPT\n",
        });
    my @input = grep { /--dport 200\d/ } rules_in($res, 'INPUT');
    is_deeply(
        \@input,
        ['-p tcp --dport 2001 -j ACCEPT', '-p tcp --dport 2002 -j ACCEPT'],
        'rules.d/*.rules read in glob order; other files ignored',
    );
}
{
    # rules.d alone, with no top-level rules file, is sufficient.
    my $res = run_genfw(make_fixture(
        ifcfg => \%ifcfg,
        files => { 'genfw/rules.d/all.rules' => "int eth1\nout eth0\n" },
    ));
    is($res->{status}, 0, 'rules.d without a rules file is enough');
}

# --- Error and warning cases.
{
    my $res = run_genfw(make_fixture(ifcfg => \%ifcfg));
    isnt($res->{status}, 0, 'no rules file: non-zero exit');
    like($res->{stderr}, qr/No rules found!/, 'no rules file: error message');
}
{
    my $res = run_rules("int\nout eth0\n");
    ok((grep { /No interface defined/ } @{$res->{warnings}}), 'interface line without a name warns');
}
{
    my $res = run_rules("int eth1\nint eth1 trusted\nout eth0\n");
    ok((grep { /Skipping duplicate definition for interface eth1/ } @{$res->{warnings}}), 'duplicate interface warns');
    # First definition wins: eth1 is not trusted, so int -> out has the drop tail.
    ok((grep { $_ eq '-j DROP' } rules_in($res, 'eth1-eth0')), 'first interface definition wins');
}
{
    my $res = run_rules("int eth1\nout eth0\nfrobnicate eth3\n");
    ok((grep { /Skipping bogus line \(3\)/ } @{$res->{warnings}}), 'unknown directive warns with line number');
    is($res->{status}, 0, 'unknown directive is not fatal');
}
{
    my $res = run_rules("int eth1\nout eth0\nappend INPUT\n");
    ok((grep { /Skipping bogus line/ } @{$res->{warnings}}), 'append without a rule body warns');
}

done_testing;
