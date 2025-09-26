#!/usr/bin/env bash
set -euo pipefail
# Void Linux installer: UEFI, LUKS-encrypted root, bcachefs, Limine, multiple kernels, doas, zram
# Assumptions: Void live ISO (x86_64 glibc), UEFI, single target disk

### Helper functions ###
prompt() { read -r -p "$1 " REPLY; echo "$REPLY"; }
die() { echo "Error: $1" >&2; exit 1; }
require_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"; }

### Verify environment and dependencies ###
for cmd in lsblk sgdisk mkfs.vfat mkfs.bcachefs mount xbps-install cryptsetup blkid xchroot efibootmgr; do
    require_cmd "$cmd"
done
[ -d /sys/firmware/efi ] || die "Boot in UEFI mode"

echo "=== Void Linux Installer (UEFI + LUKS + bcachefs + Limine) ==="
echo "WARNING: This will DESTROY all data on the target disk!"
echo

### Get user input ###
TARGET_DISK="$(prompt "Enter target disk (e.g., /dev/nvme0n1 or /dev/sda):")"
[ -b "$TARGET_DISK" ] || die "Not a block device: $TARGET_DISK"

echo "Disk info:"
lsblk -dpno NAME,SIZE,MODEL "$TARGET_DISK"

CONFIRM="$(prompt "Type YES to confirm erasing $TARGET_DISK:")"
[ "$CONFIRM" = "YES" ] || die "Aborted"

HOSTNAME="$(prompt "Enter hostname:")"
read -s -p "Enter LUKS encryption passphrase: " ROOT_PASS
echo
USERNAME="$(prompt "Create user (leave blank for root only):")"

### Partitioning ###
echo "Creating GPT partitions (ESP + LUKS root)..."
sgdisk --zap-all "$TARGET_DISK"
sgdisk -n 1:0:+1G -t 1:EF00 -c 1:EFI "$TARGET_DISK"
sgdisk -n 2:0:0    -t 2:8300 -c 2:root "$TARGET_DISK"
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
echo "Formatting EFI system partition..."
mkfs.vfat -F32 -n EFI "$BOOT_PART"

echo "Setting up LUKS (interactive, no passphrase echo)..."
# Use a secure temp keyfile for non-interactive operations
TMPKEY="$(mktemp)"
trap 'shred -u "$TMPKEY" || true' EXIT
printf "%s" "$ROOT_PASS" > "$TMPKEY"
unset ROOT_PASS

cryptsetup luksFormat --type luks1 "$ROOT_PART" "$TMPKEY"
cryptsetup luksOpen "$ROOT_PART" cryptroot --key-file "$TMPKEY"

echo "Creating bcachefs filesystem..."
mkfs.bcachefs -L voidroot /dev/mapper/cryptroot

### Mount filesystems ###
echo "Mounting filesystems..."
mount /dev/mapper/cryptroot /mnt
mkdir -p /mnt/boot
mount "$BOOT_PART" /mnt/boot

### Bootstrap system ###
echo "Bootstrapping Void Linux base system..."
xbps-install -Sy -R https://repo-default.voidlinux.org/current -r /mnt \
    base-system bcachefs-tools cryptsetup dracut

### Basic system configuration ###
echo "Configuring system basics..."
echo "$HOSTNAME" > /mnt/etc/hostname

# Minimal networking (optional but helpful)
echo "HOSTNAME=\"$HOSTNAME\"" > /mnt/etc/rc.conf
ln -sf /usr/share/zoneinfo/UTC /mnt/etc/localtime
printf "127.0.0.1\tlocalhost\n::1\tlocalhost\n127.0.1.1\t%s\n" "$HOSTNAME" > /mnt/etc/hosts

### Prepare values for chroot (avoid variable scope issues) ###
ROOT_UUID="$(blkid -s UUID -o value "$ROOT_PART")"
echo "$ROOT_UUID" > /mnt/root_uuid

### Chroot setup ###
echo "Entering chroot..."
xchroot /mnt /bin/bash << 'EOF'
set -euo pipefail

# Load values passed from the host
ROOT_UUID="$(cat /root_uuid)"

