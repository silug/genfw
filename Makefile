FILES   = genfw firewall.init Makefile install.sh genfw.spec TODO genfw.service
VERSION = $(shell perl -MExtUtils::MakeMaker \
                       -le 'print ExtUtils::MM->parse_version("genfw")')

all:

install:
	./install.sh

dist:
	rm -rf genfw-$(VERSION) genfw-$(VERSION).tar.gz* genfw-$(VERSION)-*.src.rpm
	mkdir genfw-$(VERSION)
	cp $(FILES) genfw-$(VERSION)/
	tar -zcvf genfw-$(VERSION).tar.gz genfw-$(VERSION)
	rpmbuild \
	    --define '_sourcedir .' \
	    --define '_builddir .' \
	    --define '_srcrpmdir .' \
	    --define '_rpmdir .' \
	    -bs --nodeps genfw.spec

sign: dist
	rpm --addsign genfw-$(VERSION)-*.src.rpm
	gpg -b genfw-$(VERSION).tar.gz
