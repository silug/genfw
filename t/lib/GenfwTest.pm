package GenfwTest;
#
# Test helpers for genfw.
#
# genfw has no module structure, so tests drive it as a black box: build a
# throwaway config tree, run "genfw -d" with that tree as the current
# directory (debug mode reads config from "."), and inspect the generated
# iptables-restore ruleset on stdout and the warnings on stderr.
#
# Only modules that ship with the base Fedora perl package are used here.
#
use strict;
use warnings;

use Cwd qw(abs_path getcwd);
use File::Spec;
use File::Temp qw(tempdir tempfile);

# Note for test authors: write "sort +rules_in(...)" -- without the "+",
# perl parses rules_in as a sort comparator.
use Exporter 'import';
our @EXPORT = qw(
    genfw_path
    make_fixture
    run_genfw
    rules_in
    chains_created
    policy_of
    fake_iptables_restore
    fake_ip
    read_file
);

# Absolute path to the genfw script under test.
sub genfw_path {
    my ($vol, $dir) = File::Spec->splitpath(abs_path(__FILE__));
    return abs_path(File::Spec->catfile($dir, '..', '..', 'genfw'));
}

# Write a file, creating parent directories as needed.
sub write_file {
    my ($path, $content) = @_;
    my ($vol, $dir) = File::Spec->splitpath($path);
    my $sofar = '';
    for my $part (File::Spec->splitdir($dir)) {
        next if $part eq '';
        $sofar = $sofar eq '' ? "/$part" : "$sofar/$part";
        mkdir $sofar unless -d $sofar;
    }
    open my $fh, '>', $path or die "Can't write $path: $!";
    print $fh $content;
    close $fh;
}

sub read_file {
    my ($path) = @_;
    open my $fh, '<', $path or return '';
    local $/;
    my $content = <$fh>;
    close $fh;
    return $content;
}

# make_fixture(
#     rules => "...",                 # contents of genfw/rules (omit for none)
#     ifcfg => { eth0 => "...", ... }, # network-scripts/ifcfg-<name>
#     files => { 'genfw/rules.d/x.rules' => "...", ... },
#     no_network_scripts => 1,        # don't create network-scripts/
# )
# Returns the fixture directory (removed at exit).
sub make_fixture {
    my %spec = @_;
    my $dir = tempdir('genfw-test-XXXXXX', TMPDIR => 1, CLEANUP => 1);

    mkdir "$dir/genfw";
    mkdir "$dir/network-scripts" unless $spec{no_network_scripts};

    write_file("$dir/genfw/rules", $spec{rules}) if defined $spec{rules};

    for my $iface (sort keys %{ $spec{ifcfg} || {} }) {
        write_file("$dir/network-scripts/ifcfg-$iface", $spec{ifcfg}{$iface});
    }
    for my $rel (sort keys %{ $spec{files} || {} }) {
        write_file("$dir/$rel", $spec{files}{$rel});
    }
    return $dir;
}

# run_genfw($dir, opts => [...], env => {...})
#
# Runs genfw in $dir. Returns a hashref:
#   stdout   - full stdout (an iptables-restore file)
#   stderr   - full stderr
#   status   - exit status (0 on success)
#   rules    - arrayref of every "-A chain args" line, all tables, in order
#   tables   - hashref: table name => {
#                chains    => [user chains declared, in order],
#                policy    => { builtin chain => target },
#                rules     => [ [chain, args], ... ] in order,
#                committed => 1 if the table block ended with COMMIT }
#   warnings - arrayref of stderr lines that are not debug tracing
sub run_genfw {
    my ($dir, %args) = @_;
    my @opts = @{ $args{opts} || ['-d'] };
    my $genfw = genfw_path();
    my (undef, $errfile) = tempfile('genfw-stderr-XXXXXX', TMPDIR => 1, UNLINK => 1);

    local %ENV = (%ENV, %{ $args{env} || {} });

    my $cmd = "cd '$dir' && exec perl '$genfw' " . join(' ', @opts)
            . " 2>'$errfile'";
    my $stdout = qx($cmd);
    my $status = $? >> 8;
    my $stderr = read_file($errfile);

    my @warnings = grep { length && !/^d: / } split /\n/, $stderr;

    my (%tables, @rules, $table);
    for my $line (split /\n/, $stdout) {
        if ($line =~ /^\*(\w+)$/) {
            $table = $1;
            $tables{$table} = { chains => [], policy => {}, rules => [], committed => 0 };
        } elsif (!defined $table) {
            next;
        } elsif ($line =~ /^:(\S+) (\S+) \[\d+:\d+\]$/) {
            if ($2 eq '-') {
                push @{ $tables{$table}{chains} }, $1;
            } else {
                $tables{$table}{policy}{$1} = $2;
            }
        } elsif ($line =~ /^-A (\S+) (.*)$/) {
            push @{ $tables{$table}{rules} }, [$1, $2];
            push @rules, $line;
        } elsif ($line eq 'COMMIT') {
            $tables{$table}{committed} = 1;
            $table = undef;
        }
    }

    return {
        stdout   => $stdout,
        stderr   => $stderr,
        status   => $status,
        rules    => \@rules,
        tables   => \%tables,
        warnings => \@warnings,
    };
}

