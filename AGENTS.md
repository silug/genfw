# AGENTS.md

Guidance for AI coding agents working in this repository.

## What this is

`genfw` is a single-file Perl script (no modules) that generates an iptables
firewall from a small text `rules` file plus the host's interface addresses,
read from Red Hat-style `ifcfg-*` files or from `ip -o -4 addr show`. The user documentation is the POD at the
bottom of `genfw` (`perldoc ./genfw`); it covers every rules directive and
interface flag and is the source for the man page.

**Minimum Perl is 5.16 (EL7).** EL7 and EL8 are the only platforms genfw
fully supports today, since they still ship `network-scripts` and the
iptables compatibility layer, so nothing newer than 5.16 may be used in
`genfw` or `t/`: no signatures, no postfix dereferencing, no `say`. The EL7
job in CI enforces this; check there before assuming a construct is fine.

Everything else is packaging or testing: `genfw.spec` and `genfw.rpmlintrc`
(RPM), `debian/` (Debian package; built with `dpkg-buildpackage -us -uc -b`,
the suite runs inside the build), `genfw.service` and `genfw-online.service` (the two-pass boot: before
`network-pre.target`, then after `network-online.target`), `hooks/` (network
dispatcher hooks that `systemctl try-restart genfw.service` when an
interface comes up; one per stack, each inert where its stack is absent),
`firewall.init` (legacy SysV init), `install.sh`, `Makefile`, the test suite
in `t/`, and CI in `.github/workflows/test.yml`. `TODO` is the upstream
wishlist.

## Commands

```sh
make test                     # run the test suite (prove if installed, else plain perl)
prove -v t/03-allow.t         # one test file, verbose (run from the repo root)

perl -c genfw                 # syntax check
perlcritic genfw t/lib/GenfwTest.pm t/*.t   # style check; CI enforces this, config in .perlcriticrc
perldoc ./genfw               # read the docs / verify POD renders

make dist                     # tarball + .src.rpm in cwd (version parsed from $VERSION in genfw)
make install                  # runs install.sh (installs to /usr/local, SysV init; needs root)
```

The lint and RPM-build commands CI uses are in `.github/workflows/test.yml`;
run the same ones locally rather than inventing variants. Every job there can
be reproduced in a podman container with the same package installs.

Fedora splits core perl into many small packages, so a fresh machine usually
lacks some. The per-distro lists are the `install:` lines in the workflow;
the spec's `BuildRequires` is the packaging view. If a module or tool is
missing, say which package provides it (`dnf provides`) and wait for it to be
installed; don't code around it.

Running locally without touching the live firewall:

```sh
./genfw -d > out.sh                  # or DEBUG=1 ./genfw
cd t/sample && perl ../../genfw -d   # against the checked-in sample config
```

`-d` (or `DEBUG` in the environment) points the config and sysconfig
directories at `.`; `-c DIR` overrides the config directory in either mode.
Without either, the config directory is `/etc/genfw` if it exists, else the
historical `/etc/sysconfig/genfw` (kept until a major version; the RPM still
ships that directory). See the option handling at the top of `genfw` for
exactly what is read. Without `-i`, genfw prints an `iptables-restore` ruleset to
stdout. With `-i` (what the systemd unit and init script use) it pipes that
same text to `iptables-restore` and prints nothing. Never run `-i` casually:
the ruleset lists every table, so loading it replaces the whole firewall.

## Git workflow

All changes go through a branch and a pull request on
`github.com/silug/genfw`; never push to `master` directly. Check
`git config push.default` before pushing: this clone has had it set to
`tracking`, which makes `git checkout -b X origin/master` followed by
`git push -u origin X` push to **master**. Safe pattern:

```sh
git checkout -b my-branch --no-track origin/master
git push origin HEAD:refs/heads/my-branch      # explicit refspec
git ls-remote --heads origin my-branch          # confirm before gh pr create
```

PR descriptions here state what was verified and how. Wait for
`gh pr checks N --watch` and report the real result.

## Tests

genfw has no module structure, so the suite in `t/` treats it as a black box:
build a throwaway config tree, run `genfw -d` against it, inspect the emitted
`iptables` lines and the warnings. The helpers that do this are in
`t/lib/GenfwTest.pm`, each documented in a comment above it; read that file
before writing a test. Each `t/*.t` opens with a comment saying what it
covers (`head -3 t/*.t`). Nothing in the suite touches the real firewall or
needs root; `-i` mode runs against a recording `iptables-restore` stub, and
`t/09-apply.t` loads rulesets into a real `iptables-restore` inside an
unprivileged network namespace (`unshare -rn`), skipping where that is not
allowed.

The tests double as the precise specification of generated output. When a
question is "what order do rules come out in" or "what does flag X do", the
answer is an `is_deeply` in `t/`, not this file. In particular
`t/09-apply.t` is the check that the output is something iptables really
accepts, quoting included; any change to the formatter must keep it green
(run it on a host where `unshare -rn` works, or rely on the EL7 and RPM jobs
in CI, which load the sample ruleset with real `iptables-restore` binaries).

Gotchas that have already cost time, each also noted where it applies:

