Name:		genfw
Version:	1.24
Release:	1
Packager:	Steven Pritchard <steve@kspei.com>
URL:		http://www.kspei.com/projects/genfw/
Source0:	http://ftp.kspei.com/pub/steve/genfw/%{name}-%{version}.tar.gz
Group:		System Environment/Base
License:	GPL
BuildRoot:	%{_tmppath}/%{name}-%{version}
Summary:	Tool for building iptables-based firewalls.
BuildArch:	noarch
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
mkdir -p %{buildroot}/etc/rc.d/init.d \
         %{buildroot}/etc/sysconfig/genfw \
         %{buildroot}/usr/sbin \
         %{buildroot}/usr/share/man/man8
export INSTPREFIX=%{buildroot}
export PREFIX=%{buildroot}/usr
export BINDIR=%{buildroot}/usr/sbin
./install.sh

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
* Tue Jul 30 2002 Steven Pritchard <steve@kspei.com>
- Initial packaging
