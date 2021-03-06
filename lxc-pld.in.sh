#!/bin/sh

#
# template script for generating PLD Linux container for LXC
#

#
# lxc: Linux Container library

# Authors:
# Elan Ruusamäe <glen@pld-linux.org>

# This library is free software; you can redistribute it and/or
# modify it under the terms of the GNU Lesser General Public
# License as published by the Free Software Foundation; either
# version 2.1 of the License, or (at your option) any later version.

# This library is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
 # MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# Lesser General Public License for more details.

# You should have received a copy of the GNU Lesser General Public
# License along with this library; if not, write to the Free Software
# Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA 02111-1307 USA

# Configuration
arch=$(uname -m)
cache_base=@LOCALSTATEDIR@/cache/lxc/pld/$arch
default_path=@LXCPATH@
root_password=root

if [ -e /etc/os-release ]; then
	# This is a shell friendly configuration file.  We can just source it.
	# What we're looking for in here is the ID, VERSION_ID and the CPE_NAME
	. /etc/os-release
	echo "Host CPE ID from /etc/os-release: ${CPE_NAME}"
fi

if [ "${CPE_NAME}" != "" -a "${ID}" = "pld" -a "${VERSION_ID}" != "" ]; then
	pld_host_ver=${VERSION_ID}
	is_pld=true
elif [ -e /etc/pld-release ]; then
	# Only if all other methods fail, try to parse the pld-release file.
	pld_host_ver=$(sed -e '/PLD /!d' -e 's/^\([0-9.]*\)\sPLD.*/\1/' < /etc/pld-release)
	if [ "$pld_host_ver" != "" ]; then
		is_pld=true
	fi
fi

# Map a few architectures to their generic PLD Linux repository archs.
case "$pld_host_ver:$arch" in
3.0:i586) arch=i486 ;;
esac

configure_pld()
{

	# disable selinux
	mkdir -p $rootfs_path/selinux
	echo 0 > $rootfs_path/selinux/enforce

	# configure the network using the dhcp
	sed -i -e "s/^HOSTNAME=.*/HOSTNAME=${utsname}/" ${rootfs_path}/etc/sysconfig/network

	# set hostname on systemd
	if [ $release = "3.0" ]; then
		echo "${utsname}" > ${rootfs_path}/etc/hostname
	fi

	# set minimal hosts
	test -e $rootfs_path/etc/hosts || \
	cat <<EOF > $rootfs_path/etc/hosts
127.0.0.1 localhost.localdomain localhost $utsname
::1                 localhost6.localdomain6 localhost6
EOF

	dev_path="${rootfs_path}/dev"
	rm -rf $dev_path
	mkdir -p $dev_path
	mknod -m 666 ${dev_path}/null c 1 3
	mknod -m 666 ${dev_path}/zero c 1 5
	mknod -m 666 ${dev_path}/random c 1 8
	mknod -m 666 ${dev_path}/urandom c 1 9
	mkdir -m 755 ${dev_path}/pts
	mkdir -m 1777 ${dev_path}/shm
	mknod -m 666 ${dev_path}/tty c 5 0
	mknod -m 666 ${dev_path}/tty0 c 4 0
	mknod -m 666 ${dev_path}/tty1 c 4 1
	mknod -m 666 ${dev_path}/tty2 c 4 2
	mknod -m 666 ${dev_path}/tty3 c 4 3
	mknod -m 666 ${dev_path}/tty4 c 4 4
	mknod -m 600 ${dev_path}/console c 5 1
	mknod -m 666 ${dev_path}/full c 1 7
	mknod -m 600 ${dev_path}/initctl p
	mknod -m 666 ${dev_path}/ptmx c 5 2

	echo "setting root passwd to $root_password"
	echo "root:$root_password" | chroot $rootfs_path chpasswd

	return 0
}

