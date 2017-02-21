Name:           genfw
Version:        1.50
Release:        1%{?dist}
URL:            http://www.kspei.com/projects/genfw/
Source0:        http://ftp.kspei.com/pub/steve/genfw/%{name}-%{version}.tar.gz
Group:          System Environment/Base
License:        GPL
Summary:        Tool for building iptables-based firewalls.
BuildArch:      noarch
BuildRequires:  perl
BuildRequires:  /usr/bin/pod2man
BuildRequires:  systemd
BuildRequires:  perl-generators
Requires:       iptables
Requires:       perl(Data::Dumper)
Requires:       systemd-units

%description
genfw automates much of the work of building an iptables-based
firewall by using a simple text-based configuration file.

%prep
%setup -q

%build
pod2man genfw > genfw.8

%install
mkdir -p %{buildroot}/%{_unitdir} \
         %{buildroot}/%{_sysconfdir}/sysconfig/genfw \
         %{buildroot}/%{_sbindir} \
         %{buildroot}/%{_mandir}/man8

install -m 755 genfw %{buildroot}/%{_sbindir}/genfw
install -m 644 genfw.service %{buildroot}/%{_unitdir}/
install -m 644 genfw.8 %{buildroot}/%{_mandir}/man8/genfw.8

%files
%defattr(-,root,root)
%dir %{_sysconfdir}/sysconfig/genfw
%config %{_unitdir}/genfw.service
%{_sbindir}/genfw
%{_mandir}/man8/genfw.8*

%changelog
* Mon Feb 20 2017 Steven Pritchard <steve@kspei.com> 1.49
- Add systemd unit
- Modernize spec
- Hard-code Version to eliminate mock build problem

* Sun Feb 19 2017 Steven Pritchard <steve@kspei.com> 1.48
- Fix parse_version() call

* Mon Apr 14 2003 Steven Pritchard <steve@kspei.com> 1.28
- Cleanup

* Tue Jul 30 2002 Steven Pritchard <steve@kspei.com>
- Initial packaging
