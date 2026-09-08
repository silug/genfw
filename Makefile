# genfw developer Makefile. The packages (genfw.spec, debian/) are the real
# build definitions; this is for running the checks CI runs, producing the
# release tarball, and installing by hand where no package fits.

VERSION := $(shell perl -ne 'print $$1 if /^our \$$VERSION\s*=\s*"([^"]+)"/' genfw)
TARBALL := genfw-$(VERSION).tar.gz
SRPM    := genfw-$(VERSION)-1.src.rpm

# Everything that goes into the release tarball.
FILES = genfw Makefile genfw.spec genfw.rpmlintrc README.md AGENTS.md \
        genfw.service genfw-online.service hooks debian t

# Install locations for "make install" (DESTDIR for staging).
PREFIX   ?= /usr
SBINDIR  ?= $(PREFIX)/sbin
MANDIR   ?= $(PREFIX)/share/man
UNITDIR  ?= $(PREFIX)/lib/systemd/system
NMDIR    ?= $(PREFIX)/lib/NetworkManager/dispatcher.d
NDDIR    ?= $(PREFIX)/lib/networkd-dispatcher/routable.d
SYSCONFDIR ?= /etc

.PHONY: all test lint dist rpm deb install clean

all: genfw.8

genfw.8: genfw
	pod2man --section=8 --center="System Administration" --release="genfw" genfw > $@

# The test suite. Uses prove (perl-Test-Harness) when available, otherwise
# runs each test file directly.
test:
	@if command -v prove >/dev/null 2>&1 ; then \
	    prove t ; \
	else \
	    rc=0 ; \
	    for t in t/*.t ; do \
	        echo "# $$t" ; perl $$t || rc=1 ; \
	    done ; \
	    exit $$rc ; \
	fi

# The same static checks the CI lint job runs.
lint:
	perl -c genfw
	podchecker genfw
	perlcritic genfw t/lib/GenfwTest.pm t/*.t
	shellcheck --severity=warning hooks/* debian/genfw.postinst
	rpmlint --ignore-unused-rpmlintrc genfw.spec

$(TARBALL):
	rm -rf genfw-$(VERSION)
	mkdir genfw-$(VERSION)
	cp -r $(FILES) genfw-$(VERSION)/
	tar -zcf $(TARBALL) genfw-$(VERSION)
	rm -rf genfw-$(VERSION)

$(SRPM): $(TARBALL)
	rpmbuild \
	    --define '_sourcedir .' \
	    --define '_builddir .' \
	    --define '_srcrpmdir .' \
	    --define '_rpmdir .' \
	    --define 'dist %{nil}' \
	    -bs --nodeps genfw.spec

# Release tarball and source RPM in the current directory.
dist: $(TARBALL) $(SRPM)

# Binary RPM from the tarball, as the release workflow builds it (which
# also runs the test suite in %check). Output lands under ~/rpmbuild.
rpm: $(TARBALL)
	rpmbuild -ta --define 'dist %{nil}' $(TARBALL)

# Debian package, as the release workflow builds it. Output lands in the
# parent directory.
deb:
	dpkg-buildpackage -us -uc -b

# Install by hand, mirroring what the packages install. Nothing is enabled;
# write $(SYSCONFDIR)/genfw/rules, then "systemctl enable --now genfw".
install: genfw.8
	install -d $(DESTDIR)$(SBINDIR) $(DESTDIR)$(MANDIR)/man8 $(DESTDIR)$(UNITDIR) \
	           $(DESTDIR)$(NMDIR) $(DESTDIR)$(NDDIR) $(DESTDIR)$(SYSCONFDIR)/genfw
	install -m 755 genfw $(DESTDIR)$(SBINDIR)/genfw
	install -m 644 genfw.8 $(DESTDIR)$(MANDIR)/man8/genfw.8
	install -m 644 genfw.service genfw-online.service $(DESTDIR)$(UNITDIR)/
	install -m 755 hooks/NetworkManager-dispatcher $(DESTDIR)$(NMDIR)/90-genfw
	install -m 755 hooks/networkd-dispatcher $(DESTDIR)$(NDDIR)/90-genfw

clean:
	rm -rf genfw.8 genfw-$(VERSION) genfw-*.tar.gz genfw-*.tar.gz.asc genfw-*.src.rpm