# rules_in($result, $chain [, $table])
#
# Returns the argument strings of every "-A $chain" rule in the given table
# (default "filter"), in emission order, with "-A chain " stripped.
sub rules_in {
    my ($res, $chain, $table) = @_;
    $table ||= 'filter';
    my $t = $res->{tables}{$table} or return;
    return map { $_->[1] } grep { $_->[0] eq $chain } @{ $t->{rules} };
}

# chains_created($result [, $table]) -> user chains declared, in order
sub chains_created {
    my ($res, $table) = @_;
    $table ||= 'filter';
    my $t = $res->{tables}{$table} or return;
    return @{ $t->{chains} };
}

# policy_of($result, $chain [, $table]) -> policy target, or undef if unset
sub policy_of {
    my ($res, $chain, $table) = @_;
    $table ||= 'filter';
    my $t = $res->{tables}{$table} or return;
    return $t->{policy}{$chain};
}

# fake_iptables_restore() -> ($bindir, $logfile)
#
# Creates a directory containing a fake "iptables-restore" that appends
# everything it reads on stdin to $logfile and its arguments, one
# invocation per line, to "$logfile.args". Prepend $bindir to PATH to
# exercise "genfw -i" without touching the real firewall. Set
# GENFW_FAKE_EXIT in the environment to make every invocation exit
# non-zero, or GENFW_FAKE_EXIT_LOAD to fail only the real (non --test)
# load.
sub fake_iptables_restore {
    my $bindir = tempdir('genfw-fakebin-XXXXXX', TMPDIR => 1, CLEANUP => 1);
    my $logfile = "$bindir/iptables-restore.log";
    write_file("$bindir/iptables-restore", <<"EOS");
#!/bin/sh
printf '%s\\n' "\$*" >> '$logfile.args'
cat >> '$logfile'
if [ -n "\$GENFW_FAKE_EXIT" ]; then exit "\$GENFW_FAKE_EXIT"; fi
if [ "\$*" != "--test" ] && [ -n "\$GENFW_FAKE_EXIT_LOAD" ]; then exit "\$GENFW_FAKE_EXIT_LOAD"; fi
exit 0
EOS
    chmod 0755, "$bindir/iptables-restore";
    return ($bindir, $logfile);
}

# fake_ip(%devices) -> ($bindir, $logfile)
#
# Creates a directory containing a fake "ip" that answers
# "ip -o -4 addr show dev NAME" with the canned text given for NAME in
# %devices (in ip -o format), exits 1 with ip's "does not exist" message for
# any other device, and logs each invocation's arguments to $logfile.
# Prepend $bindir to PATH to exercise the "ip" address source without
# depending on the host's interfaces.
sub fake_ip {
    my %devices = @_;
    my $bindir = tempdir('genfw-fakeip-XXXXXX', TMPDIR => 1, CLEANUP => 1);
    my $devdir = "$bindir/devices";
    mkdir $devdir;
    for my $dev (keys %devices) {
        write_file("$devdir/$dev", $devices{$dev});
    }
    my $logfile = "$bindir/ip.log";
    write_file("$bindir/ip", <<"EOS");
#!/bin/sh
printf '%s\\n' "\$*" >> '$logfile'
dev=""
while [ \$# -gt 0 ]; do
    if [ "\$1" = dev ]; then dev="\$2"; fi
    shift
done
if [ -n "\$dev" ] && [ -f '$devdir'/"\$dev" ]; then
    cat '$devdir'/"\$dev"
    exit 0
fi
echo "Device \\"\$dev\\" does not exist." >&2
exit 1
EOS
    chmod 0755, "$bindir/ip";
    return ($bindir, $logfile);
}

1;
