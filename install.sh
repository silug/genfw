#!/bin/sh

PREFIX=${PREFIX:-""}
BINDIR=${BINDIR:-"$PREFIX/usr/local/bin"}
MANDIR=${MANDIR:-"$PREFIX/usr/local/man/man8"}
INITDIR=${INITDIR:-"$PREFIX/etc/rc.d/init.d"}

set -e
set -x

install -b -o root -g root genfw $BINDIR/genfw
install -b -o root -g root firewall.init $INITDIR/firewall

chkconfig --add firewall
