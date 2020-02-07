#!/bin/bash
if [ $(id -u) != "0" ]; then
	echo "This script must be run as root" 1>&2
	exit 1
fi

set -e
echo -e 'Welcome to the GentooX setup, the installation script mainly consists of:
\t- providing this script with a target partition where system will be installed
\t- extracting precompiled squashfs system image into the specified parition
\t- setting up GRUB, BIOS or UEFI mode will be used depending how system was booted
\tGentooX uses openSUSE-style BTRFS root partition & subvolumes for snapshotting with snapper
\tGentooX requires minimum of 16GB of space, and use of BTRFS is hardcoded

Manual installation can be done via:
  mounting target partition to /mnt/install
  unsquashfs -f -i -d /mnt/install/ /mnt/cdrom/image.squashfs
  /usr/local/sbin/genfstab -U >> /mnt/install/etc/fstab
  /usr/local/sbin/arch-chroot /mnt/install/
  grub-install --target=x86_64-efi for UEFI mode or grub-install --target=i386-pc (BIOS only)
  grub-mkconfig -o /boot/grub/grub.cfg'


declare -A PART_SCHEME
PART_SCHEME[a]="Automatic"
PART_SCHEME[m]="Manual"
if [[ -d /sys/firmware/efi/ ]]; then UEFI_MODE=y; fi


setup_btrfs () {
	DEVICE=$1

	mkfs.btrfs -f -L GENTOO $DEVICE
	mkdir /mnt/install
	mount $DEVICE /mnt/install

	btrfs subvolume create /mnt/install/@
	btrfs subvolume create /mnt/install/@/.snapshots
	mkdir /mnt/install/@/.snapshots/1
	btrfs subvolume create /mnt/install/@/.snapshots/1/snapshot
	mkdir -p /mnt/install/@/boot/grub/
	#btrfs subvolume create /mnt/install/@/boot/grub/i386-pc
	#btrfs subvolume create /mnt/install/@/boot/grub/x86_64-efi
	btrfs subvolume create /mnt/install/@/home
	btrfs subvolume create /mnt/install/@/opt
	btrfs subvolume create /mnt/install/@/root
	btrfs subvolume create /mnt/install/@/srv
	btrfs subvolume create /mnt/install/@/tmp
	mkdir /mnt/install/@/usr/
	btrfs subvolume create /mnt/install/@/usr/local
	btrfs subvolume create /mnt/install/@/var

	chattr +C /mnt/install/@/var

	echo "<?xml version=\"1.0\"?>
	<snapshot>
	  <type>single</type>
	  <num>1</num>
	  <date>$(date)</date>
	  <description>first root filesystem</description>
	</snapshot>" > /mnt/install/@/.snapshots/1/info.xml

	btrfs subvolume set-default $(btrfs subvolume list /mnt/install | grep "@/.snapshots/1/snapshot" | grep -oP '(?<=ID )[0-9]+') /mnt/install
	umount /mnt/install
	mount $DEVICE /mnt/install

	# ls /mnt/install should respond with empty result

	mkdir /mnt/install/.snapshots
    mkdir /mnt/install/boot
	#mkdir -p /mnt/install/boot/grub/i386-pc
	#mkdir -p /mnt/install/boot/grub/x86_64-efi
	mkdir /mnt/install/home
	mkdir /mnt/install/opt
	mkdir /mnt/install/root
	mkdir /mnt/install/srv
	mkdir /mnt/install/tmp
	mkdir -p /mnt/install/usr/local
	mkdir /mnt/install/var

	mount $DEVICE /mnt/install/.snapshots -o subvol=@/.snapshots
	#mount $DEVICE /mnt/install/boot/grub/i386-pc -o subvol=@/boot/grub/i386-pc
	#mount $DEVICE /mnt/install/boot/grub/x86_64-efi -o subvol=@/boot/grub/x86_64-efi
	mount $DEVICE /mnt/install/home -o subvol=@/home
	mount $DEVICE /mnt/install/opt -o subvol=@/opt
	mount $DEVICE /mnt/install/root -o subvol=@/root
	mount $DEVICE /mnt/install/srv -o subvol=@/srv
	mount $DEVICE /mnt/install/tmp -o subvol=@/tmp
	mount $DEVICE /mnt/install/usr/local -o subvol=@/usr/local
	mount $DEVICE /mnt/install/var -o subvol=@/var
}


