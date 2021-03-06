# This file is part of LTSP, https://ltsp.github.io
# Copyright 2019 the LTSP team, see AUTHORS
# SPDX-License-Identifier: GPL-3.0-or-later

# Sourced by LTSP initramfs scripts

# Source the ltsp.sh functions without any tools
LTSP_MAIN=true . /ltsp/ltsp.sh

if [ -f /scripts/functions ]; then
    # Running on initramfs-tools
    rb . /scripts/functions
else
    # Running on dracut
    rootmnt=/sysroot
    # TODO: check which other variables we need, e.g. ROOT, netroot...
fi

# This hook is supposed to run after networking is configured and before root
# is mounted. Currently it's unused, but it may help if we ever want to:
#  * Repair wrong networking when proxyDHCP is used, and:
#    - Syslinux with IPAPPEND 2, or
#    - Grub with local kernel and remote server
#  * Possibly source ltsp-client.sh for $SERVER etc
#  * Patch NBD
main_ltsp_premount() {
    true
}

# Make root writable using a tmpfs overlay and override init
main_ltsp_bottom() {
    local loop

    warn "Running $0"
    kernel_variables
    img=${nfsroot##*/}
    if [ -n "$LTSP_LOOP" ]; then
        while read -r loop<&3; do
            NO_PROC=1 rb mount_file "$rootmnt/${loop#/}" "$rootmnt"
        done 3<<EOF
$(echo "$LTSP_LOOP" | tr "," "\n")
EOF
    else
        rb mount_dir "$rootmnt" "$rootmnt"
    fi
    is_writeable "$rootmnt" || rb overlay_root
    init_ltsp_d
    rb override_init
    mount | grep -w dev || echo ========NODEV========
}

init_ltsp_d() {
    local service

    test -e "$rootmnt/etc/fstab" &&
        printf "# Empty fstab generated by LTSP.\n" > "$rootmnt/etc/fstab"
    # Use loglevel from /proc/cmdline instead of resetting it
    if grep -qsw netconsole /proc/cmdline; then
        rw rm -f "$rootmnt/etc/sysctl.d/10-console-messages.conf"
    fi
    test -f "$rootmnt/usr/lib/tmpfiles.d/systemd.conf" &&
        rw sed "s|^[aA]|# &|" -i "$rootmnt/usr/lib/tmpfiles.d/systemd.conf"
    # Silence dmesg: Failed to open system journal: Operation not supported
    # Cap journal to 1M TODO make it configurable
    test -f "$rootmnt/etc/systemd/journald.conf" &&
        rw sed -e "s|[^[alpha]]*Storage=.*|Storage=volatile|" \
            -e "s|[^[alpha]]*RuntimeMaxUse=.*|RuntimeMaxUse=1M|" \
            -e "s|[^[alpha]]*ForwardToSyslog=.*|ForwardToSyslog=no|" \
            -i "$rootmnt/etc/systemd/journald.conf"
    test -f "$rootmnt/etc/systemd/system.conf" &&
        rw sed "s|[^[alpha]]*DefaultTimeoutStopSec=.*|DefaultTimeoutStopSec=10s|" \
            -i "$rootmnt/etc/systemd/system.conf"
    test -f "$rootmnt/etc/systemd/user.conf" &&
        rw sed "s|[^[alpha]]*DefaultTimeoutStopSec=.*|DefaultTimeoutStopSec=10s|" \
            -i "$rootmnt/etc/systemd/user.conf"
    for service in apt-daily.service apt-daily-upgrade.service snapd.seeded.service rsyslog.service; do
        rw ln -s /dev/null "$rootmnt/etc/systemd/system/$service"
    done
    rs rm -f "$rootmnt/etc/init.d/shared-folders"
    rw rm -f "$rootmnt/etc/cron.daily/mlocate"
    rw rm -f "$rootmnt/var/crash"*
    rw rm -f "$rootmnt/etc/resolv.conf"
    echo "nameserver 194.63.238.4" > "$rootmnt/etc/resolv.conf"
    nfsmount 10.161.254.11:/var/rw/home "$rootmnt/home"
    printf "qwer';lk\nqwer';lk\n" | rw chroot "$rootmnt" passwd
    rb chroot "$rootmnt" useradd \
	    --comment 'LTSP live user,,,' \
	    --groups adm,cdrom,sudo,dip,plugdev,lpadmin  \
	    --create-home \
	    --password '$6$bKP3Tahd$a06Zq1j.0eKswsZwmM7Ga76tKNCnueSC.6UhpZ4AFbduHqWA8nA5V/8pLHYFC4SrWdyaDGCgHeApMRNb7mwTq0' \
	    --shell /bin/bash \
	    --uid 998 \
	    --user-group \
	    ltsp
}

is_writeable() {
    local dst

    dst="$1"
    chroot "$dst" /usr/bin/test -w / && return 0
    rw mount -o remount,rw "$dst"
    chroot "$dst" /usr/bin/test -w / && return 0
    return 1
}

modprobe_overlay() {
    grep -q overlay /proc/filesystems &&
        return 0
    modprobe overlay &&
        grep -q overlay /proc/filesystems &&
        return 0
    if [ -f "$rootmnt/lib/modules/$(uname -r)/kernel/fs/overlayfs/overlay.ko" ]; then
        rb mv /lib/modules /lib/modules.real
        rb ln -s "$rootmnt/lib/modules" /lib/modules
        rb modprobe overlay
        rb rm /lib/modules
        rb mv /lib/modules.real /lib/modules
        grep -q overlay /proc/filesystems &&
            return 0
    fi
    return 1
}

override_init() {
    # To avoid specifying an init=, we override the real init.
    # We can't mount --bind as it's in use by libraries and can't be unmounted.
    # In some cases we could create a symlink to /run/ltsp/ltsp.sh,
    # but it doesn't work in all initramfs-tools versions.
    # So let's be safe and use plain cp.
    rb mv "$rootmnt/sbin/init" "$rootmnt/sbin/init.real"
    rb cp /ltsp/init "$rootmnt/sbin/init"
    # Jessie needs a 3.18+ kernel and this initramfs-tools hack:
    if grep -qs jessie /etc/os-release; then
        echo "init=${init:-/sbin/init}" >> /scripts/init-bottom/ORDER
    fi
    # Move ltsp to /run to make it available after pivot_root.
    # But initramfs-tools mounts /run with noexec; so use a symlink.
    rb mv /ltsp /run/initramfs/ltsp/
    rb ln -s initramfs/ltsp/ltsp /run/ltsp
}

overlay_root() {
    rb modprobe_overlay
    rb mkdir -p /run/initramfs/ltsp
    rb mount -t tmpfs -o mode=0755 tmpfs /run/initramfs/ltsp
    rb mkdir -p /run/initramfs/ltsp/up /run/initramfs/ltsp/work
    rb mount -t overlay -o upperdir=/run/initramfs/ltsp/up,lowerdir=$rootmnt,workdir=/run/initramfs/ltsp/work overlay "$rootmnt"
    # Seen on 20190516 on stretch-mate-sch and bionic-minimal
    if run-init -n "$rootmnt" /sbin/init 2>&1 | grep -q console; then
        warn "$0 working around https://bugs.debian.org/811479"
        rb mount --bind /dev "$rootmnt/dev"
    fi
}
