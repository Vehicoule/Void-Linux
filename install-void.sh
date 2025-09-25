#!/usr/bin/env bash
set -euo pipefail

# ===== UI helpers =====
say()  { printf "\n==> %s\n" "$*"; }
warn() { printf "\n[!] %s\n" "$*"; }
die()  { printf "\nERROR: %s\n" "$*" >&2; exit 1; }
ask()  { local p="$1" d="${2:-}"; read -rp "$p [${d}]: " a || true; echo "${a:-$d}"; }

# ===== Preconditions =====
[ "$(id -u)" -eq 0 ] || die "Run as root."
[ -d /sys/firmware/efi ] || die "UEFI firmware not detected. This installer targets UEFI only."

say "Interactive Void Linux install (bcachefs encrypted + zstd, Limine, zram)"

# ===== Interactive inputs =====
DISK="$(ask 'Target disk (DESTROYS ALL DATA!) e.g., /dev/sda' '/dev/sda')"
[ -b "$DISK" ] || die "Block device not found: $DISK"

ESP_SIZE_MIB="$(ask 'ESP size in MiB' '512')"
HOSTNAME="$(ask 'Hostname' 'voidbox')"
TIMEZONE="$(ask 'Timezone (e.g., Europe/Paris)' 'Europe/Paris')"
ARCH="$(ask 'XBPS arch' 'x86_64')"
REPO="$(ask 'Repo URL' 'https://repo-default.voidlinux.org/current')"

USERNAME="$(ask 'Create user (empty to skip)' 'mateo')"
USER_PW=""
if [ -n "$USERNAME" ]; then
  USER_PW="$(ask "Password for user '$USERNAME'" 'void')"
fi
ROOT_PW="$(ask 'Root password' 'void')"

ZRAM_PCT="$(ask 'zram percentage of RAM (0-100)' '50')"
ZRAM_ALGO="zstd"

BCACHEFS_LABEL="$(ask 'Filesystem label for root' 'voidroot')"
BCH_PASS="$(ask 'Encryption passphrase (required; will be prompted at boot)' '')"
[ -n "$BCH_PASS" ] || die "Passphrase cannot be empty."

say "Summary"
echo "  Disk:       $DISK"
echo "  ESP:        ${ESP_SIZE_MIB} MiB"
echo "  Hostname:   $HOSTNAME"
echo "  Timezone:   $TIMEZONE"
echo "  XBPS Arch:  $ARCH"
echo "  Repo:       $REPO"
echo "  User:       ${USERNAME:-<none>}"
echo "  zram:       ${ZRAM_PCT}% (${ZRAM_ALGO})"
echo "  FS label:   $BCACHEFS_LABEL"
read -rp "Type YES to proceed with destructive partitioning: " CONFIRM
[ "$CONFIRM" = "YES" ] || die "Aborted."

# ===== Ensure required tools =====
say "Ensuring required tools are present"
ensure() {
  for cmd in "$@"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      case "$cmd" in
        sgdisk)               xbps-install -Sy gptfdisk ;;
        partprobe)            xbps-install -Sy parted ;;
        mkfs.vfat)            xbps-install -Sy dosfstools ;;
        bcachefs|mount.bcachefs|bcachefs-fsck|bcachefs) xbps-install -Sy bcachefs-tools ;;
        dracut)               xbps-install -Sy dracut ;;
        xgenfstab|xchroot)    xbps-install -Sy xtools ;;
        blkid|lsblk|efibootmgr) xbps-install -Sy util-linux efibootmgr ;;
        limine)               xbps-install -Sy limine ;;
        sed|awk)              xbps-install -Sy gawk ;;
        *) warn "Unknown mapping for $cmd; attempting install"; xbps-install -Sy "$cmd" || true ;;
      esac
    fi
  done
}
ensure sgdisk partprobe mkfs.vfat bcachefs mount.bcachefs dracut xgenfstab xchroot blkid lsblk efibootmgr limine sed awk

# ===== Partition disk (GPT, UEFI) =====
say "Partitioning $DISK (ESP + bcachefs-encrypted root)"
wipefs -a "$DISK"
sgdisk --zap-all "$DISK"

