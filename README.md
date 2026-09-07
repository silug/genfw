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
systemd unit does at boot.

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

The RPM targets EL7 and later. On Debian and derivatives, `iptables`,
`iproute2`, and `perl` are all that is needed; there is no `.deb` yet, so
install the script and unit by hand. See `TODO` for the wishlist.

## Installation

Each [release](https://github.com/silug/genfw/releases) ships a single
`noarch` RPM that installs on EL7, EL8, EL9, and Fedora, plus the source RPM
and tarball. The RPMs and tarball are GPG-signed, and the public key is
attached to each release as `RPM-GPG-KEY-genfw`. To verify and install:

```sh
rpm --import RPM-GPG-KEY-genfw
rpm -K genfw-<version>-1.noarch.rpm          # expect "OK"
dnf install ./genfw-<version>-1.noarch.rpm   # yum localinstall on EL7
systemctl enable genfw.service
```

Release assets also carry GitHub build provenance, which ties them to the
workflow run and commit that produced them:

```sh
gh attestation verify genfw-<version>-1.noarch.rpm --owner silug
```

To build the RPM yourself from a checkout:

```sh
make dist            # produces genfw-<version>.tar.gz and genfw-<version>-1.src.rpm
rpmbuild -ta genfw-<version>.tar.gz
dnf install ~/rpmbuild/RPMS/noarch/genfw-<version>-*.noarch.rpm
systemctl enable genfw.service
```

The package installs `/usr/sbin/genfw`, the `genfw(8)` man page, the systemd
unit, and an empty `/etc/sysconfig/genfw/` for your rules.

Without packaging, `make install` runs `install.sh`, which installs the
script under `/usr/local`, the SysV init script `firewall.init` as
`/etc/rc.d/init.d/firewall`, and registers it with `chkconfig`. `install.sh`
honors `PREFIX`, `BINDIR`, `MANDIR`, `INITDIR`, and `CONFIGDIR`.

Runtime requirements are Perl and `iptables`. On Fedora the `perl-DirHandle`
package is also needed; the RPM pulls it in automatically.

## Configuration

genfw reads `/etc/sysconfig/genfw/rules` and any `/etc/sysconfig/genfw/rules.d/*.rules`,
then learns the addresses of each interface named in them, from `ifcfg-*`
files or from `ip` (see `addresses` below). `#` starts a comment and a
trailing `\` continues a line.

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
| `include` *file* | Read more rules from *file*, a path relative to `/etc/sysconfig/genfw/` or absolute, and it may be a glob. |
| `addresses` `ifcfg` or `ip` | Where interface addresses come from: Red Hat `ifcfg-*` files, or the running system via `ip -o -4 addr show`. Default: `ifcfg` if any `ifcfg-*` file exists, else `ip`. With `ip`, run genfw after the network is up (order the unit after `network-online.target`, or re-run from a dispatcher hook); a DHCP-assigned address is treated like `BOOTPROTO=dhcp`. |

genfw defines three chains you can jump to from your own rules: `acceptnew`
(accept new connections), `established` (accept established and related),
and `icmp-filter`.

The full reference is the man page, `genfw(8)`, or `perldoc ./genfw` in a
checkout.

## Running it

```sh
genfw > firewall.rules            # print the ruleset to review
iptables-restore < firewall.rules # load it by hand...
chmod +x firewall.rules && ./firewall.rules   # ...or run it; the #! line invokes iptables-restore
genfw -i                          # generate and load in one step (what the systemd unit does)
```

The ruleset lists every table, so loading it replaces the whole firewall:
each table is swapped atomically by `iptables-restore`, and there is no
window with a flushed, open firewall. Treat `-i` as a full reload. Before
loading, `-i` runs `iptables-restore --test` on the ruleset, so one that
cannot be parsed is rejected before anything changes. If either step fails,
genfw exits non-zero and reports it.
On systems using the SysV script, `service firewall start` does the same and
also loads any kernel modules listed in `/etc/sysconfig/genfw/modules`.

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