configure_pld_init()
{
	# default powerfail action waits 2 minutes. for lxc we want it immediately
	sed -i -e '/^pf::powerfail:/ s,/sbin/shutdown.*,/sbin/halt,' ${rootfs_path}/etc/inittab
}

configure_pld_systemd()
{
	unlink ${rootfs_path}/etc/systemd/system/default.target
	chroot ${rootfs_path} ln -s /dev/null /etc/systemd/system/udev.service
	chroot ${rootfs_path} ln -s /lib/systemd/system/multi-user.target /etc/systemd/system/default.target

	# Actually, the After=dev-%i.device line does not appear in the
	# Fedora 17 or Fedora 18 systemd getty@.service file. It may be left
	# over from an earlier version and it's not doing any harm. We do need
	# to disable the "ConditionalPathExists=/dev/tty0" line or no gettys are
	# started on the ttys in the container. Lets do it in an override copy of
	# the service so it can still pass rpm verifies and not be automatically
	# updated by a new systemd version.  --  mhw  /\/\|=mhw=|\/\/

	sed -e 's/^ConditionPathExists=/# ConditionPathExists=/' \
		-e 's/After=dev-%i.device/After=/' \
	< ${rootfs_path}/lib/systemd/system/getty@.service \
	> ${rootfs_path}/etc/systemd/system/getty@.service

	# Setup getty service on the 4 ttys we are going to allow in the
	# default config. Number should match lxc.tty
	for i in 1 2 3 4; do
		ln -sf ../getty@.service ${rootfs_path}/etc/systemd/system/getty.target.wants/getty@tty${i}.service
	done
}

download_pld()
{

	# check the mini pld was not already downloaded
	INSTALL_ROOT=$cache/partial
	mkdir -p $INSTALL_ROOT
	if [ $? -ne 0 ]; then
		echo "Failed to create '$INSTALL_ROOT' directory"
		return 1
	fi

	# download a mini pld into a cache
	echo "Downloading PLD Linux minimal ..."
	POLDEK="poldek --root $INSTALL_ROOT --noask --nohold --noignore"
	PKG_LIST="basesystem filesystem pld-release rpm poldek vserver-packages rc-scripts pwdutils mingetty"

	mkdir -p $INSTALL_ROOT@LOCALSTATEDIR@/lib/rpm
	rpm --root $INSTALL_ROOT --initdb
	$POLDEK -u $PKG_LIST

	if [ $? -ne 0 ]; then
		echo "Failed to download the rootfs, aborting."
		return 1
	fi

	mv "$INSTALL_ROOT" "$cache/rootfs"
	echo "Download complete."

	return 0
}

