#!/usr/bin/env bash
set -euo pipefail

# ================== User-configurable ==================
DISK="${DISK:-/dev/sda}"         # Target SATA SSD
HOSTNAME="${HOSTNAME:-voidbox}"
ARCH="${ARCH:-x86_64}"           # glibc x86_64
REPO="${REPO:-https://repo-default.voidlinux.org/current}"
TIMEZONE="${TIMEZONE:-Europe/Paris}"
USERNAME="${USERNAME:-mateo}"    # Set "" to skip
ROOT_PW="${ROOT_PW:-void}"
USER_PW="${USER_PW:-void}"
ZRAM_SIZE_PERCENT="${ZRAM_SIZE_PERCENT:-50}"  # ~16 GiB on 32 GiB RAM
ZRAM_ALGO="${ZRAM_ALGO:-zstd}"

# ================== Pre-flight checks & tool install ==================
if [ ! -b "$DISK" ]; then
  echo "ERROR: DISK '$DISK' is not a block device (e.g., /dev/sda)."
  exit 1
fi

# Auto-install required tools if missing (Void Linux)
need_tools="gptfdisk parted cryptsetup bcachefs-tools dracut xtools dosfstools e2fsprogs"
for t in sgdisk partprobe cryptsetup bcachefs dracut mkfs.vfat xgenfstab xchroot; do
  if ! command -v "$t" >/dev/null 2>&1; then
    echo "Installing missing tool for '$t'..."
    case "$t" in
      sgdisk)   xbps-install -Sy gptfdisk ;;
      partprobe) xbps-install -Sy parted ;;
      cryptsetup) xbps-install -Sy cryptsetup ;;
      bcachefs) xbps-install -Sy bcachefs-tools ;;
      dracut)   xbps-install -Sy dracut ;;
      mkfs.vfat) xbps-install -Sy dosfstools ;;
      xgenfstab|xchroot) xbps-install -Sy xtools ;;
      *) : ;;
    esac
  fi
done

# ================== Confirmation (destructive) ==================
echo "This will ERASE and partition $DISK for UEFI with LUKS + bcachefs:"
echo " - Partition 1: 1 GiB EFI System Partition (FAT32)"
echo " - Partition 2: LUKS container for bcachefs root"
read -rp "Type 'YES' to proceed: " CONFIRM
[ "$CONFIRM" = "YES" ] || { echo "Aborted."; exit 1; }

# ================== Partitioning (GPT, UEFI) ==================
wipefs -a "$DISK"
sgdisk --zap-all "$DISK"

# ESP: 1 MiB -> +1 GiB
sgdisk -n 1:2048:+1GiB -t 1:EF00 -c 1:"EFI System" "$DISK"
# LUKS/root: remainder
sgdisk -n 2:0:0        -t 2:8300 -c 2:"Void root (LUKS)" "$DISK"

partprobe "$DISK"
ESP="${DISK}1"
CRYPT="${DISK}2"

# ================== Encryption (LUKS) ==================
echo "Creating LUKS on $CRYPT (you will be prompted for a passphrase)..."
cryptsetup luksFormat "$CRYPT"
cryptsetup open "$CRYPT" cryptroot

# ================== Filesystems ==================
mkfs.vfat -F32 -n EFI "$ESP"

# Determine compression option name supported by bcachefs-tools
COMP_OPT="zstd"
if ! bcachefs format --help 2>&1 | grep -q "zstd"; then
  echo "zstd not supported by current bcachefs-tools, falling back to lz4."
  COMP_OPT="lz4"
fi

# bcachefs format (single device, SSD-friendly, compression, label)
bcachefs format \
  --label voidroot \
  --compression="${COMP_OPT}" \
  --metadata_checksum=crc32c \
  /dev/mapper/cryptroot

# ================== Mount target ==================
mount -t bcachefs /dev/mapper/cryptroot /mnt
mkdir -p /mnt/boot/efi
mount "$ESP" /mnt/boot/efi

