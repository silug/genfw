# genfw

genfw builds an iptables firewall from a short, readable configuration file
and the host's network configuration. You describe each interface as
*internal*, *dmz*, or *outside*, add a few flags such as `nat`, `trusted`,
or `allow=ssh/tcp`, and genfw derives the full ruleset: per-interface
chains, every interface-to-interface path, NAT, anti-spoofing drops, and
rate-limited logging of everything that falls through. Default policy is
deny on `INPUT` and `FORWARD`.

The output is a complete ruleset in `iptables-restore` format, the same
format `iptables-save` produces, so you can read it, diff it against a running
system, or load it in one atomic step. It starts with a
`#!/usr/sbin/iptables-restore` line, so a saved copy can be made executable
and run to load itself. With `-i` genfw loads it directly, which is what the
systemd unit does at boot. For hosts running nftables without the iptables
compatibility layer, `format nft` (or `-o nft`) produces the same ruleset in
`nft -f` syntax instead; see below.

## Status

genfw is mature and small (one Perl script). Things to know:

- It learns interface addresses either from Red Hat
  `/etc/sysconfig/network-scripts/ifcfg-*` files or, on systems without them
  (RHEL 9, current Fedora, Debian and derivatives), from the running system
  via `ip -o -4 addr show`. The latter needs interfaces to be up when genfw
  runs; see the `addresses` directive below.
- It generates IPv4 rules only. There is no ip6tables support.
- It drives `iptables`, which on current systems is the nftables
  compatibility layer, and it will conflict with firewalld if both are
  enabled.

