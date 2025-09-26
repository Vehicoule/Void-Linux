#!/usr/bin/env bash
set -euo pipefail

# ==============================
# Logging helpers
# ==============================
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

# ==============================
# Environment checks
# ==============================
check_root() {
  [[ $EUID -eq 0 ]] || { log_error "Run as root"; exit 1; }
}
check_void() {
  [[ -f /etc/os-release ]] || { log_error "Run from a Void Linux live environment"; exit 1; }
}
detect_firmware() {
  [[ -d /sys/firmware/efi ]] && FIRMWARE="UEFI" || FIRMWARE="BIOS"
}

# ==============================
# Bootstrap live dependencies
# ==============================
bootstrap_deps() {
  log_info "Bootstrapping live-environment dependencies"
  xbps-install -Sy
  local pkgs=(xtools xbps e2fsprogs xfsprogs btrfs-progs bcachefs-tools lvm2 cryptsetup parted gptfdisk dosfstools efibootmgr limine dracut util-linux pciutils curl wget git snapper)
  local to_install=()
  for p in "${pkgs[@]}"; do
    xbps-query -R "$p" >/dev/null 2>&1 || to_install+=("$p")
  done
  ((${#to_install[@]})) && xbps-install -y "${to_install[@]}"

  local required=(xchroot lsblk parted mkfs.fat mkfs.ext4 mkfs.xfs mkfs.btrfs mkfs.bcachefs efibootmgr)
  for cmd in "${required[@]}"; do
    command -v "$cmd" >/dev/null 2>&1 || { log_error "Missing command: $cmd"; exit 1; }
  done
  log_success "Dependencies ready"
}

# ==============================
# Gather user configuration
# ==============================
gather_config() {
  log_info "Interactive configuration"

  read -r -p "Hostname: " HOSTNAME; HOSTNAME=${HOSTNAME:-void-custom}
  read -r -p "Username: " USERNAME; USERNAME=${USERNAME:-voiduser}
  while true; do
    read -r -s -p "Password for $USERNAME: " USER_PASSWORD; echo
    read -r -s -p "Confirm password: " USER_PASSWORD_CONFIRM; echo
    [[ "$USER_PASSWORD" == "$USER_PASSWORD_CONFIRM" ]] && break || log_error "User passwords don't match"
  done
  while true; do
    read -r -s -p "Root password: " ROOT_PASSWORD; echo
    read -r -s -p "Confirm root password: " ROOT_PASSWORD_CONFIRM; echo
    [[ "$ROOT_PASSWORD" == "$ROOT_PASSWORD_CONFIRM" ]] && break || log_error "Root passwords don't match"
  done

  log_info "Available disks:"
  lsblk -d -o NAME,SIZE,MODEL,TYPE
  read -r -p "Target disk (e.g., sda, nvme0n1): " TARGET_DISK; TARGET_DISK=${TARGET_DISK:-sda}
  [[ -b /dev/$TARGET_DISK ]] || { log_error "Disk /dev/$TARGET_DISK not found"; exit 1; }

  log_info "Root filesystem options (snapshots supported):"
  echo "1) btrfs"
  echo "2) bcachefs"
  echo "3) ext4 (requires LVM for snapshots)"
  echo "4) xfs (requires LVM for snapshots)"
  read -r -p "Choose [1-4]: " FS_CHOICE; FS_CHOICE=${FS_CHOICE:-1}
  case "$FS_CHOICE" in
    1) ROOT_FS="btrfs" ;;
    2) ROOT_FS="bcachefs" ;;
    3) ROOT_FS="ext4" ;;
    4) ROOT_FS="xfs" ;;
    *) log_error "Invalid filesystem choice"; exit 1 ;;
  esac

  log_info "Encryption (LUKS) option:"
  echo "1) No encryption"
  echo "2) Encrypt root with LUKS2"
  read -r -p "Choose [1-2]: " ENC_CHOICE; ENC_CHOICE=${ENC_CHOICE:-2}
  if [[ "$ENC_CHOICE" == "2" ]]; then
    while true; do
      read -r -s -p "LUKS passphrase: " ENCRYPTION_PASSPHRASE; echo
      read -r -s -p "Confirm passphrase: " ENCRYPTION_PASSPHRASE_CONFIRM; echo
      [[ "$ENCRYPTION_PASSPHRASE" == "$ENCRYPTION_PASSPHRASE_CONFIRM" ]] && break || log_error "Passphrases don't match"
    done
  fi

  log_info "LVM option:"
  echo "1) Do not use LVM"
  echo "2) Use LVM (recommended with LUKS; required for ext4/xfs snapshots)"
  read -r -p "Choose [1-2]: " LVM_CHOICE; LVM_CHOICE=${LVM_CHOICE:-2}
  if [[ "$ROOT_FS" =~ ^(ext4|xfs)$ ]] && [[ "$LVM_CHOICE" != "2" ]]; then
    log_warning "ext4/xfs require LVM for snapshots. Enabling LVM."
    LVM_CHOICE="2"
  fi

  log_info "Swap option:"
  echo "1) No swap"
  echo "2) Swap LV (if LVM) or swapfile (if not using LVM)"
  read -r -p "Choose [1-2]: " SWAP_CHOICE; SWAP_CHOICE=${SWAP_CHOICE:-2}

  log_info "Zswap option:"
  echo "1) Disable zswap"
  echo "2) Enable zswap (zstd, 20% pool)"
  read -r -p "Choose [1-2]: " ZSWAP_CHOICE; ZSWAP_CHOICE=${ZSWAP_CHOICE:-2}

  read -r -p "Timezone (e.g., Europe/Paris): " TIMEZONE; TIMEZONE=${TIMEZONE:-Europe/Paris}
  [[ -f "/usr/share/zoneinfo/$TIMEZONE" ]] || { log_error "Invalid timezone '$TIMEZONE'."; exit 1; }

  read -r -p "Locale (e.g., en_US.UTF-8): " LOCALE; LOCALE=${LOCALE:-en_US.UTF-8}
  read -r -p "Keymap (e.g., fr): " KEYMAP; KEYMAP=${KEYMAP:-fr}

  log_info "GPU configuration:"
  echo "1) NVIDIA only"
  echo "2) Hybrid (NVIDIA + Intel)"
  echo "3) None/Other"
  read -r -p "Select [1-3]: " GPU_CHOICE; GPU_CHOICE=${GPU_CHOICE:-1}

  log_info "Kernel selection:"
  echo "1) Mainline only"
  echo "2) Current only"
  echo "3) Both"
  read -r -p "Select [1-3]: " KERNEL_CHOICE; KERNEL_CHOICE=${KERNEL_CHOICE:-3}

  detect_firmware
  log_info "Firmware: $FIRMWARE"
  echo "Disk: /dev/$TARGET_DISK | FS: $ROOT_FS | LUKS: $([[ "$ENC_CHOICE" == "2" ]] && echo yes || echo no) | LVM: $([[ "$LVM_CHOICE" == "2" ]] && echo yes || echo no)"
  echo "Swap: $([[ "$SWAP_CHOICE" == "2" ]] && echo enabled || echo disabled) | Zswap: $([[ "$ZSWAP_CHOICE" == "2" ]] && echo enabled || echo disabled)"
  echo "Timezone: $TIMEZONE | Locale: $LOCALE | Keymap: $KEYMAP"
  echo "GPU: $GPU_CHOICE | Kernels: $KERNEL_CHOICE"

  read -r -p "Type YES to proceed (this destroys data on /dev/$TARGET_DISK): " CONFIRM
  [[ "$CONFIRM" == "YES" ]] || { log_info "Cancelled"; exit 0; }

  if [[ "$TARGET_DISK" == nvme* || "$TARGET_DISK" == mmcblk* ]]; then
    P1_SUFFIX="p1"; P2_SUFFIX="p2"
  else
    P1_SUFFIX="1"; P2_SUFFIX="2"
  fi
}

