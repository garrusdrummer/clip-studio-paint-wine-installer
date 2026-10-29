#!/usr/bin/env bash
# uninstall.sh - remove the Clip Studio Paint install created by install.sh.
# Usage: ./uninstall.sh [--purge]   (--purge also deletes the download cache)
set -euo pipefail

BASE=${CSP_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/csp5}
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/csp5-installer"
DATA="${XDG_DATA_HOME:-$HOME/.local/share}"

echo "This deletes $BASE: the Wine runner, the prefix and everything inside it"
echo "(CSP settings, downloaded materials, and any files saved inside the prefix's C: drive)."
echo "Files saved to Windows' Documents folder are kept: it is a link to your home folder, not a copy."
read -rp "Continue? [y/N] " answer
[[ $answer == [yY]* ]] || exit 1

[[ -x $BASE/wine/bin/wineserver ]] && WINEPREFIX="$BASE/prefix" "$BASE/wine/bin/wineserver" -k 2>/dev/null || true
rm -rf -- "$BASE"
rm -f -- "$HOME/.local/bin/clip-studio-paint" \
         "$DATA/applications/clip-studio-paint.desktop" \
         "$DATA/icons/hicolor/256x256/apps/clip-studio-paint.png"
[[ ${1:-} == --purge ]] && rm -rf -- "$CACHE"
command -v update-desktop-database >/dev/null && update-desktop-database "$DATA/applications" >/dev/null 2>&1 || true
echo "Removed."