- Interface iteration follows Perl hash order, which differs between
  processes. See the `%stable` handling in `t/07-run-mode.t` for how to pin
  it when two runs must match; otherwise compare as sorted lists.
- `sort +rules_in(...)`, not `sort rules_in(...)`; see the note at the top
  of `t/lib/GenfwTest.pm`.
- Tests that need `/etc/services` guard themselves with `plan skip_all`;
  use numeric `port/proto` elsewhere so nothing else depends on it.

Convention: a bug found but not fixed in the same change gets its failing
assertion inside a `TODO:` block so the suite stays green and the bug is
documented; drop the wrapper when fixing it. `grep -rn TODO t/` shows what is
outstanding.

## Release procedure

`$VERSION` in `genfw`, `Version:` in `genfw.spec`, and the top entry of
`debian/changelog` (as `<version>-1`) must agree; `t/00-compile.t` enforces
it, and the release workflow refuses a tag that does not match all three. A
release is:

1. A PR that bumps all three and adds a `%changelog` entry in the same form
   as the existing ones plus a `debian/changelog` entry (mind the weekday;
   lintian checks it).
2. After it merges, a signed tag `v<version>` on master, pushed. Creating
   the release in the GitHub UI instead also works; it creates the tag.
3. Approving the `release` environment when the workflow asks.

`.github/workflows/release.yml` then builds one portable noarch RPM on EL8
(the oldest platform with usable images; no dist tag, and building on the
oldest target is what keeps the package installable on EL7) and a `.deb` on
Debian stable, GPG-signs the RPMs and tarball with the key from the
`release` environment (the `.deb` is covered by a checksum file and the
attestation, not a per-file signature; apt signs repositories, not
packages), installs the results on EL7, EL9, Fedora, Debian, and Ubuntu,
attests provenance, and publishes the assets. A tag
with a suffix (`v1.51-rc1`) is a prerelease and may run without the signing
key; a real release requires it. Nothing in that workflow can be tested
without pushing a tag, so use a `-rc` tag to rehearse.

The license identifier in the spec and the script header must agree.
`genfw.rpmlintrc` exists to silence one false positive; don't add filters
to hide real findings.

## How the script works

Read the top of `genfw` first: the option handling, the `%conf` defaults
block (policies, the three built-in chains and their comments), and the main
loop that calls `parserules`, then one address source per interface, then
`generate_rules`. Two globals carry all state: `%interface` (per interface:
type, flags, and a list of address configs, a list because an interface can
have several addresses) and `%conf` (logging fragment, policies, user
chains, and the `append`/`insert` rule lists keyed by `[table:]chain`).

Address sources: `ifcfg_addresses` reads `ifcfg-*` files through
`parseconfig`; `ip_addresses` parses `ip -o -4 addr show dev NAME`. Both
return the same hash shape, and a DHCP address (`BOOTPROTO=dhcp` or ip's
`dynamic` flag) becomes a config with no `ipaddr`. The `addresses`
directive picks one; otherwise `ifcfg` is used when any `ifcfg-*` file
exists, else `ip`. `t/10-addresses.t` pins that the same network described
either way gives identical rules. The `ip` text format was chosen over
`-json` because EL7's iproute predates JSON output; tests use a fake `ip`
on PATH. Core Perl modules are fine to use when they are needed (the RPM's
dependency generator picks them up automatically); the constraint is Perl
5.16, not module count.

Non-obvious design points, each visible in `generate_rules`:

- Nothing is emitted while parsing. `generate_rules` first `unshift`s its own
  generated rules onto the `append` lists so user `append` rules land after
  them, then walks the chains and emits.
- Generation and output are separate. `generate_rules` records into the
  `%ruleset` intermediate representation through `chain()`, `policy()`, and
  `rule("[table:]chain", @iptables_args)`; comment helpers queue text that
  attaches to the next rule. An output backend in `%backend` then formats
  the whole thing (`format_iptables_restore`) and, under `-i`, pipes it to
  the backend's `test` command first (`iptables-restore --test`) and then
  its `apply` command. Record rules only through `rule()`, and add a new
  output format (an `nft -f` backend is planned) as a new formatter plus
  apply command in `%backend`, never by printing from generation code.
- `filter:` is the default table and is stripped at parse time, so
  `filter:INPUT` and `INPUT` are the same key everywhere downstream.
- Chain naming: one chain per interface (`label($in)`), one per ordered pair
  (`label($in)-label($out)`, with a hard length limit), dispatched from
  `FORWARD` by `-i` and then by `-o`. What each pair chain contains depends
  on the interface types and the `trusted` flag; `t/01-basic.t` and
  `t/06-network-config.t` pin the exact sequences.
- `allow=` is read from the *destination* interface's flags. The grammar is
  in the POD and parsed in `check_allowed`; `t/03-allow.t` pins its behavior.
  Its colon-delimited form is why IPv6 addresses and port ranges are
  unsupported.

## Known gaps

`TODO` is the authoritative wishlist; `grep -n FIXME genfw` marks the code
sites. Beyond both: no IPv6 support. The two-pass boot and the dispatcher
hooks can only be checked with `systemd-analyze verify` and a fake
`systemctl` in this repo's tests and CI (containers have no running
systemd); their behaviour on a real boot has to be observed on a host.
