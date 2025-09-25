#!/bin/bash

# Check if running as root
if [ "$(id -u)" != "0" ]; then
   echo "This script must be run as root" 1>&2
   exit 1
fi

# Identify the SSD device (change this if necessary)
SSD_DEVICE="/dev/sda"

# Function to handle errors
handle_error() {
    echo "Error: $1" 1>&2
    exit 1
}

# Ask about encryption
read -p "Do you want to use encryption? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    ENCRYPT=true
else
    ENCRYPT=false
fi

# Partition the SSD
echo "Partitioning ${SSD_DEVICE}..."
if ! sgdisk -Z ${SSD_DEVICE}; then
    handle_error "Failed to zap partitions on ${SSD_DEVICE}"
fi
if ! sgdisk -a 2048 -o ${SSD_DEVICE}; then
    handle_error "Failed to create new GPT disk on ${SSD_DEVICE}"
fi

# Create EFI System Partition (ESP)
if ! sgdisk -n 1:0:+512M -t 1:ef00 ${SSD_DEVICE}; then
    handle_error "Failed to create ESP on ${SSD_DEVICE}"
fi

# Create root partition
if ! sgdisk -n 2:0:0 -t 2:8300 ${SSD_DEVICE}; then
    handle_error "Failed to create root partition on ${SSD_DEVICE}"
fi

# Format the partitions
echo "Formatting partitions..."
if ! mkfs.fat -F32 ${SSD_DEVICE}1; then
    handle_error "Failed to format ESP"
fi

if [ "$ENCRYPT" = true ]; then
    # Format the root partition with bcachefs and enable encryption
    echo "Formatting root partition with bcachefs and encryption..."
    if ! mkfs.bcachefs --encrypt ${SSD_DEVICE}2; then
        handle_error "Failed to format root partition with encryption"
    fi
else
    # Format the root partition with bcachefs without encryption
    echo "Formatting root partition with bcachefs..."
    if ! mkfs.bcachefs ${SSD_DEVICE}2; then
        handle_error "Failed to format root partition"
    fi
fi

# Mount the partitions
echo "Mounting partitions..."
if ! mount ${SSD_DEVICE}2 /mnt; then
    handle_error "Failed to mount root partition"
fi
if ! mkdir -p /mnt/boot/efi; then
    handle_error "Failed to create /mnt/boot/efi directory"
fi
if ! mount ${SSD_DEVICE}1 /mnt/boot/efi; then
    handle_error "Failed to mount ESP"
fi

# Install the base system
echo "Installing base system..."
if ! xbps-install -r /mnt base-system; then
    handle_error "Failed to install base-system"
fi

# Set up the chroot environment
echo "Setting up chroot environment..."
if ! mkdir -p /mnt/dev; then
    handle_error "Failed to create /mnt/dev directory"
fi
if ! mkdir -p /mnt/proc; then
    handle_error "Failed to create /mnt/proc directory"
fi
if ! mkdir -p /mnt/sys; then
    handle_error "Failed to create /mnt/sys directory"
fi

if ! mount -t devtmpfs dev /mnt/dev; then
    handle_error "Failed to mount devtmpfs on /mnt/dev"
fi
if ! mount -t proc proc /mnt/proc; then
    handle_error "Failed to mount proc on /mnt/proc"
fi
if ! mount -t sysfs sys /mnt/sys; then
    handle_error "Failed to mount sysfs on /mnt/sys"
fi

# Copy the resolver configuration
if ! cp /etc/resolv.conf /mnt/etc/resolv.conf; then
    handle_error "Failed to copy resolv.conf"
fi

# Configure basic system settings within the chroot environment
echo "Configuring basic system settings..."
if ! chroot /mnt /bin/bash <<EOF; then
    handle_error "Failed to chroot into /mnt"
EOF
# Set timezone (example: Europe/Paris)
ln -sf /usr/share/zoneinfo/Europe/Paris /etc/localtime
echo "Europe/Paris" > /etc/timezone

# Set hostname (replace with desired hostname)
echo "voidlinux" > /etc/hostname

# Configure network (example: DHCP)
echo "auto_lo=lo" > /etc/dhcpcd.conf
echo "noipv4ll" >> /etc/dhcpcd.conf
EOF

# Set root password and create user account within the chroot environment
echo "Setting root password..."
if ! chroot /mnt /bin/bash -c "passwd"; then
    handle_error "Failed to set root password"
fi

read -p "Enter username: " USERNAME
echo "Creating user account $USERNAME..."
if ! chroot /mnt /bin/bash -c "useradd -m -G wheel -s /bin/bash $USERNAME"; then
    handle_error "Failed to create user account"
fi
if ! chroot /mnt /bin/bash -c "passwd $USERNAME"; then
    handle_error "Failed to set password for $USERNAME"
fi

# Install and configure additional packages within the chroot environment
echo "Installing and configuring additional packages..."
if ! chroot /mnt /bin/bash <<EOF; then
    handle_error "Failed to chroot into /mnt"
EOF
# Install Limine bootloader
if ! xbps-install -S limine; then
    handle_error "Failed to install limine"
fi
if ! limine-install /dev/sda; then
    handle_error "Failed to install Limine bootloader"
fi

# Set up zram swap
echo "Setting up zram swap..."
if ! modprobe zram; then
    handle_error "Failed to load zram module"
fi
echo "zram" >> /etc/modules
echo "KERNEL=\"\\[ \\\\\$kernel \\\\\\]\"" > /etc/mkinitfs.conf.d/zram.conf
echo "MODULES=\"zram\"" >> /etc/mkinitfs.conf.d/zram.conf
echo "zram" >> /etc/mkinitfs.conf.d/zram.conf

# Install additional packages (example: NVIDIA drivers, AI tools, gaming tools)
echo "Installing packages for AI and gaming..."
if ! xbps-install -S python3 python3-pip jupyter tensorflow pytorch steam wine; then
    echo "Failed to install some AI and gaming packages" 1>&2
fi

# Install bcachefs tools if not already installed
if ! xbps-install -S bcachefs; then
    handle_error "Failed to install bcachefs tools"
fi

# Set up bcachefs snapshots and rollback
echo "Setting up bcachefs snapshots and rollback..."
# Create a snapshot directory
if ! mkdir -p /snapshots; then
    handle_error "Failed to create snapshots directory"
fi

# Create a snapshot of the root filesystem
if ! bcachefs subvolume snapshot / /snapshots/initial; then
    handle_error "Failed to create initial snapshot"
fi
EOF

# Unmount the chroot environment
echo "Unmounting chroot environment..."
if ! umount /mnt/dev; then
    handle_error "Failed to unmount /mnt/dev"
fi
if ! umount /mnt/proc; then
    handle_error "Failed to unmount /mnt/proc"
fi
if ! umount /mnt/sys; then
    handle_error "Failed to unmount /mnt/sys"
fi

echo "Installation complete!"
