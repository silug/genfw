Name:           genfw
Version:        1.51.0
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
pod2man genfw > genfw.8

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
%systemd_post genfw.service genfw-online.service

%preun
%systemd_preun genfw.service genfw-online.service

%postun
%systemd_postun genfw.service genfw-online.service

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