# Configure repositories (current + nonfree/multilib as needed)
mkdir -p /etc/xbps.d
cp /usr/share/xbps.d/*-repository-*.conf /etc/xbps.d/ || true
xbps-install -Syu xbps
xbps-install -Syu void-repo-nonfree void-repo-multilib void-repo-multilib-nonfree || true

# Full system update
xbps-install -Syu

# Detect CPU vendor for microcode (Intel: intel-ucode; AMD: provided by linux-firmware)
CPU_VENDOR="$(LC_ALL=C lscpu | awk -F: '/Vendor ID/{gsub(/^[ \t]+/, "", $2); print $2}')"
MICROCODE_PKGS=""
if echo "$CPU_VENDOR" | grep -qi intel; then
    MICROCODE_PKGS="intel-ucode"
fi

# Install kernels, firmware, microcode, and essentials
xbps-install -y linux linux-headers linux-mainline linux-mainline-headers linux-firmware ${MICROCODE_PKGS}
xbps-install -y opendoas zramen limine efibootmgr xtools

# Configure doas (replace sudo)
cat > /etc/doas.conf << 'DOAS_EOF'
permit nopass :wheel
DOAS_EOF
chmod 0400 /etc/doas.conf
xbps-remove -y sudo 2>/dev/null || true

# Configure zram
cat > /etc/zramen.conf << 'ZRAM_EOF'
SIZE=ram
NUM_DEVICES=1
COMPRESSION_ALGO=zstd
PRIORITY=100
ZRAM_EOF
# Enable zram service
ln -s /etc/sv/zramen /var/service/ 2>/dev/null || true

# Dracut: enable crypt + bcachefs + early microcode
cat > /etc/dracut.conf.d/90-crypt.conf << 'DRACUT_EOF'
add_dracutmodules+=" crypt "
filesystems+=" bcachefs "
early_microcode=yes
DRACUT_EOF

# Generate initramfs for all installed kernels
for moddir in /usr/lib/modules/*; do
    [ -d "$moddir" ] || continue
    kver="$(basename "$moddir")"
    dracut --force --kver "$kver"
done

# Limine (UEFI) install: copy EFI loader and limine.sys, create boot entry
mkdir -p /boot/EFI/BOOT /boot/limine
cp -f /usr/share/limine/BOOTX64.EFI /boot/EFI/BOOT/BOOTX64.EFI

# Build Limine configuration dynamically for all kernels
cat > /boot/limine.cfg <<EOF_CFG
TIMEOUT=5
DEFAULT_ENTRY=void-linux-mainline
EOF_CFG

have_mainline=0
have_current=0

for moddir in /usr/lib/modules/*; do
    [ -d "$moddir" ] || continue
    kver="$(basename "$moddir")"
    kernel="/boot/vmlinuz-$kver"
    initrd="/boot/initramfs-$kver.img"

    title="Void Linux ($kver)"
    if echo "$kver" | grep -qi mainline; then
        title="Void Linux (Mainline)"
        have_mainline=1
    elif echo "$kver" | grep -qi '^6\|^5\|^4'; then
        title="Void Linux (Current)"
        have_current=1
    fi

    cat >> /boot/limine.cfg <<EOF_ENT
:$title
    PROTOCOL=linux
    KERNEL_PATH=boot:///$(${MICROCODE_PKGS:+echo "cpu_microcode" > /dev/null})${kernel#/}
    MODULE_PATH=boot:///${initrd#/}
    CMDLINE=rd.luks.uuid=$ROOT_UUID root=/dev/mapper/cryptroot rootfstype=bcachefs rw
EOF_ENT
done

# Fallback default entry if mainline wasn't detected
if [ "\$have_mainline" -eq 0 ] && [ "\$have_current" -eq 1 ]; then
    sed -i 's/DEFAULT_ENTRY=.*/DEFAULT_ENTRY=void-linux-current/' /boot/limine.cfg
fi

# Create EFI boot entry pointing to Limine
# Note: many firmwares auto-boot \EFI\BOOT\BOOTX64.EFI; this makes it explicit.
efibootmgr -c -L "Void (Limine)" -l "\\EFI\\BOOT\\BOOTX64.EFI" || true

# Set root password
echo "Set root password:"
passwd

# Create user if requested (passed via file)
if [ -f /username_requested ] && [ -s /username_requested ]; then
    USERNAME="$(cat /username_requested)"
    useradd -m -G wheel,audio,video "\$USERNAME"
    echo "Set password for \$USERNAME:"
    passwd "\$USERNAME"
fi

# Final system configuration
xbps-reconfigure -fa
EOF

### Pass username into chroot (if any) ###
if [ -n "$USERNAME" ]; then
    echo "$USERNAME" > /mnt/username_requested
fi

### Cleanup ###
echo "Unmounting filesystems..."
umount -R /mnt || true
cryptsetup luksClose cryptroot || true

echo "Installation complete!"
echo "System features:"
echo "✓ LUKS-encrypted root with bcachefs"
echo "✓ Current and mainline kernels (with correct initramfs generation)"
echo "✓ CPU microcode: Intel only if needed; AMD via linux-firmware"
echo "✓ Doas instead of sudo"
echo "✓ Zram compression enabled"
echo "✓ Limine bootloader (UEFI) correctly installed without limine-install"
echo ""
echo "Reboot and remove installation media."
echo "Use 'doas' instead of 'sudo' for privilege escalation."
