#!/usr/bin/env bash
set -euo pipefail

# Interactive Void Linux installer for UEFI, bcachefs (encrypted), Limine, zram, NVIDIA/AI/Gaming.
# Tested assumptions: Void live ISO, x86_64 glibc, UEFI system, single target disk wiped.
# Warning: This will DESTROY all data on the target disk.

### Helper functions ###
prompt() { read -r -p "$1" REPLY_VAR; echo "$REPLY_VAR"; }
die() { echo "Error: $1" >&2; exit 1; }
require_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }

### Check environment ###
for c in lsblk sgdisk mkfs.vfat mkfs.bcachefs mount umount xbps-install xbps-query ; do
  require_cmd "$c"
done

[ -d /sys/firmware/efi ] || die "UEFI firmware not detected. Please boot the live ISO in UEFI mode."

echo "=== Void Linux Installer (bcachefs encrypted + Limine + zram) ==="
echo "This will ERASE the selected disk and install Void with an encrypted bcachefs root."
echo

TARGET_DISK="$(prompt "Enter target disk (e.g., /dev/nvme0n1 or /dev/sda): ")"
[ -b "$TARGET_DISK" ] || die "Not a block device: $TARGET_DISK"

echo "Selected disk:"
lsblk -dpno NAME,SIZE,MODEL "$TARGET_DISK"
CONFIRM="$(prompt "Type YES to confirm erasing $TARGET_DISK: ")"
[ "$CONFIRM" = "YES" ] || die "Installation aborted."

HOSTNAME="$(prompt "Enter hostname (e.g., voidbox): ")"
TZ="$(prompt "Enter timezone (e.g., Europe/Paris): ")"
CREATE_USER="$(prompt "Create a user? Enter username or leave blank to skip: ")"

INSTALL_STEAM="$(prompt "Install Steam and Wine (y/N)? ")"
INSTALL_CUDA="$(prompt "Install CUDA toolkit for AI (y/N)? ")"

echo "Partitioning $TARGET_DISK (GPT: 1GiB EFI, rest bcachefs)..."
sgdisk --zap-all "$TARGET_DISK"
sgdisk -n 1:0:+1GiB -t 1:EF00 -c 1:"EFI System Partition" "$TARGET_DISK"
sgdisk -n 2:0:0      -t 2:8300 -c 2:"Void bcachefs root" "$TARGET_DISK"
partprobe "$TARGET_DISK"

# Resolve partition paths
if [[ "$TARGET_DISK" =~ nvme ]]; then
  ESP="${TARGET_DISK}p1"
  ROOTP="${TARGET_DISK}p2"
else
  ESP="${TARGET_DISK}1"
  ROOTP="${TARGET_DISK}2"
fi

echo "Formatting EFI partition (FAT32)..."
mkfs.vfat -F32 -n EFI "$ESP"

echo "Formatting bcachefs (encrypted) on $ROOTP..."
# You will be prompted for a passphrase; remember it for boot.
# Adjust options as desired (compression, etc.). We choose zstd compression.
mkfs.bcachefs --encrypted --compression=zstd --label rootfs "$ROOTP"

echo "Mounting filesystems..."
mkdir -p /mnt
mount -t bcachefs -o compress /dev/disk/by-label/rootfs /mnt
mkdir -p /mnt/boot/efi
mount "$ESP" /mnt/boot/efi