copy_pld()
{

	# make a local copy of the minipld
	echo -n "Copying rootfs to $rootfs_path ..."
	cp -a $cache/rootfs/* $rootfs_path || return 1
	return 0
}

update_pld()
{
	POLDEK="poldek --root $cache/rootfs --noask"
	$POLDEK --upgrade-dist
}

install_pld()
{
	mkdir -p @LOCALSTATEDIR@/lock/subsys/
	(
		flock -x 9
		if [ $? -ne 0 ]; then
			echo "Cache repository is busy."
			return 1
		fi

		echo "Checking cache download in $cache/rootfs ... "
		if [ ! -e "$cache/rootfs" ]; then
			download_pld
			if [ $? -ne 0 ]; then
				echo "Failed to download 'pld base'"
				return 1
			fi
		else
			echo "Cache found. Updating..."
			update_pld
			if [ $? -ne 0 ]; then
				echo "Failed to update 'pld base', continuing with last known good cache"
			else
				echo "Update finished"
			fi
		fi

		echo "Copy $cache/rootfs to $rootfs_path ... "
		copy_pld
		if [ $? -ne 0 ]; then
			echo "Failed to copy rootfs"
			return 1
		fi

		return 0
	) 9>@LOCALSTATEDIR@/lock/subsys/lxc-pld

	return $?
}

copy_configuration()
{

	mkdir -p $config_path
	grep -q "^lxc.rootfs" $config_path/config 2>/dev/null || echo "lxc.rootfs = $rootfs_path" >> $config_path/config
	cat <<EOF >> $config_path/config
lxc.utsname = $utsname
lxc.tty = 4
lxc.pts = 1024
lxc.mount = $config_path/fstab
lxc.cap.drop = sys_module mac_admin mac_override sys_time

lxc.autodev = $auto_dev

# When using LXC with apparmor, uncomment the next line to run unconfined:
#lxc.aa_profile = unconfined

## Devices
# Allow all devices
#lxc.cgroup.devices.allow = a
# Deny all devices
lxc.cgroup.devices.deny = a
# Allow to mknod all devices (but not using them)
lxc.cgroup.devices.allow = c *:* m
lxc.cgroup.devices.allow = b *:* m

# /dev/null and zero
lxc.cgroup.devices.allow = c 1:3 rwm
lxc.cgroup.devices.allow = c 1:5 rwm
# consoles
lxc.cgroup.devices.allow = c 5:1 rwm
lxc.cgroup.devices.allow = c 5:0 rwm
lxc.cgroup.devices.allow = c 4:0 rwm
lxc.cgroup.devices.allow = c 4:1 rwm
# /dev/{,u}random
lxc.cgroup.devices.allow = c 1:9 rwm
lxc.cgroup.devices.allow = c 1:8 rwm
lxc.cgroup.devices.allow = c 136:* rwm
lxc.cgroup.devices.allow = c 5:2 rwm
# rtc
lxc.cgroup.devices.allow = c 254:0 rm
EOF

	cat <<EOF > $config_path/fstab
proc            proc         proc    nodev,noexec,nosuid 0 0
sysfs           sys          sysfs defaults  0 0
EOF
	if [ $? -ne 0 ]; then
		echo "Failed to add configuration"
		return 1
	fi

	return 0
}

clean()
{

	if [ ! -e $cache ]; then
		exit 0
	fi

	# lock, so we won't purge while someone is creating a repository
	(
		flock -x 9
		if [ $? != 0 ]; then
			echo "Cache repository is busy."
			exit 1
		fi

		echo -n "Purging the download cache for PLD Linux $release..."
		rm --preserve-root --one-file-system -rf $cache && echo "Done." || exit 1
		exit 0
	) 9>@LOCALSTATEDIR@/lock/subsys/lxc-pld
}

usage()
{
	cat <<EOF
usage:
	$1 -n|--name=<container_name>
		[-p|--path=<path>] [-c|--clean] [-R|--release=<PLD Release>] [--fqdn=<network name of container>] [-A|--arch=<arch of the container>]
		[-h|--help]
Mandatory args:
  -n,--name         container name, used to as an identifier for that container from now on
Optional args:
  -p,--path         path to where the container will be created, defaults to @LXCPATH@. The container config will go under @LXCPATH@ in that case
  --rootfs          path for actual rootfs.
  -c,--clean        clean the cache
  -R,--release      PLD Linux release for the new container. if the host is PLD Linux, then it will default to the host's release.
	 --fqdn         fully qualified domain name (FQDN) for DNS and system naming
  -A,--arch         NOT USED YET. Define what arch the container will be [i686,x86_64]
  -h,--help         print this help
EOF
	return 0
}

options=$(getopt -o hp:n:cR: -l help,path:,rootfs:,name:,clean,release:,fqdn: -- "$@")
if [ $? -ne 0 ]; then
	usage $(basename $0)
	exit 1
fi
eval set -- "$options"

while :; do
	case "$1" in
		-h|--help)      usage $0 && exit 0;;
		-p|--path)      path=$2; shift 2;;
		--rootfs)       rootfs=$2; shift 2;;
		-n|--name)      name=$2; shift 2;;
		-c|--clean)     clean=$2; shift 2;;
		-R|--release)   release=$2; shift 2;;
		--fqdn)         utsname=$2; shift 2;;
		--)             shift 1; break ;;
		*)              break ;;
	esac
done

if [ ! -z "$clean" -a -z "$path" ]; then
	clean || exit 1
	exit 0
fi

if [ -z "${utsname}" ]; then
	utsname=${name}
fi

# This follows a standard "resolver" convention that an FQDN must have
# at least two dots or it is considered a local relative host name.
# If it doesn't, append the dns domain name of the host system.
#
# This changes one significant behavior when running
# "lxc_create -n Container_Name" without using the
# --fqdn option.
#
# Old behavior:
#    utsname and hostname = Container_Name
# New behavior:
#    utsname and hostname = Container_Name.Domain_Name

if [ $(expr "$utsname" : '.*\..*\.') = 0 ]; then
	if [ -n "$(dnsdomainname)" ]; then
		utsname=${utsname}.$(dnsdomainname)
	fi
fi

needed_pkgs=""
type poldek >/dev/null 2>&1
if [ $? -ne 0 ]; then
	needed_pkgs="poldek $needed_pkgs"
fi

#type curl >/dev/null 2>&1
#if [ $? -ne 0 ]; then
#	needed_pkgs="curl $needed_pkgs"
#fi

if [ -n "$needed_pkgs" ]; then
	echo "Missing commands: $needed_pkgs"
	echo "Please install these using \"sudo poldek -u $needed_pkgs\""
	exit 1
fi

if [ -z "$path" ]; then
	path=$default_path/$name
fi

if [ -z "$release" ]; then
	if [ "$is_pld" -a "$pld_host_ver" ]; then
		release=$pld_host_ver
	else
		echo "This is not a PLD Linux host and release missing, defaulting to 3.0. use -R|--release to specify release"
		release=3.0
	fi
fi

# pld th have systemd. We need autodev enabled to keep systemd from causing problems.
if [ $release = 3.0 ]; then
	auto_dev="0"
else
	auto_dev="0"
fi

if [ "$(id -u)" != "0" ]; then
	echo "This script should be run as 'root'"
	exit 1
fi

if [ -z "$rootfs" ]; then
    rootfs_path=$path/rootfs
    # check for 'lxc.rootfs' passed in through default config by lxc-create
    # TODO: should be lxc.rootfs.mount used instead?
    if grep -q '^lxc.rootfs' $path/config 2>/dev/null ; then
            rootfs_path=$(awk -F= '/^lxc.rootfs =/{ print $2 }' $path/config)
    fi
else
    rootfs_path=$rootfs
fi
config_path=$default_path/$name
cache=$cache_base/$release

revert()
{
	echo "Interrupted, so cleaning up"
	lxc-destroy -n $name
	# maybe was interrupted before copy config
	rm -rf $path
	rm -rf $default_path/$name
	echo "exiting..."
	exit 1
}

trap revert SIGHUP SIGINT SIGTERM

copy_configuration
if [ $? -ne 0 ]; then
	echo "Failed write configuration file"
	exit 1
fi

install_pld
if [ $? -ne 0 ]; then
	echo "Failed to install PLD Linux"
	exit 1
fi

configure_pld
if [ $? -ne 0 ]; then
	echo "Failed to configure PLD Linux for a container"
	exit 1
fi

# If the systemd configuration directory exists - set it up for what we need.
if [ -d ${rootfs_path}/etc/systemd/system ]; then
	configure_pld_systemd
fi

# This configuration (rc.sysinit) is not inconsistent with the systemd stuff
# above and may actually coexist on some upgraded systems. Let's just make
# sure that, if it exists, we update this file, even if it's not used...
if [ -f ${rootfs_path}/etc/rc.sysinit ]; then
	configure_pld_init
fi

if [ ! -z $clean ]; then
	clean || exit 1
	exit 0
fi
echo "container rootfs and config created"
