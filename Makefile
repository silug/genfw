FILES   = genfw firewall.init Makefile install.sh
VERSION = $(shell perl -MExtUtils::MakeMaker \
                       -le 'print ExtUtils::MM_Unix::parse_version("","genfw")')

install:
	./install.sh

dist:
	rm -rf genfw-$(VERSION) genfw-$(VERSION).tar.gz
	mkdir genfw-$(VERSION)
	cp $(FILES) genfw-$(VERSION)/
	tar -zcvf genfw-$(VERSION).tar.gz genfw-$(VERSION)