# ==============================
# Partitioning and formatting
# ==============================
setup_partitions() {
  local DISK="/dev/$TARGET_DISK"
  umount -R /mnt 2>/dev/null || true; swapoff -a 2>/dev/null || true

  log_info "Creating GPT on $DISK"
  parted -s "$DISK" mklabel gpt

  if [[ "$FIRMWARE" == "UEFI" ]]; then
    log_info "Creating ESP FAT32 (1 GiB) at /boot"
    parted -s "$DISK" mkpart ESP fat32 1MiB 1025MiB
    parted -s "$DISK" set 1 esp on
    ESP="${DISK}${P1_SUFFIX}"; BOOT="$ESP"
    log_info "Creating root partition (remaining space)"
    parted -s "$DISK" mkpart primary 1025MiB 100%
    ROOT="${DISK}${P2_SUFFIX}"
  else
    log_info "Creating BIOS boot partition (bios_grub, 1 MiB)"
    parted -s "$DISK" mkpart primary 1MiB 2MiB
    parted -s "$DISK" set 1 bios_grub on
    BIOS_GRUB="${DISK}${P1_SUFFIX}"
    log_info "Creating FAT32 /boot (1 GiB)"
    parted -s "$DISK" mkpart primary fat32 2MiB 1026MiB
    BOOT="${DISK}${P2_SUFFIX}"
    log_info "Creating root partition (remaining space)"
    local p3_suffix
    if [[ "$P2_SUFFIX" =~ ^p?([0-9]+)$ ]]; then
      local n="${BASH_REMATCH[1]}"; p3_suffix="${P2_SUFFIX/$n/$((n+1))}"
    else
      p3_suffix="3"
    fi
    parted -s "$DISK" mkpart primary 1026MiB 100%
    ROOT="${DISK}${p3_suffix}"
  fi

  partprobe "$DISK"; sleep 2

  log_info "Formatting /boot (FAT32)"
  mkfs.fat -F32 "$BOOT"

  if [[ "$ENC_CHOICE" == "2" ]]; then
    log_info "Configuring LUKS2 on root"
    echo -n "$ENCRYPTION_PASSPHRASE" | cryptsetup luksFormat --type luks2 -s 512 -h sha512 "$ROOT" -
    echo -n "$ENCRYPTION_PASSPHRASE" | cryptsetup open "$ROOT" cryptroot -
    ROOT_MAPPER="/dev/mapper/cryptroot"
  else
    ROOT_MAPPER="$ROOT"
  fi

  if [[ "$LVM_CHOICE" == "2" ]]; then
    log_info "Setting up LVM on ${ROOT_MAPPER}"
    pvcreate "$ROOT_MAPPER"
    vgcreate voidvg "$ROOT_MAPPER"
    # Root 100G, optional 8G swap, home rest
    [[ "$SWAP_CHOICE" == "2" ]] && lvcreate -L 8G -n swap voidvg || true
    lvcreate -L 100G -n root voidvg
    lvcreate -l 100%FREE -n home voidvg
    ROOT_DEV="/dev/voidvg/root"; HOME_DEV="/dev/voidvg/home"; SWAP_DEV="/dev/voidvg/swap"
  else
    ROOT_DEV="$ROOT_MAPPER"; HOME_DEV=""; SWAP_DEV=""
  fi

  case "$ROOT_FS" in
    btrfs)
      log_info "Formatting root as btrfs and creating @/@home"
      mkfs.btrfs -f "$ROOT_DEV"
      mount "$ROOT_DEV" /mnt
      btrfs subvolume create /mnt/@
      btrfs subvolume create /mnt/@home
      umount /mnt
      ;;
    bcachefs)
      log_info "Formatting root as bcachefs"
      mkfs.bcachefs -f "$ROOT_DEV"
      ;;
    ext4)
      mkfs.ext4 -F "$ROOT_DEV"
      ;;
    xfs)
      mkfs.xfs -f "$ROOT_DEV"
      ;;
  esac

  if [[ -n "$HOME_DEV" && "$ROOT_FS" != "btrfs" && "$ROOT_FS" != "bcachefs" ]]; then
    case "$ROOT_FS" in
      ext4) mkfs.ext4 -F "$HOME_DEV" ;;
      xfs)  mkfs.xfs  -f "$HOME_DEV" ;;
    esac
  fi

  [[ "$LVM_CHOICE" == "2" && "$SWAP_CHOICE" == "2" ]] && mkswap "$SWAP_DEV" || true

  log_info "Mounting filesystems"
  case "$ROOT_FS" in
    btrfs)
      mount -o subvol=@ "$ROOT_DEV" /mnt
      mkdir -p /mnt/boot /mnt/home
      mount "$BOOT" /mnt/boot
      mount -o subvol=@home "$ROOT_DEV" /mnt/home
      ;;
    *)
      mount "$ROOT_DEV" /mnt
      mkdir -p /mnt/boot
      mount "$BOOT" /mnt/boot
      if [[ -n "$HOME_DEV" && "$ROOT_FS" != "bcachefs" ]]; then
        mkdir -p /mnt/home; mount "$HOME_DEV" /mnt/home
      fi
      ;;
  esac
  [[ "$LVM_CHOICE" == "2" && "$SWAP_CHOICE" == "2" ]] && swapon "$SWAP_DEV" || true

  for d in proc sys dev; do
    mount --rbind "/$d" "/mnt/$d"; mount --make-rslave "/mnt/$d"
  done

  log_success "Partitioning and mounting complete"
}