# Bind mounts for chroot operations
mkdir -p /mnt/{proc,sys,dev}
for d in proc sys dev; do
  mount --bind "/$d" "/mnt/$d"
done

# ================== Bootstrap Void base (per Void chroot guide) ==================
mkdir -p /mnt/var/db/xbps/keys
cp /var/db/xbps/keys/* /mnt/var/db/xbps/keys/ || true

export XBPS_ARCH="$ARCH"
xbps-install -S -r /mnt -R "$REPO" base-system

# Install xtools and enable all repos
xbps-install -Sy xtools void-repo-nonfree void-repo-multilib void-repo-multilib-nonfree

# Update and sync
xbps-install -Syu

# Kernel, firmware, headers, initramfs, filesystem tools, bootloader, essentials
xbps-install -S -r /mnt -R "$REPO" \
  linux linux-headers linux-firmware dracut bcachefs-tools cryptsetup limine xtools \
  dosfstools parted \
  sudo dhcpcd \
  pciutils usbutils \
  git curl wget neovim htop tmux \
  python3 python3-pip python3-virtualenv \
  zramen \
  vulkan-loader nvidia nvidia-libs nvidia-libs-32bit nvidia-opencl

# ================== fstab ==================
xgenfstab -U /mnt > /mnt/etc/fstab

# ================== Basic config ==================
echo "$HOSTNAME" > /mnt/etc/hostname
ln -sf "/usr/share/zoneinfo/$TIMEZONE" /mnt/etc/localtime

# glibc locales
cat > /mnt/etc/default/libc-locales <<'EOF'
en_US.UTF-8 UTF-8
fr_FR.UTF-8 UTF-8
EOF

# ================== LUKS integration (crypttab) ==================
CRYPT_UUID="$(blkid -s UUID -o value "$CRYPT")"
cat > /mnt/etc/crypttab <<EOF
cryptroot UUID=$CRYPT_UUID none luks
EOF

# ================== Dracut (initramfs) ==================
mkdir -p /mnt/etc/dracut.conf.d
cat > /mnt/etc/dracut.conf.d/bcachefs-crypt.conf <<'EOF'
add_dracutmodules+=" bcachefs crypt "
compress="zstd"
EOF

# ================== Limine (UEFI bootloader) ==================
mkdir -p /mnt/boot/efi/EFI/BOOT /mnt/boot/efi/void

# Copy Limine EFI binary (package may install to one of these paths)
if [ -f /mnt/usr/share/limine/BOOTX64.EFI ]; then
  cp /mnt/usr/share/limine/BOOTX64.EFI /mnt/boot/efi/EFI/BOOT/BOOTX64.EFI
elif [ -f /mnt/usr/share/limine/EFI/BOOT/BOOTX64.EFI ]; then
  cp /mnt/usr/share/limine/EFI/BOOT/BOOTX64.EFI /mnt/boot/efi/EFI/BOOT/BOOTX64.EFI
else
  echo "WARNING: Limine BOOTX64.EFI not found in expected paths; adjust if needed."
fi

# ================== Chroot: accounts, services, locales ==================
chroot /mnt /usr/bin/bash -c "echo 'root:${ROOT_PW}' | chpasswd"
chroot /mnt xbps-reconfigure -f glibc-locales

# Enable networking
chroot /mnt ln -sf /etc/sv/dhcpcd /var/service

# User with sudo via wheel
if [ -n "$USERNAME" ]; then
  chroot /mnt useradd -m -G wheel -s /bin/bash "$USERNAME"
  chroot /mnt /usr/bin/bash -c "echo '${USERNAME}:${USER_PW}' | chpasswd"
  chroot /mnt sed -i 's/^# %wheel/%wheel/' /etc/sudoers
fi

# ================== Build initramfs, copy kernel/initramfs to ESP ==================
chroot /mnt xbps-reconfigure -fa

# Detect newest kernel version
KVER="$(chroot /mnt sh -c 'ls -1 /boot/vmlinuz-* | sed s@/boot/vmlinuz-@@ | sort -V | tail -n1')"
[ -n "$KVER" ] || { echo "ERROR: Could not detect kernel version in /mnt/boot."; exit 1; }

cp "/mnt/boot/vmlinuz-${KVER}" /mnt/boot/efi/void/vmlinuz
if [ -f "/mnt/boot/initramfs-${KVER}.img" ]; then
  cp "/mnt/boot/initramfs-${KVER}.img" /mnt/boot/efi/void/initramfs
elif [ -f "/mnt/boot/initrd" ]; then
  cp "/mnt/boot/initrd" /mnt/boot/efi/void/initramfs
else
  echo "ERROR: initramfs image not found."
  exit 1
fi

# Limine configuration (dracut-friendly LUKS parameters)
cat > /mnt/boot/efi/limine.cfg <<EOF
TIMEOUT=5
DEFAULT_ENTRY=Void

ENTRY=Void
PROTOCOL=linux
KERNEL_PATH=boot:///void/vmlinuz
MODULE_PATH=boot:///void/initramfs
CMDLINE=rd.luks=1 rd.luks.uuid=$CRYPT_UUID rd.luks.name=$CRYPT_UUID=cryptroot root=LABEL=voidroot rw quiet splash
EOF

# ================== Keep ESP in sync after kernel updates ==================
mkdir -p /mnt/etc/kernel.d/post-install
cat > /mnt/etc/kernel.d/post-install/99-copy-to-esp.sh <<'EOF'
#!/bin/sh
set -eu
ESP_DIR="/boot/efi/void"
KVER="$1"
[ -d "$ESP_DIR" ] || mkdir -p "$ESP_DIR"
cp "/boot/vmlinuz-${KVER}" "${ESP_DIR}/vmlinuz"
if [ -f "/boot/initramfs-${KVER}.img" ]; then
  cp "/boot/initramfs-${KVER}.img" "${ESP_DIR}/initramfs"
elif [ -f "/boot/initrd" ]; then
  cp "/boot/initrd" "${ESP_DIR}/initramfs"
fi
EOF
chmod +x /mnt/etc/kernel.d/post-install/99-copy-to-esp.sh

# ================== zram swap ==================
cat > /mnt/etc/zramen.conf <<EOF
devices=1
algo=${ZRAM_ALGO}
percentage=${ZRAM_SIZE_PERCENT}
EOF
chroot /mnt ln -sf /etc/sv/zramen /var/service

# ================== Bcachefs snapshot helpers ==================
mkdir -p /mnt/usr/local/sbin
cat > /mnt/usr/local/sbin/bcachefs-snapshot <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
SNAP="${1:-snap-$(date +%Y%m%d-%H%M%S)}"
bcachefs subvolume snapshot / "$SNAP"
echo "Created snapshot: $SNAP"
EOF
chmod +x /mnt/usr/local/sbin/bcachefs-snapshot

cat > /mnt/usr/local/sbin/bcachefs-rollback <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ $# -lt 1 ] && { echo "Usage: bcachefs-rollback <snapshot>"; exit 1; }
sync
bcachefs subvolume rollback / "$1"
echo "Rollback done. Consider rebooting."
EOF
chmod +x /mnt/usr/local/sbin/bcachefs-rollback

# ================== Cleanup ==================
echo "Finalizing..."
for d in dev sys proc; do
  umount "/mnt/$d" || true
done

echo "Installation complete."
echo " - Reboot, enter your LUKS passphrase, and boot into Void."
echo " - Verify NVIDIA (nvidia-smi), Vulkan, network, and locales."
echo " - Snapshot before big updates: bcachefs-snapshot pre-upgrade"
echo " - Rollback if needed: bcachefs-rollback pre-upgrade
"