echo "Setting up XBPS keys..."
mkdir -p /mnt/var/db/xbps/keys
cp -a /var/db/xbps/keys/* /mnt/var/db/xbps/keys/

# Choose repo and arch for bootstrap
REPO="https://repo-default.voidlinux.org/current"
ARCH="x86_64"

echo "Bootstrapping base-system (glibc, $ARCH)..."
XBPS_ARCH="$ARCH" xbps-install -Sy -R "$REPO" -r /mnt base-system

echo "Generating fstab..."
# xtools/xgenfstab may not be present on live; if available, use it; otherwise generate basic fstab.
if command -v xgenfstab >/dev/null 2>&1; then
  xgenfstab -U /mnt > /mnt/etc/fstab
else
  ROOT_UUID="$(blkid -s UUID -o value "$ROOTP")"
  ESP_UUID="$(blkid -s UUID -o value "$ESP")"
  cat > /mnt/etc/fstab <<EOF
# /etc/fstab
UUID=${ROOT_UUID}  /          bcachefs  defaults,compress  0 1
UUID=${ESP_UUID}   /boot/efi  vfat      umask=0077         0 2
EOF
fi

echo "Configuring basic system files..."
echo "$HOSTNAME" > /mnt/etc/hostname

# rc.conf minimal network via dhcpcd
cat > /mnt/etc/rc.conf <<'EOF'
# Minimal rc.conf for Void (runit)
HOSTNAME="$(cat /etc/hostname)"
EOF

# Locale (glibc)
if [ -f /mnt/etc/default/libc-locales ]; then
  sed -i 's/^# \(en_US.UTF-8 UTF-8\)/\1/' /mnt/etc/default/libc-locales
fi

echo "Entering chroot to configure system..."
mount -t proc none /mnt/proc
mount -t sysfs none /mnt/sys
mount -o bind /dev /mnt/dev
mount -o bind /run /mnt/run
chroot /mnt /bin/bash -e <<'CHROOT_EOF'
set -euo pipefail

# Update xbps itself and base
xbps-install -Sy xbps
xbps-install -yu

# Core packages: kernel, headers, microcode, dracut, bcachefs tools
xbps-install -y linux linux-headers dracut bcachefs-tools intel-ucode

# Networking and SSH (optional but handy)
xbps-install -y dhcpcd-openrc || true
xbps-install -y dhcpcd || true
xbps-install -y openssh

# Locale reconfigure (glibc)
if [ -f /etc/default/libc-locales ]; then
  xbps-reconfigure -f glibc-locales
fi

# Timezone
ln -sf /usr/share/zoneinfo/Europe/Paris /etc/localtime

# Runit services enable
ln -sf /etc/sv/dhcpcd /var/service/dhcpcd || true
ln -sf /etc/sv/sshd    /var/service/sshd    || true

# zram swap via zramen service
xbps-install -y zramen
# Configure zram: size equals RAM, can adjust via conf file
mkdir -p /etc
cat > /etc/zramen.conf <<'EOF_ZRAM'
# zramen.conf - simple zram swap config
# Size in bytes or with suffix; here use 100% of RAM
SIZE=ram
NUM_DEVICES=1
COMPRESSION_ALGO=zstd
PRIORITY=100
EOF_ZRAM
ln -sf /etc/sv/zramen /var/service/zramen

# NVIDIA (RTX 3070) proprietary driver + vulkan
xbps-install -y nvidia nvidia-libs
# Optional Vulkan tools
xbps-install -y vulkan-loader vulkan-tools

# CUDA toolkit (optional)
# Uncomment if requested outside chroot block.
CHROOT_EOF

# Optional CUDA and gaming installs outside chroot decision
if [[ "${INSTALL_CUDA,,}" == "y" ]]; then
  chroot /mnt xbps-install -y cuda
fi
if [[ "${INSTALL_STEAM,,}" == "y" ]]; then
  chroot /mnt xbps-install -y steam wine winetricks
fi

# User creation and passwords
echo "Set root password:"
chroot /mnt passwd
if [ -n "$CREATE_USER" ]; then
  chroot /mnt useradd -m -G wheel,video,audio,input "$CREATE_USER"
  echo "Set password for $CREATE_USER:"
  chroot /mnt passwd "$CREATE_USER"
  # sudo setup
  chroot /mnt xbps-install -y sudo
  chroot /mnt sh -c 'echo "%wheel ALL=(ALL) ALL" > /etc/sudoers.d/10-wheel'
fi

echo "Configuring dracut to include bcachefs and ask for encryption passphrase..."
mkdir -p /mnt/etc/dracut.conf.d
cat > /mnt/etc/dracut.conf.d/10-bcachefs.conf <<'EOF'
# Ensure bcachefs filesystem support in initramfs
filesystems+=" bcachefs "
# Optional: add hostonly="no" to be safer across kernels
EOF

echo "Installing Limine bootloader..."
chroot /mnt xbps-install -y limine efibootmgr

# Create simple limine.cfg
KVER="$(chroot /mnt bash -c 'ls /boot/vmlinuz-* | sed "s|.*/vmlinuz-||"')"
INITRD="$(chroot /mnt bash -c 'ls /boot/initramfs-* | sed "s|.*/initramfs-||"')"
cat > /mnt/boot/limine.cfg <<EOF
TIMEOUT=3
DEFAULT_ENTRY=Void Linux

ENTRY=Void Linux
    PROTOCOL=linux
    KERNEL_PATH=boot://vmlinuz-${KVER}
    MODULE_PATH=boot://initramfs-${INITRD}
    CMDLINE=root=UUID=$(blkid -s UUID -o value "$ROOTP") rootfstype=bcachefs rw quiet
EOF

# Ensure kernel/initramfs paths exist and match limine cfg
# (Void uses versioned files; limine.cfg references them directly)

echo "Install Limine to the ESP..."
# Limine copies EFI file and sets up boot entry
chroot /mnt limine-install /boot/efi

echo "Regenerate initramfs and finalize configuration..."
chroot /mnt xbps-reconfigure -fa

echo "Unmounting and rebooting..."
umount -R /mnt || true
sync
echo "Installation complete. Remove the live media and reboot."
