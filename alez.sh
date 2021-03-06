#!/bin/bash
# Arch Linux Easy ZFS (ALEZ) installer 0.3
# by Dan MacDonald 2016

# Check script is being run as root
if [[ $EUID -ne 0 ]]; then
   echo "Arch Linux Easy ZFS installer must be run as root"
   exit 1
fi

# Set a default locale during install to avoid mandb error when indexing man pages
export LANG=C

# Run stuff in the ZFS chroot install function
chrun() {
	arch-chroot /mnt /bin/bash -c "$1"
}

# List and enumerate attached disks function
lsdsks() {
	lsblk
	echo -e "\nAttached disks : \n"
	disks=(`lsblk | grep disk | awk '{print $1}'`)
	ndisks=${#disks[@]}
	for (( d=0; d<${ndisks}; d++ )); do
	   echo -e "$d - ${disks[d]}\n"
	done
}

# No frills BIOS/GPT partitioning
read -p "Do you want to GPT partition any drives for a BIOS (non-UEFI) machine? (N/y): " dopart
while [ "$dopart" == "y" ] || [ "$dopart" == "Y" ]; do
  lsdsks
  blkdev=-1
  while [ "$blkdev" -ge "$ndisks" ] || [ "$blkdev" -lt 0 ]; do
     read -p "Enter the number of the disk you want to partition, between 0 and $(($ndisks-1)) : " blkdev
  done
  read -p "ALL data on /dev/${disks[$blkdev]} will be lost? Proceed? (N/y) : " blkconf
  if [ "$blkconf" == "y" ] || [ "$blkconf" == "Y" ]; then
        echo "GPT partitioning /dev/${disks[$blkdev]}..."
        parted --script /dev/${disks[$blkdev]} mklabel gpt mkpart non-fs 0% 2 mkpart primary 2 100% set 1 bios_grub on set 2 boot on
  else
        break
  fi
  read -p "Do you want to partition another device? (N/y) : " dopart
done

echo -e "\nArch Linux Easy ZFS (ALEZ) installer 0.3\n\nBy Dan MacDonald 2016\n\n"
echo -e "Please make sure you are connected to the Internet before running ALEZ.\n\n"
echo -e "Available partitions:\n\n"

# Read partitions into an array and print enumerated
partids=(`ls /dev/disk/by-id/*`)
ptcount=${#partids[@]}
for (( p=0; p<${ptcount}; p++ )); do
   echo -e "$p - ${partids[p]}\n"
done

# Try exporting zroot pool in case previous installation attempt failed
zfs umount -a &> /dev/null
zpool export zroot &> /dev/null

# Create zpool
zpconf="0"
echo -e "If you used this script to create your partitions, choose partitions ending with -part2\n\n"
while read -p "Do you want to create a single or double disk (mirrored) zpool? (1/2) : " zpconf 
do if (( $zpconf == 1 || $zpconf == 2 )); then
 if [ "$zpconf" == "1" ]; then 
   read -p "Enter the number of the partition above that you want to create a new zpool on : " zps
   echo "Creating a single disk zpool..."
   zpool create -f -d -o feature@async_destroy=enabled -o feature@empty_bpobj=enabled -o \
   feature@lz4_compress=enabled -o feature@spacemap_histogram=enabled -o feature@enabled_txg=enabled zroot ${partids[$zps]}
   break
 elif [ "$zpconf" == "2" ]; then
   read -p "Enter the number of the first partition : " zp1
   read -p "Enter the number of the second partition : " zp2
   echo "Creating a mirrored zpool..."
   zpool create zroot mirror -f -d -o feature@async_destroy=enabled -o feature@empty_bpobj=enabled \
   -o feature@lz4_compress=enabled -o feature@spacemap_histogram=enabled -o feature@enabled_txg=enabled ${partids[$zp1]} ${partids[$zp2]}
   break
 fi
 fi
 echo "Please enter 1 or 2"
done 

echo "Creating datasets..."
zfs create -o mountpoint=none zroot/data
zfs create -o mountpoint=none zroot/ROOT
zfs create -o mountpoint=/ zroot/ROOT/default
zfs create -o mountpoint=/home zroot/data/home

# This umount is not always required but can prevent problems with the next command
zfs umount -a

echo "Setting ZFS mount options..."
zfs set mountpoint=/ zroot/ROOT/default
zfs set mountpoint=legacy zroot/data/home
zpool set bootfs=zroot/ROOT/default zroot

echo "Exporting and importing pool..."
zpool export zroot
zpool import `zpool import | grep id: | awk '{print $2}'` -R /mnt zroot

echo "Installing Arch base system..."
pacstrap /mnt base

echo "Copy zpool.cache..."
mkdir /mnt/etc/zfs
cp /etc/zfs/zpool.cache /mnt/etc/zfs

echo "Add fstab entries..."
echo -e "zroot/ROOT/default / zfs defaults,noatime 0 0\nzroot/data/home /home zfs defaults,noatime 0 0" >> /mnt/etc/fstab

echo "Add Arch ZFS pacman repo..."
echo -e "\n[archzfs]\nServer = http://archzfs.com/\$repo/x86_64" >> /mnt/etc/pacman.conf

echo "Modify HOOKS in mkinitcpio.conf..."
sed -i 's/HOOKS=.*/HOOKS="base udev autodetect modconf block keyboard zfs filesystems"/g' /mnt/etc/mkinitcpio.conf

echo "Adding Arch ZFS repo key in chroot..."
chrun "pacman-key -r 5E1ABF240EE7A126; pacman-key --lsign-key 5E1ABF240EE7A126"

echo "Installing ZFS and GRUB in chroot..."
chrun "pacman -Sy; pacman -S --noconfirm zfs-linux grub os-prober"

echo "Adding Arch ZFS entry to GRUB menu..."
awk -i inplace '/10_linux/ && !x {print $0; print "menuentry \"Arch Linux ZFS\" {\n\tlinux /ROOT/default/@/boot/vmlinuz-linux \
	zfs=zroot/ROOT/default rw\n\tinitrd /ROOT/default/@/boot/initramfs-linux.img\n}"; x=1; next} 1' /mnt/boot/grub/grub.cfg
echo "Update initial ramdisk (initrd) with ZFS support..."
chrun "mkinitcpio -p linux"

echo -e "Enable systemd ZFS service...\n"
chrun "systemctl enable zfs.target"

# Write script to create symbolic links for partition ids to work around a GRUB bug that can cause grub-install to fail - hackety hack
echo -e "ptids=(\`cd /dev/disk/by-id/;ls\`)\nidcount=\${#ptids[@]}\nfor (( c=0; c<\${idcount}; c++ )) do\ndevs[c]=\$(readlink /dev/disk/by-id/\${ptids[\$c]} | sed 's/\.\.\/\.\.\///')\nln -s /dev/\${devs[c]} /dev/\${ptids[c]}\ndone" > /mnt/home/partlink.sh

echo -e "Create symbolic links for partition ids to work around a grub-install bug...\n"
chrun "sh /home/partlink.sh"
rm -f /mnt/home/partlink.sh

lsdsks

# Install GRUB
echo -e "NOTE: If you have installed Arch onto a mirrored pool then you should install GRUB onto both disks\n"
read -p "Do you want to install GRUB onto any of the attached disks? (N/y): " dogrub
while [ "$dogrub" == "y" ] || [ "$dogrub" == "Y" ]; do
  read -p "Enter the number of the disk to install GRUB to : " gn
  if [ "$gn" -ge 0 -a "$gn" -le "$ndisks" ]; then
        echo "Installing GRUB to /dev/${disks[$gn]}..."
        chrun "grub-install /dev/${disks[$gn]}"
  else
        echo "Please enter a number between 0 and $(($ndisks-1))"
  fi
  read -p "Do you want to install GRUB to another disk? (N/y) : " dogrub
done

echo "Exporting the pool"
zfs umount -a
zpool export zroot

echo "Arch ZFS installation complete"