# ESP: start at 2048 sector, size ESP_SIZE_MIB
sgdisk -n 1:2048:+${ESP_SIZE_MIB}MiB -t 1:EF00 -c 1:"EFI System" "$DISK"
# Root: remainder
sgdisk -n 2:0:0 -t 2:8300 -c 2:"Void root (bcachefs encrypted)" "$DISK"

partprobe "$DISK"
ESP="${DISK}1"
ROOTP="${DISK}2"

# ===== Format filesystems =====
say "Formatting ESP (FAT32) and root (bcachefs encrypted with zstd)"
mkfs.vfat -F32 -n EFI "$ESP"

# bcachefs format with native encryption + zstd
bcachefs format \
  --encrypted \
  --compression=zstd:5 \
  --metadata_checksum=crc32c \
  --label="$BCACHEFS_LABEL" \
  "$ROOTP"

# ===== Mount target =====
say "Mounting encrypted bcachefs root"
mkdir -p /mnt
# Pass passphrase to avoid interactive prompt during install
mount.bcachefs -o "fs_passphrase=${BCH_PASS}" "$ROOTP" /mnt

mkdir -p /mnt/boot/efi
mount "$ESP" /mnt/boot/efi

# ===== Bind mounts for chroot =====
say "Preparing chroot bind mounts"
mkdir -p /mnt/{proc,sys,dev}
mount --bind /proc /mnt/proc
mount --bind /sys  /mnt/sys
mount --bind /dev  /mnt/dev