echo -e "\nDetected drives:\n$(lsblk | grep disk)"
while :; do
	echo
	read -erp "Automatic partitioning (a) or manual partitioning (will launch gparted)? [a/m] " -n 1 partitioning_mode
	if [[ $partitioning_mode = "a" ]]; then
		read -erp "Enter drive to be formatted for GentooX installation: " -i "/dev/sda" drive
        if [[ ! -z $UEFI_MODE ]]; then partition="${drive}2"; else partition="${drive}1"; fi
	elif [[ $partitioning_mode = "m" ]]; then
        if [[ ! -z $UEFI_MODE ]]; then echo "EFI boot detected, please also create EF00 ESP EFI partition..."; fi
		gparted &> /dev/null &
		read -erp "Enter formatted partition for GentooX installation: " -i "/dev/sda1" partition
	else
		echo "Invalid option"
		continue
	fi

	read -erp "Partitioning: ${PART_SCHEME[$partitioning_mode]}
    Partition: $partition
    Is this correct? [y/n] " -n 1 yn
	if [[ $yn == "y" ]]; then
		break
	fi
done


if [[ $partitioning_mode = "a" ]]; then
  if [[ ! -z $UEFI_MODE ]]; then
	echo -e "o\nY\nn\n\n\n+256M\nEF00\nn\n2\n\n\n\nw\nY\n" | gdisk $drive
    mkfs.vfat -F32 "${drive}1"
    UEFI_PART="${drive}1"
	setup_btrfs "${drive}2"
    mkdir -p /mnt/install/boot/efi
    mount $UEFI_PART /mnt/install/boot/efi
  else
	echo -e "o\nn\np\n1\n\n\nw" | fdisk /dev/$drive
	setup_btrfs "${drive}1"
  fi
else
  # user done the partitioning
  read -erp "Enter formatted EF00 ESP partition for EFI: " -i "/dev/sda1" efi_partition
  setup_btrfs $partition
fi

echo "extracting precompiled image.squashfs GentooX image to the target partition..."
unsquashfs -f -d /mnt/install/ /mnt/cdrom/image.squashfs
/usr/local/sbin/genfstab -U /mnt/install/ >> /mnt/install/etc/fstab

mount -t proc none /mnt/install/proc
mount --rbind /dev /mnt/install/dev
mount --rbind /sys /mnt/install/sys

cd /mnt/install/
cat <<HEREDOC | chroot .
source /etc/profile && export PS1="(chroot) \$PS1"
if [[ -d /sys/firmware/efi/ ]]; then UEFI_MODE=y; fi
if [[ -z $drive ]]; then drive=$(echo $partition | sed 's/[0-9]\+\$//'); fi
sensors-detect --auto
rc-update add lm_sensors default
NCORES=\$(getconf _NPROCESSORS_ONLN)
sed -i -r "s/^MAKEOPTS=\"([^\"]*)\"$/MAKEOPTS=\"-j\$NCORES\"/g" /etc/portage/make.conf
sed -i -r "s/^NTHREADS=\"([^\"]*)\"$/NTHREADS=\"\$NCORES\"/g" /etc/portage/make.conf
#rc-update add zfs-import boot
#rc-update add zfs-mount boot
if [[ ! -z $UEFI_MODE ]]; then
  grub-install --target=x86_64-efi
else
  grub-install --target=i386-pc $drive
fi
grub-mkconfig -o /boot/grub/grub.cfg
HEREDOC

umount -l /mnt/install/boot/efi /mnt/install/var /mnt/install/usr/local /mnt/install/tmp /mnt/install/srv /mnt/install/root /mnt/install/opt /mnt/install/home /mnt/install/boot/grub/x86_64-efi /mnt/install/boot/grub/i386-pc /mnt/install/.snapshots /mnt/install
echo "Installation complete, you may remove the install media and reboot"