# ==============================
# Install base system
# ==============================
install_base() {
  log_info "Installing base system"
  xbps-install -S -y -R https://repo-default.voidlinux.org/current -r /mnt base-system
  case "$ROOT_FS" in
    btrfs)    xbps-install -y -r /mnt btrfs-progs snapper ;;
    bcachefs) xbps-install -y -r /mnt bcachefs-tools ;;
    xfs)      xbps-install -y -r /mnt xfsprogs ;;
    ext4)     xbps-install -y -r /mnt e2fsprogs ;;
  esac
  log_success "Base system installed"
}

# ==============================
# System configuration (chroot)
# ==============================
configure_system() {
  log_info "Configuring system in chroot"

  xchroot /mnt /bin/bash <<EOF
set -euo pipefail

# Update and repos (your preferred sequence)
xbps-install -Syu
xbps-install -u xbps
xbps-install -Syu void-repo-nonfree void-repo-multilib void-repo-multilib-nonfree
xbps-install -Syu xtools opendoas sudo zsh git curl wget NetworkManager dbus dracut intel-ucode
xbps-install -Syu

# Kernel(s)
case "${KERNEL_CHOICE}" in
  1) xbps-install -y linux-mainline linux-mainline-headers ;;
  2) xbps-install -y linux linux-headers ;;
  3) xbps-install -y linux linux-headers linux-mainline linux-mainline-headers ;;
