#!/bin/sh
# List manually installed packages (base programs, no deps, no versions)

xbps-query -m | awk '{print $1}' | rev | cut -d- -f2- | rev > my-packages.txt

echo "Saved package list to my-packages.txt"

