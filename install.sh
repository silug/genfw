#!/bin/sh

INSTPREFIX=${INSTPREFIX:-""}
PREFIX=${PREFIX:-"$INSTPREFIX/usr/local"}
BINDIR=${BINDIR:-"$PREFIX/bin"}
MANDIR=${MANDIR:-"$PREFIX/share/man"}
MAN8DIR=${MAN8DIR:-"$MANDIR/man8"}
INITDIR=${INITDIR:-"$INSTPREFIX/etc/rc.d/init.d"}
CONFIGDIR=${CONFIGDIR:-"$INSTPREFIX/etc/sysconfig/genfw"}

set -e
set -x

install -b -o root -g root genfw $BINDIR/genfw
install -b -o root -g root firewall.init $INITDIR/firewall

mkdir -p $CONFIGDIR
for file in rules modules ; do
    if [ ! -f $CONFIGDIR/$file ] ; then
        touch $CONFIGDIR/$file
    fi
done

pod2man genfw > genfw.8
if [ -z "$INSTPREFIX" ] ; then
    gzip -9 genfw.8
    install -b -o root -g root genfw.8.gz $MANDIR/genfw.8.gz
else
    install -b -o root -g root genfw.8 $MANDIR/genfw.8
fi

if [ -z "$INSTPREFIX" ] ; then
    chkconfig --add firewall
fi