esac
xbps-install -y linux-firmware

# NVIDIA if selected
if [ "${GPU_CHOICE}" = "1" ] || [ "${GPU_CHOICE}" = "2" ]; then
  xbps-install -y nvidia nvidia-tools nvidia-dkms
fi

# Timezone, locale, keymap, hostname
ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
hwclock --systohc

echo "${LOCALE} UTF-8" >> /etc/default/libc-locales
xbps-reconfigure -f glibc-locales
echo "LANG=${LOCALE}" > /etc/locale.conf

echo "KEYMAP=${KEYMAP}" > /etc/vconsole.conf
echo "${HOSTNAME}" > /etc/hostname

cat > /etc/hosts <<EOT
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${HOSTNAME}.localdomain ${HOSTNAME}
EOT

# doas
echo "permit :wheel" > /etc/doas.conf
chmod 0400 /etc/doas.conf

# User
useradd -m -G wheel,users,network,audio,video -s /bin/zsh "${USERNAME}"
echo "${USERNAME}:${USER_PASSWORD}" | chpasswd
echo "root:${ROOT_PASSWORD}" | chpasswd

# Enable services (runit)
mkdir -p /var/service
ln -sf /etc/sv/dbus /var/service/
ln -sf /etc/sv/NetworkManager /var/service/
ln -sf /etc/sv/sshd /var/service/

