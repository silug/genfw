Name:           genfw
Version:        %(perl -MExtUtils::MakeMaker -le 'print ExtUtils::MM->parse_version("genfw")')
Release:        1
URL:            http://www.kspei.com/projects/genfw/
Source0:        http://ftp.kspei.com/pub/steve/genfw/%{name}-%{version}.tar.gz
Group:          System Environment/Base
License:        GPL
BuildRoot:      %{_tmppath}/%{name}-%{version}
Summary:        Tool for building iptables-based firewalls.
BuildArch:      noarch
BuildRequires:  perl
Requires:       iptables
Requires:       perl
Requires:       perl(FileHandle)
Requires:       perl(DirHandle)
Requires:       perl(Socket)
Requires:       perl(Getopt::Std)
Requires:       systemd-units

%description
genfw automates much of the work of building an iptables-based
firewall by using a simple text-based configuration file.

%prep
%setup -q

%build

%install
[ "%{buildroot}" = "/" -o -z "%{buildroot}" ] && exit 1
rm -rf %{buildroot}
mkdir -p %{buildroot}/%{_unitdir} \
         %{buildroot}/%{_sysconfdir}/sysconfig/genfw \
         %{buildroot}/%{_sbindir} \
         %{buildroot}/%{_mandir}/man8

cp genfw %{buildroot}/%{_sbindir}/genfw
cp genfw.service %{buildroot}/%{_unitdir}/

pod2man genfw > genfw.8
cp genfw.8 %{buildroot}/%{_mandir}/man8/genfw.8

%clean
rm -rf %{buildroot}

%files
%defattr(-,root,root)
%dir %{_sysconfdir}/sysconfig/genfw
%config %{_unitdir}/genfw.service
%{_sbindir}/genfw
%{_mandir}/man8/genfw.8*

%changelog
* Sun Feb 19 2017 Steven Pritchard <steve@kspei.com> 1.49
- Add systemd unit

* Sun Feb 19 2017 Steven Pritchard <steve@kspei.com> 1.48
- Fix parse_version() call

* Mon Apr 14 2003 Steven Pritchard <steve@kspei.com> 1.28
- Cleanup

* Tue Jul 30 2002 Steven Pritchard <steve@kspei.com>
- Initial packaging
