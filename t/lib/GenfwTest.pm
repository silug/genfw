package GenfwTest;
#
# Test helpers for genfw.
#
# genfw has no module structure, so tests drive it as a black box: build a
# throwaway config tree, run "genfw -d" with that tree as the current
# directory (debug mode reads config from "."), and inspect the generated
# iptables commands on stdout and the warnings on stderr.
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
    fake_iptables
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
#   stdout   - full stdout
#   stderr   - full stderr
#   status   - exit status (0 on success)
#   rules    - arrayref of "iptables ..." lines from stdout, in order
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

    my @rules = grep { /^iptables / } split /\n/, $stdout;
    my @warnings = grep { length && !/^d: / } split /\n/, $stderr;

    return {
        stdout   => $stdout,
        stderr   => $stderr,
        status   => $status,
        rules    => \@rules,
        warnings => \@warnings,
    };
}

# rules_in($result, $chain [, $table])
#
# Returns the argument strings of every "-A $chain" rule in the given table
# (default "filter"), in emission order, with the leading
# "iptables [-t table] -A chain " stripped.
sub rules_in {
    my ($res, $chain, $table) = @_;
    $table ||= 'filter';
    my @found;
    for my $line (@{ $res->{rules} }) {
        my ($t, $c, $rest) = $line =~ /^iptables (?:-t (\S+) )?-A (\S+) (.*)$/
            or next;
        $t ||= 'filter';
        push @found, $rest if $t eq $table && $c eq $chain;
    }
    return @found;
}

# chains_created($result [, $table]) -> list of chains passed to -N
sub chains_created {
    my ($res, $table) = @_;
    $table ||= 'filter';
    my @found;
    for my $line (@{ $res->{rules} }) {
        my ($t, $c) = $line =~ /^iptables (?:-t (\S+) )?-N (\S+)$/ or next;
        $t ||= 'filter';
        push @found, $c if $t eq $table;
    }
    return @found;
}

# fake_iptables() -> ($bindir, $logfile)
#
# Creates a directory containing a fake "iptables" that records its
# arguments, one invocation per line, to $logfile ("$*" form) and to
# "$logfile.argv" with each argument bracketed ("[-A][INPUT][-j][ACCEPT]")
# so argv boundaries can be checked. Prepend $bindir to PATH to exercise
# "genfw -i" without touching the real firewall. Set GENFW_FAKE_EXIT in the
# environment to make the fake exit non-zero.
sub fake_iptables {
    my $bindir = tempdir('genfw-fakebin-XXXXXX', TMPDIR => 1, CLEANUP => 1);
    my $logfile = "$bindir/iptables.log";
    write_file("$bindir/iptables", <<"EOS");
#!/bin/sh
printf '%s\\n' "\$*" >> '$logfile'
for a in "\$@"; do printf '[%s]' "\$a"; done >> '$logfile.argv'
printf '\\n' >> '$logfile.argv'
exit \${GENFW_FAKE_EXIT:-0}
EOS
    chmod 0755, "$bindir/iptables";
    return ($bindir, $logfile);
}

1;