EOF

  log_success "System configuration done"
}

# ==============================
# Kernel cmdline builder
# ==============================
build_cmdline() {
  local root_id; root_id=$(blkid -s UUID -o value "$ROOT_DEV")
  KERNEL_CMDLINE="root=UUID=$root_id rw quiet"
  [[ "$ROOT_FS" == "btrfs" ]] && KERNEL_CMDLINE="$KERNEL_CMDLINE rootflags=subvol=@"
  if [[ "$ENC_CHOICE" == "2" ]]; then
    local luks_id; luks_id=$(blkid -s UUID -o value "$ROOT")
    KERNEL_CMDLINE="$KERNEL_CMDLINE rd.luks.uuid=$luks_id"
  fi
  [[ "$LVM_CHOICE" == "2" ]] && KERNEL_CMDLINE="$KERNEL_CMDLINE rd.lvm.vg=voidvg"
  if [[ "$ZSWAP_CHOICE" == "2" ]]; then
    KERNEL_CMDLINE="$KERNEL_CMDLINE zswap.enabled=1 zswap.compressor=zstd zswap.zpool=zsmalloc zswap.max_pool_percent=20"
  fi
}

# ==============================
# Limine bootloader with snapshots
# ==============================
install_limine() {
  log_info "Installing Limine"
  xbps-install -y -r /mnt limine

  # Create limine.conf with entries for current kernels and btrfs snapshots
  cat > /mnt/boot/limine.conf <<EOF
timeout: 5
verbose: yes

# Entries will be appended below
EOF

  # Append entries for kernels present
  xchroot /mnt /bin/bash <<EOF
set -euo pipefail
ROOT_UUID="$(blkid -s UUID -o value "${ROOT_DEV}")"

for kern in /boot/vmlinuz*; do
  [ -e "\$kern" ] || continue
  base=\$(basename "\$kern")
  initrd=\$(ls /boot/initramfs* | grep "\${base#vmlinuz-}" | head -n1 || true)

  cat >> /boot/limine.conf <<EOT
/ Void Linux (\$base)
protocol: linux
path: boot():/\$base
EOT

  if [ -n "\$initrd" ]; then
    echo "module_path: boot():/\$initrd" >> /boot/limine.conf
  fi

  echo "cmdline: root=UUID=\$ROOT_UUID rw ${ROOT_FS == "btrfs" ? "rootflags=subvol=@" : ""} ${KERNEL_CMDLINE#*quiet}" >> /boot/limine.conf
done

# Snapshot entries for btrfs subvols
if [ -d /.snapshots ] && btrfs subvolume list / >/dev/null 2>&1; then
  for snap in \$(find /.snapshots -maxdepth 2 -type d -name snapshot | sort -r); do
    subvol=\${snap#/}      # strip leading /
    name=\$(basename \$(dirname "\$snap"))
    for kern in /boot/vmlinuz*; do
      base=\$(basename "\$kern")
      initrd=\$(ls /boot/initramfs* | grep "\${base#vmlinuz-}" | head -n1 || true)

      cat >> /boot/limine.conf <<EOT
/ Snapshot \$name (\$base)
protocol: linux
path: boot():/\$base
EOT

      if [ -n "\$initrd" ]; then
        echo "module_path: boot():/\$initrd" >> /boot/limine.conf
      fi
      echo "cmdline: root=UUID=\$ROOT_UUID rw rootflags=subvol=\$subvol ${KERNEL_CMDLINE#*quiet}" >> /boot/limine.conf
    done
  done
fi
EOF

  # UEFI: copy EFI binary and run limine-install on the ESP
  if [[ "$FIRMWARE" == "UEFI" ]]; then
    mkdir -p /mnt/boot/EFI/BOOT 
    mkdir -p /mnt/boot/EFI/limine
    cp /mnt/usr/share/limine/BOOTX64.EFI /mnt/boot/EFI/BOOT/BOOTX64.EFI
    cp /mnt/boot/limine.conf /mnt/boot/EFI/limine/
    xchroot /mnt limine-install /boot
    # Try to add NVRAM entry (optional)
    local disk="/dev/$TARGET_DISK"
    local partnum
    if [[ "$BOOT" =~ ${TARGET_DISK}p([0-9]+)$ ]]; then
      partnum="${BASH_REMATCH[1]}"
    elif [[ "$BOOT" =~ ${TARGET_DISK}([0-9]+)$ ]]; then
      partnum="${BASH_REMATCH[1]}"
    else
      partnum="1"
    fi
    efibootmgr --create --disk "$disk" --part "$partnum" --label "Void (Limine)" --loader '\EFI\BOOT\BOOTX64.EFI' || true
  else
    # BIOS: ensure limine-bios.sys present and install to disk MBR
    cp /mnt/usr/share/limine/limine-bios.sys /mnt/boot/
    xchroot /mnt limine-install "/dev/$TARGET_DISK"
  fi

  log_success "Limine installed with snapshot entries"
}

# ==============================
# Snapshot tooling configuration
# ==============================
configure_snapshots() {
  log_info "Configuring snapshot tooling"

  if [[ "$ROOT_FS" == "btrfs" ]]; then
    xchroot /mnt /bin/bash <<'EOF'
set -e
xbps-install -y snapper
snapper -c root create-config /
snapper -c home create-config /home || true
sed -i 's/TIMELINE_CREATE="no"/TIMELINE_CREATE="yes"/' /etc/snapper/configs/root || true
sed -i 's/TIMELINE_LIMIT_DAILY="0"/TIMELINE_LIMIT_DAILY="7"/' /etc/snapper/configs/root || true
sed -i 's/TIMELINE_LIMIT_WEEKLY="0"/TIMELINE_LIMIT_WEEKLY="4"/' /etc/snapper/configs/root || true
sed -i 's/TIMELINE_LIMIT_MONTHLY="0"/TIMELINE_LIMIT_MONTHLY="12"/' /etc/snapper/configs/root || true
ln -sf /etc/sv/crond /var/service/ || true
EOF
  elif [[ "$ROOT_FS" == "bcachefs" ]]; then
    xchroot /mnt /bin/bash <<'EOF'
set -e
mkdir -p /etc/cron.daily
cat > /etc/cron.daily/bcachefs-snapshots <<'S'
#!/bin/bash
set -e
SNAP="/.snapshots/daily"
mkdir -p "$SNAP"
if command -v bcachefs >/dev/null 2>&1; then
  bcachefs subvolume snapshot / "$SNAP/$(date +%Y%m%d-%H%M)" || true
  ls -dt "$SNAP"/* 2>/dev/null | tail -n +8 | xargs rm -rf 2>/dev/null || true
fi
S
chmod +x /etc/cron.daily/bcachefs-snapshots
ln -sf /etc/sv/crond /var/service/ || true
EOF
  else
    if [[ "$LVM_CHOICE" == "2" ]]; then
      xchroot /mnt /bin/bash <<'EOF'
set -e
mkdir -p /etc/cron.daily
cat > /etc/cron.daily/lvm-root-snapshot <<'S'
#!/bin/bash
set -e
VG="voidvg"; LV="root"; SNAP_SIZE="10G"; KEEP=7
DATE=$(date +%Y%m%d-%H%M)
lvcreate -s -n "${LV}-snap-${DATE}" -L "$SNAP_SIZE" "${VG}/${LV}" || exit 0
lvs --noheadings -o lv_name,vg_name | awk '$2=="voidvg" && $1 ~ /^root-snap-/ {print $1}' \
  | sort | head -n -${KEEP} | xargs -r -I{} lvremove -f "voidvg/{}"
S
chmod +x /etc/cron.daily/lvm-root-snapshot
ln -sf /etc/sv/crond /var/service/ || true
EOF
    fi
  fi

  log_success "Snapshot tooling configured"
}

# ==============================
# Swapfile creation (if needed)
# ==============================
setup_swapfile_if_needed() {
  # If no LVM but swap was requested, create a swapfile (not for bcachefs)
  if [[ "$LVM_CHOICE" != "2" && "$SWAP_CHOICE" == "2" && "$ROOT_FS" != "bcachefs" ]]; then
    log_info "Creating 8G swapfile on root"
    xchroot /mnt /bin/bash <<'EOF'
set -e
fallocate -l 8G /swapfile
chmod 600 /swapfile
mkswap /swapfile
echo "/swapfile none swap defaults 0 0" >> /etc/fstab
EOF
  fi
}

# ==============================
# Finalize
# ==============================
finalize() {
  log_info "Finalizing"
  # Generate fstab
  local fstab="/mnt/etc/fstab"; : > "$fstab"
  local ROOT_UUID BOOT_UUID HOME_UUID SWAP_UUID
  ROOT_UUID=$(blkid -s UUID -o value "$ROOT_DEV")
  BOOT_UUID=$(blkid -s UUID -o value "$BOOT")
  [[ -n "$HOME_DEV" && "$ROOT_FS" != "btrfs" && "$ROOT_FS" != "bcachefs" ]] && HOME_UUID=$(blkid -s UUID -o value "$HOME_DEV") || HOME_UUID=""
  if [[ "$LVM_CHOICE" == "2" && "$SWAP_CHOICE" == "2" ]]; then SWAP_UUID=$(blkid -s UUID -o value "$SWAP_DEV"); else SWAP_UUID=""; fi

  case "$ROOT_FS" in
    ext4)    echo "UUID=$ROOT_UUID / ext4 rw,relatime 0 1" >> "$fstab" ;;
    xfs)     echo "UUID=$ROOT_UUID / xfs rw,relatime 0 1" >> "$fstab" ;;
    btrfs)   echo "UUID=$ROOT_UUID / btrfs rw,relatime,subvol=@ 0 0" >> "$fstab" ;;
    bcachefs)echo "UUID=$ROOT_UUID / bcachefs rw 0 1" >> "$fstab" ;;
  esac
  echo "UUID=$BOOT_UUID /boot vfat rw,relatime,umask=0077 0 2" >> "$fstab"
  if [[ "$ROOT_FS" == "btrfs" ]]; then
    echo "UUID=$ROOT_UUID /home btrfs rw,relatime,subvol=@home 0 0" >> "$fstab"
  elif [[ -n "$HOME_UUID" ]]; then
    echo "UUID=$HOME_UUID /home $ROOT_FS rw,relatime 0 2" >> "$fstab"
  fi
  [[ -n "$SWAP_UUID" ]] && echo "UUID=$SWAP_UUID none swap defaults 0 0" >> "$fstab"

  # Reconfigure initramfs
  xchroot /mnt /bin/bash -c 'xbps-reconfigure -fa' || true

  # Unmount and deactivate
  umount /mnt/boot 2>/dev/null || true
  [[ -d /mnt/home ]] && umount /mnt/home 2>/dev/null || true
  umount /mnt 2>/dev/null || true
  [[ "$ENC_CHOICE" == "2" ]] && cryptsetup close cryptroot 2>/dev/null || true
  [[ "$LVM_CHOICE" == "2" ]] && vgchange -an voidvg 2>/dev/null || true
  swapoff -a 2>/dev/null || true

  log_success "Installation complete"
  log_info "Next steps:"
  log_info "1. Reboot"
  log_info "2. Ensure firmware boots from the target disk"
  log_info "3. Login as $USERNAME (password you set)"
  [[ "$ENC_CHOICE" == "2" ]] && log_info "4. Enter LUKS passphrase at boot" || true
}

# ==============================
# Main
# ==============================
main() {
  check_root
  check_void
  bootstrap_deps
  gather_config
  setup_partitions
  install_base
  configure_system
  build_cmdline
  install_limine
  configure_snapshots
  setup_swapfile_if_needed
  finalize
}
trap 'log_error "Script failed at line $LINENO"; exit 1' ERR
main "$@"
