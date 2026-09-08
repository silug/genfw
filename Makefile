FILES   = genfw firewall.init Makefile install.sh genfw.spec TODO genfw.service genfw-online.service hooks t
VERSION = $(shell perl -MExtUtils::MakeMaker \
                       -le 'print ExtUtils::MM->parse_version("genfw")')

all:

# Runs the test suite in t/. Uses prove (perl-Test-Harness) when available,
# otherwise runs each test file directly.
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

install:
	./install.sh

clean:
	rm -rf genfw-$(VERSION) \
	    genfw-$(VERSION).tar.gz* \
	    genfw-$(VERSION)-*.src.rpm

genfw-$(VERSION).tar.gz:
	mkdir genfw-$(VERSION)
	cp -r $(FILES) genfw-$(VERSION)/
	tar -zcvf genfw-$(VERSION).tar.gz genfw-$(VERSION)

genfw-$(VERSION)-1.src.rpm: genfw-$(VERSION).tar.gz
	rpmbuild \
	    --define '_sourcedir .' \
	    --define '_builddir .' \
	    --define '_srcrpmdir .' \
	    --define '_rpmdir .' \
	    --define 'dist %{nil}' \
	    -bs --nodeps genfw.spec

dist: genfw-$(VERSION).tar.gz genfw-$(VERSION)-1.src.rpm

sign: dist
	rpm --addsign genfw-$(VERSION)-*.src.rpm
	gpg -b genfw-$(VERSION).tar.gz
