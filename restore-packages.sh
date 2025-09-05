#!/bin/sh
# Restore packages on Void (simple version)

set -e

# Install xtools and enable all repos
sudo xbps-install -Sy xtools void-repo-nonfree void-repo-multilib void-repo-multilib-nonfree

# Update and sync
sudo xbps-install -Syu

# Install everything from your list
sudo xbps-install -y $(cat my-packages.txt)

echo "[✔] Done!"

