Name:		genfw
Version:	%(perl -MExtUtils::MakeMaker -le 'print ExtUtils::MM_Unix::parse_version("", "genfw")')
Release:	1
Packager:	Steven Pritchard <steve@kspei.com>
URL:		http://www.kspei.com/projects/genfw/
Source0:	http://ftp.kspei.com/pub/steve/genfw/%{name}-%{version}.tar.gz
Group:		System Environment/Base
License:	GPL
BuildRoot:	%{_tmppath}/%{name}-%{version}
Summary:	Tool for building iptables-based firewalls.
BuildArch:	noarch
BuildRequires:	perl
Requires:	iptables
Requires:	perl
Requires:	perl(FileHandle)
Requires:	perl(DirHandle)
Requires:	perl(Socket)
Requires:	perl(Getopt::Std)
Requires:	chkconfig

%description
genfw automates much of the work of building an iptables-based
firewall by using a simple text-based configuration file.

%prep
%setup -q

%build

%install
[ "%{buildroot}" = "/" -o -z "%{buildroot}" ] && exit 1
rm -rf %{buildroot}
mkdir -p %{buildroot}/%{_initrddir} \
         %{buildroot}/%{_sysconfdir}/sysconfig/genfw \
         %{buildroot}/%{_sbindir} \
         %{buildroot}/%{_mandir}/man8

cp genfw %{buildroot}/%{_sbindir}/genfw
cp firewall.init %{buildroot}/%{_initrddir}/firewall

pod2man genfw > genfw.8
cp genfw.8 %{buildroot}/%{_mandir}/genfw.8

%clean
rm -rf %{buildroot}

%preun
chkconfig --del firewall

%post
chkconfig --add firewall

%files
%defattr(-,root,root)
%dir /etc/sysconfig/genfw
%config /etc/rc.d/init.d/firewall
/usr/sbin/genfw
%{_mandir}/man8/genfw.8*

%changelog
* Mon Apr 14 2003 Steven Pritchard <steve@kspei.com> 1.28
- Cleanup

* Tue Jul 30 2002 Steven Pritchard <steve@kspei.com>
- Initial packaging
