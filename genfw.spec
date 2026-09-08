Name:           genfw
Version:        1.52.1
Release:        1%{?dist}
URL:            http://www.kspei.com/projects/genfw/
Source0:        http://ftp.kspei.com/pub/steve/genfw/%{name}-%{version}.tar.gz
Group:          System Environment/Base
License:        GPL-2.0-or-later
Summary:        Tool for building iptables-based firewalls
BuildArch:      noarch
BuildRequires:  perl
BuildRequires:  /usr/bin/pod2man
BuildRequires:  systemd
BuildRequires:  perl-generators
BuildRequires:  perl(Test::More)
BuildRequires:  perl(DirHandle)
Requires:       iptables
Requires:       perl(Data::Dumper)
Requires:       systemd-units
%{?systemd_requires}

%description
genfw automates much of the work of building an iptables-based
firewall by using a simple text-based configuration file.

%prep
%setup -q

%build
pod2man --section=8 --center="System Administration" --release="genfw" genfw > genfw.8

%check
perl -e 'for (glob("t/*.t")) { system($^X, $_) == 0 or die "$_ failed\n" }'

%install
mkdir -p %{buildroot}/%{_unitdir} \
         %{buildroot}/%{_sysconfdir}/sysconfig/genfw \
         %{buildroot}/%{_sbindir} \
         %{buildroot}/%{_mandir}/man8 \
         %{buildroot}/%{_prefix}/lib/NetworkManager/dispatcher.d \
         %{buildroot}/%{_prefix}/lib/networkd-dispatcher/routable.d

install -m 755 genfw %{buildroot}/%{_sbindir}/genfw
install -m 644 genfw.service genfw-online.service %{buildroot}/%{_unitdir}/
install -m 644 genfw.8 %{buildroot}/%{_mandir}/man8/genfw.8
# Hooks that regenerate the firewall when an interface comes up. Each is
# only ever run by the network stack it belongs to, so shipping all of them
# is harmless on a host that has only one.
install -m 755 hooks/NetworkManager-dispatcher \
    %{buildroot}/%{_prefix}/lib/NetworkManager/dispatcher.d/90-genfw
install -m 755 hooks/networkd-dispatcher \
    %{buildroot}/%{_prefix}/lib/networkd-dispatcher/routable.d/90-genfw

%post
%systemd_post genfw.service
# On upgrade, the previous package's %%postun would normally reload systemd
# and restart the unit, but packages before 1.52.1 had no scriptlets (or no
# restart), so do it here as well. Reloading twice is harmless; the unit is
# started only if it is enabled and not already active, which is the state
# an upgrade from 1.51.0 leaves it in (its unit had no RemainAfterExit).
if [ $1 -gt 1 ] ; then
    systemctl daemon-reload >/dev/null 2>&1 || :
    if systemctl is-enabled --quiet genfw.service 2>/dev/null \
       && ! systemctl is-active --quiet genfw.service 2>/dev/null ; then
        systemctl start genfw.service >/dev/null 2>&1 || :
    fi
fi

# Runs after everything else in the transaction, including the previous
# package's %%postun that restarts the unit, so a failure to regenerate the
# firewall (a rules file that no longer parses, say) is reported here where
# the person upgrading can see it, rather than only in the journal. The
# upgrade itself still succeeds; the rules in effect are the previous ones.
%posttrans
if systemctl is-enabled --quiet genfw.service 2>/dev/null \
   && systemctl is-failed --quiet genfw.service 2>/dev/null ; then
    echo "warning: genfw.service failed to regenerate the firewall after this upgrade;" >&2
    echo "         see 'systemctl status genfw.service' and 'journalctl -u genfw.service'." >&2
fi

%preun
%systemd_preun genfw.service genfw-online.service

%postun
# Reload systemd and, on upgrade, restart the unit so the rules are
# regenerated with the new version. This runs from the package being
# replaced, so it takes effect for upgrades from this version onward.
%systemd_postun_with_restart genfw.service

%files
%defattr(-,root,root)
%dir %{_sysconfdir}/sysconfig/genfw
%{_unitdir}/genfw.service
%{_unitdir}/genfw-online.service
%{_sbindir}/genfw
%{_mandir}/man8/genfw.8*
%dir %{_prefix}/lib/NetworkManager
%dir %{_prefix}/lib/NetworkManager/dispatcher.d
%{_prefix}/lib/NetworkManager/dispatcher.d/90-genfw
%dir %{_prefix}/lib/networkd-dispatcher
%dir %{_prefix}/lib/networkd-dispatcher/routable.d
%{_prefix}/lib/networkd-dispatcher/routable.d/90-genfw

%changelog
* Tue Sep 08 2026 Steven Pritchard <steve@kspei.com> - 1.52.1-1
- genfw.service now pulls in genfw-online.service; enabling genfw.service
  is again the only step needed. genfw-online.service is no longer enabled
  separately.
- Upgrading the package reloads systemd and restarts genfw.service, so the
  rules are regenerated with the new version. Upgrades from 1.51.0 and
  earlier are handled too (those packages had no scriptlets).
- genfw-online.service uses Requires rather than Requisite, so starting it
  by hand starts the early pass instead of failing.

* Tue Sep 08 2026 Steven Pritchard <steve@kspei.com> - 1.52.0-1
- Learn interface addresses from ip(8) when there are no ifcfg files, so
  genfw works on RHEL 9, Fedora, Debian, and Ubuntu ("addresses" directive).
- /etc/genfw is the configuration directory; /etc/sysconfig/genfw still
  works as a fallback. New -c option to choose another.
- Run before the network comes up (genfw.service) and again after
  (genfw-online.service); ship NetworkManager and networkd-dispatcher hooks
  that rerun genfw when an interface appears. Add systemd scriptlets.
- Add Debian packaging.
- Man page is generated in section 8.

* Mon Sep 07 2026 Steven Pritchard <steve@kspei.com> - 1.51.0-1
- Output is now an iptables-restore ruleset (loaded atomically, one table at
  a time) instead of a shell script of iptables commands; -i checks it with
  iptables-restore --test and then loads it. The file starts with a
  #!/usr/sbin/iptables-restore line so a saved copy can still be executed.
- Fix "append filter:CHAIN" being silently ignored, "policy table:CHAIN"
  emitting an empty target, and embedded quotes breaking script output.
- Parse interface flags once; unknown flags and duplicate labels now warn.
- Add a test suite (run in %%check), GitHub Actions CI, README, and a
  signed release workflow.
- License tag is now the SPDX identifier GPL-2.0-or-later.
- Switch to semantic versioning.

* Sun Apr 30 2017 Steven Pritchard <steve@kspei.com> - 1.50-1
- Fix systemd unit to also work with network.service

* Mon Feb 20 2017 Steven Pritchard <steve@kspei.com> - 1.49-1
- Add systemd unit
- Modernize spec
- Hard-code Version to eliminate mock build problem

* Sun Feb 19 2017 Steven Pritchard <steve@kspei.com> - 1.48-1
- Fix parse_version() call

* Mon Apr 14 2003 Steven Pritchard <steve@kspei.com> - 1.28-1
- Cleanup

* Tue Jul 30 2002 Steven Pritchard <steve@kspei.com>
- Initial packaging