# ===== Bootstrap Void base =====
say "Bootstrapping Void base system"
mkdir -p /mnt/var/db/xbps/keys
cp /var/db/xbps/keys/* /mnt/var/db/xbps/keys/ || true

export XBPS_ARCH="$ARCH"
xbps-install -S -r /mnt -R "$REPO" base-system

# Core packages
xbps-install -S -r /mnt -R "$REPO" \
  linux linux-headers linux-firmware \
  dracut bcachefs-tools limine \
  dosfstools parted xtools util-linux \
  sudo dhcpcd \
  pciutils usbutils \
  git curl wget neovim htop tmux \
  python3 python3-pip python3-virtualenv \
  zramen

# ===== fstab =====
say "Generating fstab"
xgenfstab -U /mnt > /mnt/etc/fstab

# ===== Basic config =====
say "Configuring hostname, timezone, locales"
echo "$HOSTNAME" > /mnt/etc/hostname
ln -sf "/usr/share/zoneinfo/$TIMEZONE" /mnt/etc/localtime

cat > /mnt/etc/default/libc-locales <<'EOF'
en_US.UTF-8 UTF-8
fr_FR.UTF-8 UTF-8
EOF

# ===== Dracut (bcachefs + zstd) =====
say "Configuring dracut (bcachefs, zstd compression)"
mkdir -p /mnt/etc/dracut.conf.d
cat > /mnt/etc/dracut.conf.d/bcachefs.conf <<'EOF'
add_dracutmodules+=" bcachefs "
compress="zstd"
EOF

# ===== Networking and users =====
say "Enabling dhcpcd service"
chroot /mnt ln -sf /etc/sv/dhcpcd /var/service

say "Setting passwords and users"
chroot /mnt /usr/bin/bash -c "echo 'root:${ROOT_PW}' | chpasswd"
chroot /mnt xbps-reconfigure -f glibc-locales

if [ -n "$USERNAME" ]; then
  chroot /mnt useradd -m -G wheel -s /bin/bash "$USERNAME"
  chroot /mnt /usr/bin/bash -c "echo '${USERNAME}:${USER_PW}' | chpasswd"
  chroot /mnt sed -i 's/^# %wheel/%wheel/' /etc/sudoers
fi

# ===== Build initramfs & detect kernel =====
say "Building initramfs and detecting kernel version"
chroot /mnt xbps-reconfigure -fa
KVER="$(chroot /mnt sh -c 'ls -1 /boot/vmlinuz-* | sed s@/boot/vmlinuz-@@ | sort -V | tail -n1')"
[ -n "$KVER" ] || die "Could not detect kernel version in /mnt/boot."

# ===== Copy kernel/initramfs to ESP =====
say "Copying kernel and initramfs to ESP"
mkdir -p /mnt/boot/efi/EFI/limine /mnt/boot/efi/void

# Limine BOOTX64.EFI (handle package paths)
if [ -f /mnt/usr/share/limine/BOOTX64.EFI ]; then
  cp /mnt/usr/share/limine/BOOTX64.EFI /mnt/boot/efi/EFI/limine/BOOTX64.EFI
elif [ -f /mnt/usr/share/limine/EFI/BOOT/BOOTX64.EFI ]; then
  cp /mnt/usr/share/limine/EFI/BOOT/BOOTX64.EFI /mnt/boot/efi/EFI/limine/BOOTX64.EFI
else
  die "Limine BOOTX64.EFI not found in expected paths."
fi

cp "/mnt/boot/vmlinuz-${KVER}" /mnt/boot/efi/void/vmlinuz
if [ -f "/mnt/boot/initramfs-${KVER}.img" ]; then
  cp "/mnt/boot/initramfs-${KVER}.img" /mnt/boot/efi/void/initramfs
elif [ -f "/mnt/boot/initrd" ]; then
  cp "/mnt/boot/initrd" /mnt/boot/efi/void/initramfs
else
  die "initramfs image not found in /mnt/boot."
fi

# ===== Extract bcachefs UUID for root= =====
say "Extracting bcachefs filesystem UUID"
BCH_UUID="$(bcachefs inspect-super --all "$ROOTP" | awk '/uuid:/ {print $2; exit}')"
[ -n "$BCH_UUID" ] || die "Could not extract bcachefs UUID from $ROOTP"

# ===== Write Limine configuration (limine.conf) =====
say "Writing Limine configuration (UEFI recommended path)"
cat > /mnt/boot/efi/EFI/limine/limine.conf <<EOF
timeout: 5
default_entry: 0

/ Void
comment: Void Linux (bcachefs encrypted)
protocol: linux
kernel_path: boot():/void/vmlinuz
module_path: boot():/void/initramfs
kernel_cmdline: root=UUID=${BCH_UUID} rootfstype=bcachefs rw quiet splash
EOF

# ===== Create UEFI boot entry =====
say "Creating UEFI boot entry via efibootmgr"
efibootmgr --create \
  --disk "$DISK" \
  --part 1 \
  --label "Void Linux (Limine)" \
  --loader '\EFI\limine\BOOTX64.EFI' || warn "efibootmgr failed; firmware may still pick up the fallback."

# ===== Keep ESP in sync after kernel updates =====
say "Installing kernel post-install hook to refresh ESP"
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

# ===== zram swap =====
say "Configuring zram swap"
cat > /mnt/etc/zramen.conf <<EOF
devices=1
algo=${ZRAM_ALGO}
percentage=${ZRAM_PCT}
EOF
chroot /mnt ln -sf /etc/sv/zramen /var/service

# ===== Snapshot helpers =====
say "Installing bcachefs snapshot helpers"
mkdir -p /mnt/usr/local/sbin
cat > /mnt/usr/local/sbin/bcachefs-snapshot <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
SNAP="${1:-snap-$(date +%Y%m%d-%H%M%S)}"
bcachefs subvolume snapshot / "/${SNAP}"
echo "Created snapshot: /${SNAP}"
EOF
chmod +x /mnt/usr/local/sbin/bcachefs-snapshot

cat > /mnt/usr/local/sbin/bcachefs-rollback <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ $# -lt 1 ] && { echo "Usage: bcachefs-rollback <snapshot_name>"; exit 1; }
sync
bcachefs subvolume rollback / "/$1"
echo "Rollback complete. Reboot recommended."
EOF
chmod +x /mnt/usr/local/sbin/bcachefs-rollback

# ===== Finalization =====
say "Finalizing and cleaning up"
umount /mnt/dev || true
umount /mnt/sys || true
umount /mnt/proc || true

say "Installation complete."
echo "Next steps:"
echo "  1) Reboot; Limine should show 'Void'."
echo "  2) Enter your bcachefs passphrase at boot (dracut prompt)."
echo "  3) After boot: install NVIDIA -> sudo xbps-install -S nvidia nvidia-libs nvidia-opencl"
echo "  4) Test NVIDIA: nvidia-smi; Vulkan: sudo xbps-install -S vulkan-tools && vulkaninfo"
echo "  5) Snapshots: bcachefs-snapshot pre-upgrade; rollback: bcachefs-rollback pre-upgrade"
