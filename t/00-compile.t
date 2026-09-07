#!/usr/bin/perl
# Syntax and documentation checks.
use strict;
use warnings;
use lib 't/lib';
use GenfwTest;
use Test::More;

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

# $VERSION in the script must match Version: in the spec.
my ($script_version) = read_file($genfw) =~ /^our \$VERSION\s*=\s*"([^"]+)"/m;
my ($spec_version) = read_file("$genfw.spec") =~ /^Version:\s*(\S+)/m;
ok(defined $script_version, "found \$VERSION ($script_version) in genfw");
ok(defined $spec_version, "found Version: ($spec_version) in genfw.spec");
is($script_version, $spec_version, 'genfw and genfw.spec agree on version');

done_testing;
