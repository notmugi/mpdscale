#!/usr/bin/env bash
# uninstall.sh — stop services and remove MPD config (keeps Tailscale installed)
set -euo pipefail

echo "==> Stopping and disabling MPD user service..."
systemctl --user disable --now mpd.service 2>/dev/null || true

echo "==> Removing MPD config and data..."
rm -rf "$HOME/.config/mpd" "$HOME/.local/share/mpd" "$HOME/.local/share/mpdscale" "$HOME/.config/systemd/user/mpd.service.d"

read -rp "Also remove packages (mpd, mpc)? [y/N] " yn
if [[ "$yn" =~ ^[Yy]$ ]]; then
    sudo pacman -Rns --noconfirm mpd mpc
fi

echo "Note: Tailscale was left installed/running. To remove:"
echo "  sudo tailscale logout && sudo systemctl disable --now tailscaled && sudo pacman -Rns tailscale"
echo "Done."
