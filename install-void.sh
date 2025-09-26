#!/usr/bin/env bash
set -euo pipefail
# Enhanced Void Linux installer: UEFI, LUKS-encrypted root, Limine, multiple kernels, doas, zram
# Assumptions: Void live ISO, x86_64 glibc, UEFI, single target disk

### Helper functions ###
prompt() { read -r -p "$1 " REPLY; echo "$REPLY"; }
die() { echo "Error: $1" >&2; exit 1; }
require_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"; }

### Verify environment and dependencies ###
for cmd in lsblk sgdisk mkfs.vfat mkfs.bcachefs mount xbps-install cryptsetup blkid xchroot; do
    require_cmd "$cmd"
done
[ -d /sys/firmware/efi ] || die "Boot in UEFI mode"

echo "=== Enhanced Void Linux Installer ==="
echo "WARNING: This will DESTROY all data on the target disk!"
echo

### Get user input ###
TARGET_DISK="$(prompt "Enter target disk (e.g., /dev/sda):")"
[ -b "$TARGET_DISK" ] || die "Not a block device: $TARGET_DISK"

echo "Disk info:"
lsblk -dpno NAME,SIZE,MODEL "$TARGET_DISK"

CONFIRM="$(prompt "Type YES to confirm erasing $TARGET_DISK:")"
[ "$CONFIRM" = "YES" ] || die "Aborted"

HOSTNAME="$(prompt "Enter hostname:")"
ROOT_PASS="$(prompt "Enter LUKS encryption passphrase:")"
USERNAME="$(prompt "Create user (leave blank for root only):")"

### Partitioning ###
echo "Creating partitions..."
sgdisk --zap-all "$TARGET_DISK"
sgdisk -n 1:0:+1G -t 1:EF00 -c 1:EFI "$TARGET_DISK"
sgdisk -n 2:0:0 -t 2:8300 -c 2:root "$TARGET_DISK"
partprobe "$TARGET_DISK"

# Set partition variables
if [[ "$TARGET_DISK" =~ nvme ]]; then
    BOOT_PART="${TARGET_DISK}p1"
    ROOT_PART="${TARGET_DISK}p2"
else
    BOOT_PART="${TARGET_DISK}1"
    ROOT_PART="${TARGET_DISK}2"
fi

### Format partitions ###
echo "Formatting boot partition..."
mkfs.vfat -F32 -n BOOT "$BOOT_PART"

echo "Setting up LUKS encryption..."
echo -n "$ROOT_PASS" | cryptsetup luksFormat --type luks1 "$ROOT_PART" -
echo -n "$ROOT_PASS" | cryptsetup luksOpen "$ROOT_PART" cryptroot -

echo "Creating bcachefs filesystem..."
mkfs.bcachefs -L voidroot /dev/mapper/cryptroot

### Mount filesystems ###
echo "Mounting filesystems..."
mount /dev/mapper/cryptroot /mnt
mkdir -p /mnt/boot
mount "$BOOT_PART" /mnt/boot

### Bootstrap system ###
echo "Bootstrapping Void Linux..."
xbps-install -Sy -R https://repo-default.voidlinux.org/current -r /mnt \
    base-system bcachefs-tools cryptsetup

### Basic system configuration ###
echo "Configuring system..."
echo "$HOSTNAME" > /mnt/etc/hostname

### Chroot setup ###
echo "Entering chroot..."
xchroot /mnt /bin/bash << 'EOF'
set -e

# Configure repositories (current + nonfree for microcode)
mkdir -p /etc/xbps.d
cp /usr/share/xbps.d/*-repository-*.conf /etc/xbps.d/

# Install essential packages with both kernels and microcode
xbps-install -Sy xbps
xbps-install -yu

# Install kernels, firmware, and microcode
xbps-install -y linux linux-mainline linux-firmware intel-ucode

# Install system utilities
xbps-install -y opendoas zramen limine efibootmgr

# Configure doas (replace sudo)
cat > /etc/doas.conf << 'DOAS_EOF'
permit persist :wheel
DOAS_EOF
chmod 0400 /etc/doas.conf

# Remove sudo if present
xbps-remove -y sudo 2>/dev/null || true

# Configure zram
cat > /etc/zramen.conf << 'ZRAM_EOF'
SIZE=ram
NUM_DEVICES=1
COMPRESSION_ALGO=zstd
PRIORITY=100
ZRAM_EOF

# Enable zram service
ln -sf /etc/sv/zramen /var/service/ 2>/dev/null || true

# Configure dracut for LUKS and both kernels
cat > /etc/dracut.conf.d/90-crypt.conf << 'DRACUT_EOF'
add_dracutmodules+=" crypt "
filesystems+=" bcachefs "
omit_dracutmodules+=" nvdimm fs-lib "
early_microcode=yes
DRACUT_EOF

# Generate initramfs for both kernels
for kver in /usr/lib/modules/*; do
    if [ -d "$kver" ]; then
        kver=$(basename "$kver")
        dracut --force --kver "$kver"
    fi
done

# Install Limine bootloader
limine-install /boot

# Get partition UUIDs for boot configuration
ROOT_UUID=$(blkid -s UUID -o value "$ROOT_PART")
LUKS_UUID=$(blkid -s UUID -o value /dev/mapper/cryptroot)

# Create Limine configuration with both kernel options
cat > /boot/limine.cfg << 'LIMINE_EOF'
TIMEOUT=5
DEFAULT_ENTRY=void-linux-mainline

:Void Linux (Mainline)
    PROTOCOL=linux
    KERNEL_PATH=boot:///vmlinuz-linux-mainline
    MODULE_PATH=boot:///initramfs-linux-mainline.img
    CMDLINE=rd.luks.uuid=$ROOT_UUID root=/dev/mapper/cryptroot rootfstype=bcachefs rw

:Void Linux (Current)
    PROTOCOL=linux
    KERNEL_PATH=boot:///vmlinuz-linux
    MODULE_PATH=boot:///initramfs-linux.img
    CMDLINE=rd.luks.uuid=$ROOT_UUID root=/dev/mapper/cryptroot rootfstype=bcachefs rw
LIMINE_EOF

# Set root password
echo "Setting root password:"
passwd

# Create user if requested
if [ -n "$USERNAME" ]; then
    useradd -m -G wheel,audio,video "$USERNAME"
    echo "Setting password for $USERNAME:"
    passwd "$USERNAME"
fi

# Final system configuration
xbps-reconfigure -fa
EOF

### Cleanup ###
echo "Unmounting filesystems..."
umount -R /mnt || true
cryptsetup luksClose cryptroot || true

echo "Installation complete!"
echo "System features:"
echo "✓ LUKS-encrypted root with bcachefs"
echo "✓ Both current and mainline kernels"
echo "✓ Intel microcode updates"
echo "✓ Doas instead of sudo"
echo "✓ Zram compression"
echo "✓ Limine bootloader"
echo ""
echo "Reboot and remove installation media."
echo "Use 'doas' instead of 'sudo' for privilege escalation."
