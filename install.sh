#!/bin/sh

PREFIX=${PREFIX:-""}
BINDIR=${BINDIR:-"$PREFIX/usr/local/bin"}
MANDIR=${MANDIR:-"$PREFIX/usr/local/share/man/man8"}
INITDIR=${INITDIR:-"$PREFIX/etc/rc.d/init.d"}

set -e
set -x

install -b -o root -g root genfw $BINDIR/genfw
install -b -o root -g root firewall.init $INITDIR/firewall

pod2man genfw > genfw.8
gzip -9 genfw.8

install -b -o root -g root genfw.8.gz $MANDIR/genfw.8.gz

chkconfig --add firewall
