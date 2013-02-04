#!/bin/sh

delete_raid_hp () {
	HPACUCLI="hpacucli"
	ID=`$HPACUCLI ctrl all show | awk '{ print $6 }'`
	for SLOT in $ID;
	do
		for LD in $($HPACUCLI ctrl slot=0 ld all show | awk '$1 ~ "logical" { print $2}');
 		do
			echo "y" | $HPACUCLI ctrl slot=$SLOT ld $LD delete
		done
	done
}

create_raid_hp () {
	RAID_LVL="1+0"
	HPACUCLI="hpacucli"
	ID=`$HPACUCLI ctrl all show | awk '{ print $6 }'`
	for SLOT in $ID;
	do
		for DRIVE in $($HPACUCLI ctrl slot=$SLOT pd all show | awk '$1 ~ "drive" { print $2 }');                                                                                                         
		do
			TMP_DRIVES=${TMP_DRIVES},${DRIVE}
		done
		LIST_DRIVES=${TMP_DRIVES#?}
		$HPACUCLI ctrl slot=$SLOT create type=ld drives=$LIST_DRIVES raid=$RAID_LVL
	done
}

partitions () {
	DEV=/dev/cciss/c0d0
	TYPE=gpt
	PARTED=parted
	BOOT=515
	SWAP=16000
	SLASH=30000
    # be sure to wipe gpt out
    SIZE=`cat /sys/block/cciss\!c0d0/size`
    SKIP=`expr $SIZE - 34`
    BLOCK=`cat /sys/block/cciss\!c0d0/queue/physical_block_size`
    dd if=/dev/zero of=/dev/cciss/c0d0 bs=$BLOCK count=34
    dd if=/dev/zero of=/dev/cciss/c0d0 bs=$BLOCK count=34 skip=$SKIP
	$PARTED $DEV --script -- mklabel $TYPE
    $PARTED $DEV --script -- mkpart primary ext2 1 3
    $PARTED $DEV --script -- name 1 bios_grub
    $PARTED $DEV --script -- set 1 bios_grub on
	$PARTED $DEV --script -- mkpart primary ext2 3 $BOOT
	$PARTED $DEV --script -- set 2 boot on
	$PARTED $DEV --script -- name 2 boot
	$PARTED $DEV --script -- mkpart primary linux-swap $BOOT `expr $BOOT + $SWAP`
	$PARTED $DEV --script -- name 3 swap
	$PARTED $DEV --script -- mkpart primary ext2 `expr $BOOT + $SWAP` `expr $BOOT + $SWAP + $SLASH`
	$PARTED $DEV --script -- name 4 slash
}

filesystems () {
	DEV_BOOT="/dev/cciss/c0d0p2"
	DEV_SWAP="/dev/cciss/c0d0p3"
	DEV_SLASH="/dev/cciss/c0d0p4"
	MKEXT3="mkfs.ext3"
	MKEXT4="mkfs.ext4"
	MKSWAP="mkswap"
	MOUNT="mount"
	DEST_MOUNT="/mnt"

	$MKEXT3 -L boot $DEV_BOOT
	$MKSWAP -L swap $DEV_SWAP
	$MKEXT4 -L slash $DEV_SLASH

	$MOUNT $DEV_SLASH $DEST_MOUNT
	mkdir -p $DEST_MOUNT/boot
	$MOUNT $DEV_BOOT $DEST_MOUNT/boot
}

install () {
	DEST_MOUNT="/mnt"
	DEBOOTSTRAP="debootstrap"
	MIRROR="http://ftp.fr.debian.org/debian"
	VERSION="squeeze"

	$DEBOOTSTRAP --arch=amd64 $VERSION $DEST_MOUNT $MIRROR
}

custom () {
	DEST_MOUNT="/mnt"
	BLKID="blkid"
	DEV_BOOT="/dev/cciss/c0d0p2"
	DEV_SWAP="/dev/cciss/c0d0p3"
	DEV_SLASH="/dev/cciss/c0d0p4"

	# configure loopback
	echo "auto lo\niface lo inet loopback" > $DEST_MOUNT/etc/network/interfaces

	# configure all interfaces to dhcp
	i=0
	while [ $i -ne "$(ip l | grep state | wc -l)" ]
	do
		echo "allow-hotplug eth$i\niface eth$i inet dhcp" >> $DEST_MOUNT/etc/network/interfaces
		i=`expr $i + 1`
	done

	# configure dns to use one extern dns
	echo "nameserver 74.82.42.42" > $DEST_MOUNT/etc/resolv.conf

	# configure hostname to install-last_digit_of_ip
	echo "install-`ifconfig  | grep 'inet addr:'| grep -v '127.0.0.1' | cut -d. -f4 | awk '{print $1}' | head -n 1`" > $DEST_MOUNT/etc/hostname

    echo "deb http://ftp.fr.debian.org/debian/ squeeze main contrib non-free
deb-src http://ftp.fr.debian.org/debian/ squeeze main contrib non-free

deb http://security.debian.org/ squeeze/updates main contrib non-free
deb-src http://security.debian.org/ squeeze/updates main contrib non-free

# squeeze-updates, previously known as 'volatile'
deb http://ftp.fr.debian.org/debian/ squeeze-updates main contrib non-free
deb-src http://ftp.fr.debian.org/debian/ squeeze-updates main contrib non-free" > $DEST_MOUNT/etc/apt/sources.list

	echo "UUID=$($BLKID $DEV_BOOT -t LABEL=boot -o list | awk ' $3 ~ "boot" {print $5}') /boot	ext3	defaults			0 1
UUID=$($BLKID $DEV_SWAP -t LABEL=swap -o list | awk ' $3 ~ "swap" {print $6}') none	swap	sw				0 0
UUID=$($BLKID $DEV_SLASH -t LABEL=slash -o list | awk ' $3 ~ "slash" {print $5}') /	ext4	relatime,errors=remount-ro	0 1" > /mnt/etc/fstab
}

kernel_grub () {
    DEST_MOUNT=/mnt
    mount -t proc none $DEST_MOUNT/proc
    mount -o bind /dev $DEST_MOUNT/dev
    mount -o bind /sys $DEST_MOUNT/sys
    chroot $DEST_MOUNT aptitude update
    DEBIAN_FRONTEND=noninteractive chroot $DEST_MOUNT aptitude install linux-image-amd64 firmware-bnx2 grub-pc openssh-server -y
    chroot $DEST_MOUNT grub-install --recheck --no-floppy /dev/cciss/c0d0
    chroot $DEST_MOUNT grub-mkconfig -o /boot/grub/grub.cfg
    chroot $DEST_MOUNT echo "root:toto" | chpasswd
    mkdir -p $DEST_MOUNT/root/.ssh
    echo "ssh-rsa AAAAB3NzaC1yc2EAAAABIwAAAQEAslaQRTlW1a5EXyFw9Y158MOfoajW8dzUwo31tzHHbRx84ZXiI+/3PpLmn5yoLeJHHPRFgqU6UV5z4/iB9vxO8exMwCjnYuIO/02twK8gIvIRL3mzwaLa4fHXCBW3XZwi5YDZ+nU3t0G6XxWo8hfgiVauLfxdFMuuu8qAU79bZzvB3NLj4WcqN+dK3uomF7VB/0eZxkBZ9HXJOr5QV+oZQUv6S9L43450AkDu72aCl5g1jCp3LaHVBBzwXPReeExnQYOQ25M8lSye7CtwIc7HtnHmnHkmgsBKSsavnDXp6oJ86IAbDP3kKPq8t3I/ZkWEuAHnuGcxEcQG7mTJ7+M/ow== root@pxe" > $DEST_MOUNT/root/.ssh/authorized_keys
    umount $DEST_MOUNT/sys
    umount $DEST_MOUNT/dev
    umount $DEST_MOUNT/proc
}

unmount () {
	sync
	umount /mnt/boot
	umount /mnt
	sleep 2
}

unmount
delete_raid_hp
create_raid_hp
partitions
filesystems
install
custom
kernel_grub
unmount

#reboot
