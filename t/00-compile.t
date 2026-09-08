#!/usr/bin/perl
# Syntax and documentation checks.
use strict;
use warnings;
use lib 't/lib';
use GenfwTest;
use Test::More;
use File::Spec;

my $genfw = genfw_path();
ok(-f $genfw, "found genfw at $genfw");
ok(-x $genfw, 'genfw is executable');

my $out = qx(perl -c '$genfw' 2>&1);
is($? >> 8, 0, 'perl -c genfw succeeds') or diag($out);
like($out, qr/syntax OK/, 'perl -c reports syntax OK');

SKIP: {
    eval { require Test::Pod; Test::Pod->import };
    skip 'Test::Pod not installed (perl-Test-Pod)', 1 if $@;
    pod_file_ok($genfw, 'POD in genfw is well-formed');
}

# The man page is built with pod2man at package build time.
SKIP: {
    my $pod2man = qx(command -v pod2man 2>/dev/null);
    skip 'pod2man not available', 2 unless $pod2man;
    my $man = qx(pod2man '$genfw' 2>&1);
    is($? >> 8, 0, 'pod2man genfw succeeds');
    like($man, qr/\.TH GENFW/i, 'pod2man output has a title header');
}

# $VERSION in the script must match Version: in the spec and the top entry
# of debian/changelog (whose version carries a "-N" Debian revision).
my ($script_version) = read_file($genfw) =~ /^our \$VERSION\s*=\s*"([^"]+)"/m;
my ($spec_version) = read_file("$genfw.spec") =~ /^Version:\s*(\S+)/m;
my ($vol, $dir) = File::Spec->splitpath($genfw);
my ($deb_version) = read_file(File::Spec->catfile($dir, 'debian', 'changelog')) =~ /^genfw \(([^)]+)\)/;
ok(defined $script_version, "found \$VERSION ($script_version) in genfw");
ok(defined $spec_version, "found Version: ($spec_version) in genfw.spec");
ok(defined $deb_version, "found version ($deb_version) in debian/changelog");
is($script_version, $spec_version, 'genfw and genfw.spec agree on version');
like($deb_version, qr/^\Q$script_version\E-\d+$/, 'debian/changelog is the same version with a Debian revision');

done_testing;
