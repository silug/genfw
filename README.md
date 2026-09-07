# genfw

genfw builds an iptables firewall from a short, readable configuration file
and the host's network configuration. You describe each interface as
*internal*, *dmz*, or *outside*, add a few flags such as `nat`, `trusted`,
or `allow=ssh/tcp`, and genfw derives the full ruleset: per-interface
chains, every interface-to-interface path, NAT, anti-spoofing drops, and
rate-limited logging of everything that falls through. Default policy is
deny on `INPUT` and `FORWARD`.

The output is either a plain shell script of `iptables` commands you can read
and audit, or, with `-i`, the same commands executed directly. The systemd
unit uses the latter at boot.

## Status

genfw is mature and small (one Perl script), but it targets a platform that
has moved on:

- It reads network configuration from `/etc/sysconfig/network-scripts/ifcfg-*`.
  RHEL 9 and current Fedora no longer create these files by default.
- It generates IPv4 rules only. There is no ip6tables support.
- It drives `iptables`, which on current systems is the nftables
  compatibility layer, and it will conflict with firewalld if both are
  enabled.

It works as documented on RHEL and CentOS 7 and earlier, and on any system
where `ifcfg-*` files and `iptables` are still present. See `TODO` for the
wishlist.

## Installation

From the RPM (Fedora, RHEL, and derivatives):

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
then the `ifcfg-*` file for each interface named in them. `#` starts a
comment and a trailing `\` continues a line.

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

genfw defines three chains you can jump to from your own rules: `acceptnew`
(accept new connections), `established` (accept established and related),
and `icmp-filter`.

The full reference is the man page, `genfw(8)`, or `perldoc ./genfw` in a
checkout.

## Running it

```sh
genfw > firewall.sh     # print the script to review
genfw -i                # apply it directly (what the systemd unit does)
```

Applying flushes every table first and then sets policies and rules, so
treat `-i` as a full reload. On systems using the SysV script, `service
firewall start` does the same and also loads any kernel modules listed in
`/etc/sysconfig/genfw/modules`.

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
configurations and never touches the real firewall. GitHub Actions runs it on
Fedora, EL9, and Ubuntu, lints the shell scripts and the generated output,
and builds and installs the RPM. See `.github/workflows/test.yml`.

Contributions go through pull requests against `master`.

## License

GPL-2.0-or-later. Copyright (C) 2001-2010 Steven Pritchard.
