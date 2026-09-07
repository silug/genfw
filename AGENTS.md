# AGENTS.md

Guidance for AI coding agents working in this repository.

## What this is

`genfw` is a single-file Perl script (no modules) that generates an iptables
firewall from a small text `rules` file plus the host's Red Hat-style
`ifcfg-*` network configuration. The user documentation is the POD at the
bottom of `genfw` (`perldoc ./genfw`); it covers every rules directive and
interface flag and is the source for the man page.

Everything else is packaging or testing: `genfw.spec` and `genfw.rpmlintrc`
(RPM), `genfw.service` (systemd oneshot), `firewall.init` (legacy SysV init),
`install.sh`, `Makefile`, the test suite in `t/`, and CI in
`.github/workflows/test.yml`. `TODO` is the upstream wishlist.

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

`-d` (or `DEBUG` in the environment) points `$config_dir` at `.` instead of
`/etc/sysconfig`; see the option handling at the top of `genfw` for exactly
what is read. Without `-i`, genfw prints a `#!/bin/sh` script of `iptables`
commands to stdout. With `-i` (what the systemd unit and init script use) it
executes `iptables` directly and prints nothing. Never run `-i` casually: it
flushes all tables first.

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
needs root; `-i` mode runs against a recording `iptables` stub.

The tests double as the precise specification of generated output. When a
question is "what order do rules come out in" or "what does flag X do", the
answer is an `is_deeply` in `t/`, not this file. In particular
`t/07-run-mode.t` executes the generated script under `sh` and requires argv
identical to `-i` mode; any shell-quoting change must keep it green.

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

`$VERSION` in `genfw` and `Version:` in `genfw.spec` must match;
`t/00-compile.t` enforces it. A release bump edits both and adds a
`%changelog` entry in the same form as the existing ones, then `make dist` /
`make sign`. The license identifier in the spec and the script header must
agree. `genfw.rpmlintrc` exists to silence one false positive; don't add
filters to hide real findings.

## How the script works

Read the top of `genfw` first: the option handling, the `%conf` defaults
block (policies, the three built-in chains and their comments), and the main
loop that calls `parserules`, `parseconfig`, and `generate_rules` in that
order. Two globals carry all state: `%interface` (per interface: type, flags,
and a list of parsed `ifcfg` configs, a list because aliases like `eth0:1`
merge in) and `%conf` (logging fragment, policies, user chains, and the
`append`/`insert` rule lists keyed by `[table:]chain`).

Non-obvious design points, each visible in `generate_rules`:

- Nothing is emitted while parsing. `generate_rules` first `unshift`s its own
  generated rules onto the `append` lists so user `append` rules land after
  them, then walks the chains and emits.
- Every command goes through `iptables(@)`, which prints or executes
  depending on `-i`, and the comment helpers are no-ops under `-i`. Emit
  rules only through `iptables(@)` so both modes stay identical.
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
sites. Beyond both: the script reads `ifcfg-*` files, which RHEL 9 and
current Fedora no longer create by default, and it has no IPv6 support.