The RPM targets EL7 and later; the `.deb` targets current Debian and Ubuntu.
Planned work is tracked in the
[GitHub issues](https://github.com/silug/genfw/issues).

## Installation

Each [release](https://github.com/silug/genfw/releases) ships a single
`noarch` RPM that installs on EL7, EL8, EL9, and Fedora, a `.deb` for Debian
and Ubuntu, plus the source RPM and tarball. The RPMs and tarball are
GPG-signed, and the public key is attached to each release as
`RPM-GPG-KEY-genfw`; the `.deb` is covered by the signed `SHA256SUMS` and by
the build provenance. To verify and install:

```sh
rpm --import RPM-GPG-KEY-genfw
rpm -K genfw-<version>-1.noarch.rpm          # expect "OK"
dnf install ./genfw-<version>-1.noarch.rpm   # yum localinstall on EL7
# ...write your rules (see below), then:
systemctl enable --now genfw.service
```

Release assets also carry GitHub build provenance, which ties them to the
workflow run and commit that produced them:

```sh
gh attestation verify genfw-<version>-1.noarch.rpm --owner silug
```

On Debian or Ubuntu:

```sh
sha256sum -c --ignore-missing SHA256SUMS.deb
apt install ./genfw_<version>-1_all.deb
mkdir -p /etc/genfw   # then write /etc/genfw/rules (see below)
systemctl enable --now genfw.service
```

The package installs the same files as the RPM plus an ifupdown hook in
`/etc/network/if-up.d/`, and creates `/etc/genfw/`. Nothing is enabled by
installation.

To build the packages yourself from a checkout:

```sh
make dist            # produces genfw-<version>.tar.gz and genfw-<version>-1.src.rpm
rpmbuild -ta genfw-<version>.tar.gz
dnf install ~/rpmbuild/RPMS/noarch/genfw-<version>-*.noarch.rpm

dpkg-buildpackage -us -uc -b   # on Debian: produces ../genfw_<version>-1_all.deb
```

The package installs `/usr/sbin/genfw`, the `genfw(8)` man page, two systemd
units, dispatcher hooks for NetworkManager and networkd-dispatcher, and an
empty `/etc/sysconfig/genfw/` for your rules. You can use `/etc/genfw/`
instead (see below); the package will move there in a future major version.
Nothing is enabled by installation.

### At boot and on network changes

`genfw.service` runs before any interface is configured, so no traffic is
ever handled without a firewall, and pulls in `genfw-online.service`, which
runs again after the network is up. With `ifcfg` files the first pass is
already complete; with the `ip` address source the first pass lacks
address-dependent rules (anti-spoof filtering, NAT) and the second pass adds
them. Only `genfw.service` needs enabling. Upgrading the package restarts
it, so the rules are regenerated with the new version.

Interfaces that appear later, such as a VPN, trigger a rerun through hooks
that call `systemctl try-restart genfw.service`: for NetworkManager, for
`networkd-dispatcher` on systemd-networkd hosts, and for ifupdown on Debian.
Each hook is only run by its own network stack, and `try-restart` does
nothing unless genfw is enabled and active. After changing a static address
by hand, `systemctl restart genfw.service`.

Without packaging, `make install` puts the same files in place under
`/usr` (`PREFIX`, `DESTDIR`, and the individual directory variables in the
Makefile can override that). Nothing is enabled; write your rules, then
`systemctl enable --now genfw.service`.

Runtime requirements are Perl and `iptables`. On Fedora the `perl-DirHandle`
package is also needed; the RPM pulls it in automatically.

## Configuration

genfw reads `rules` and any `rules.d/*.rules` from its configuration
directory, then learns the addresses of each interface named in them, from
`ifcfg-*` files or from `ip` (see `addresses` below). `#` starts a comment
and a trailing `\` continues a line.

The configuration directory is `/etc/genfw` if it exists, otherwise the
historical `/etc/sysconfig/genfw`; `-c DIR` overrides both. If both
directories exist, `/etc/genfw` is used and genfw warns about the other.
On a Debian-family system, create `/etc/genfw`.

A three-interface gateway, taken from `t/sample/genfw/rules` in this
repository:

```
# Inside network, NATed to the outside, allowed to reach the DMZ freely.
internal eth1 nat trusted label=inside

# DMZ hosts: reachable from the outside on web and DNS, ssh only from inside.
dmz eth2 nat allow=http/tcp,https/tcp,domain allow=ssh/tcp:::eth1 label=dmz

# Outside (DHCP) interface.
outside eth0 label=world

limit logging

# Local services on the gateway itself.
append INPUT -i eth1 -p tcp --dport ssh -j acceptnew
append INPUT -i eth0 -p tcp --dport ssh -m limit --limit 3/min -j acceptnew

# Transparent proxy for inside web traffic.
append nat:PREROUTING -i eth1 -p tcp --dport 80 -j REDIRECT --to 3128
```

### Interface types

| Directive | Meaning |
|---|---|
| `internal` *iface* (or `int`) | Can connect out. Nothing can connect in to it. |
| `dmz` *iface* | Accepts connections from outside. Cannot reach internal interfaces. |
| `outside` *iface* (or `out`, `output`) | Cannot reach internal interfaces; can reach what the dmz allows. Traffic between two outside interfaces is dropped. |

### Interface flags

Any number of these may follow the interface name.

| Flag | Effect |
|---|---|
| `nat` | Masquerade or SNAT traffic from this interface when it leaves through an outside interface. SNAT to the outside address when it is static, MASQUERADE when it is dynamic. |
| `trusted` | Internal or dmz only. Full outgoing access. A trusted internal interface can also reach anything on a dmz. |
| `allow=`*spec*`,`... | Open specific traffic **to** this interface. See below. |
| `label=`*name* | Use *name* instead of the interface name in chain names and log prefixes. |
| `ignore` | Generate no rules for this interface. |

Each `allow=` item is `port[/proto][:src[:dst[:iface]]]`:

- `allow=domain` looks the name up in `/etc/services` and opens every
  protocol it is defined for (here, 53/tcp and 53/udp).
- `allow=gre` opens a protocol from `/etc/protocols` when the name is not a
  service.
- `allow=ssh/tcp` or `allow=22/tcp` opens one port on one protocol. A bare
  numeric port with no protocol is rejected as ambiguous.
- The optional colon-separated fields restrict the source address, the
  destination address, and the interface the traffic must arrive on. Any
  can be left blank: `allow=ssh/tcp:::eth1` permits ssh only from `eth1`.

### Other directives

| Directive | Effect |
|---|---|
| `append` [*table*`:`]*chain* *rule* | Append a raw iptables rule to *chain*. The table defaults to `filter`. |
| `insert` [*table*`:`]*chain* *rule* | Same, but at the start of the chain, before generated rules. |
| `chain` [*table*`:`]*name* [*comment*] | Create a user chain for use with `append` and `insert`. |
| `policy` [*table*`:`]*chain* *target* | Set a built-in chain's policy. Defaults are `INPUT DROP`, `OUTPUT ACCEPT`, `FORWARD DROP`. |
| `no logging`, `limit logging`, `full logging` | Control logging of dropped packets. `limit` is the default and adds `-m limit` to every `LOG` rule. |
| `include` *file* | Read more rules from *file*, a path relative to the configuration directory or absolute, and it may be a glob. |
| `format` `iptables-restore` or `nft` | Which loader the ruleset is written for. Default `iptables-restore`; `-o` on the command line overrides. See "nft output" below. |
| `addresses` `ifcfg` or `ip` | Where interface addresses come from: Red Hat `ifcfg-*` files, or the running system via `ip -o -4 addr show`. Default: `ifcfg` if any `ifcfg-*` file exists, else `ip`. With `ip`, run genfw after the network is up (order the unit after `network-online.target`, or re-run from a dispatcher hook); a DHCP-assigned address is treated like `BOOTPROTO=dhcp`. |

genfw defines three chains you can jump to from your own rules: `acceptnew`
(accept new connections), `established` (accept established and related),
and `icmp-filter`.

The full reference is the man page, `genfw(8)`, or `perldoc ./genfw` in a
checkout.

### nft output

With `format nft` in the rules file (or `genfw -o nft`), the ruleset comes
out in `nft -f` syntax, for hosts that run nftables directly. genfw builds
its rules as iptables arguments and has them translated by
`iptables-restore-translate`, which ships in the `iptables-nft` package on
Red Hat systems and in `iptables` on Debian; that package must be installed
even though `iptables` itself is never run. The output starts with
`#!/usr/sbin/nft -f`, and each of genfw's tables (`ip filter`, `nat`,
`mangle`, `raw`) is deleted and recreated within the file, so loading it
replaces them atomically and leaves every other nft table alone. Those four
tables are the ones the nftables-backed iptables uses too, so rules another
tool (Docker, libvirt) added to them through iptables are replaced as well,
exactly as with the `iptables-restore` format. The chains keep their
iptables names, but inspect the result with `nft list ruleset`,
not `iptables-save`: the nftables-backed iptables tools can only read back
rules they created themselves and report these tables as incompatible. A
rule with no nft translation is a fatal error rather than a silently
missing rule. Comments from the rules are not carried into the nft output.

## Running it

```sh
genfw > firewall.rules            # print the ruleset to review
genfw -c /path/to/dir > out.rules # ...using another configuration directory
iptables-restore < firewall.rules # load it by hand...
chmod +x firewall.rules && ./firewall.rules   # ...or run it; the #! line invokes iptables-restore
genfw -i                          # generate and load in one step (what the systemd unit does)
genfw -o nft > firewall.nft       # the same ruleset for nft -f (see "nft output")
```

The ruleset lists every table, so loading it replaces the whole firewall:
each table is swapped atomically by `iptables-restore`, and there is no
window with a flushed, open firewall. Treat `-i` as a full reload. Before
loading, `-i` runs `iptables-restore --test` on the ruleset, so one that
cannot be parsed is rejected before anything changes. If either step fails,
genfw exits non-zero and reports it.

To try a configuration without root and without touching the live firewall,
use `-d`. It reads `./genfw/rules` and `./network-scripts/ifcfg-*` from the
current directory instead of `/etc/sysconfig`, and prints debug tracing to
stderr:

```sh
cd t/sample && perl ../../genfw -d
```

## Development

```sh
make test               # run the test suite (needs perl-Test-Harness for prove)
prove -v t/03-allow.t   # one test file
```

The suite in `t/` exercises the script as a black box against throwaway
configurations and never touches the real firewall. One test loads generated
rulesets into a real `iptables-restore` inside a private network namespace
and skips itself where that is not possible. GitHub Actions runs the suite
on EL7, EL9, Fedora, and Ubuntu, runs `perlcritic` on the script and tests,
lints the shell scripts, and builds and installs the RPM, then loads the
sample ruleset with it. See `.github/workflows/test.yml`.

Contributions go through pull requests against `master`.

## License

GPL-2.0-or-later. Copyright (C) 2001-2026 Steven Pritchard.
