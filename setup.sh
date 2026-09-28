#!/usr/bin/env bash
#
# setup.sh — Install & configure MPD + Tailscale for remote music streaming
# Targets Arch-based distros (Arch, CachyOS, EndeavourOS, Manjaro).
# Runs MPD as a *user* service so it can read music in your home directory.

set -euo pipefail

RED=$'\e[31m'; GRN=$'\e[32m'; YLW=$'\e[33m'; BLU=$'\e[34m'; RST=$'\e[0m'
info()  { echo "${BLU}==>${RST} $*"; }
ok()    { echo "${GRN} ✓${RST} $*"; }
warn()  { echo "${YLW} !${RST} $*"; }
die()   { echo "${RED} ✗${RST} $*" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MPD_CONFIG_DIR="$HOME/.config/mpd"
MPD_DATA_DIR="$HOME/.local/share/mpd"

[[ $EUID -eq 0 ]] && die "Run as your normal user, not root. (sudo is used internally when needed)"
command -v pacman >/dev/null || die "pacman not found — this script targets Arch-based distros."

# ---------------------------------------------------------------- config file
ENV_FILE="$SCRIPT_DIR/.env"
if [[ -f "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    info "Loaded settings from .env"
fi

MUSIC_DIR="${MUSIC_DIR:-$HOME/Music}"
MPD_PASSWORD="${MPD_PASSWORD:-}"
TAILSCALE_AUTHKEY="${TAILSCALE_AUTHKEY:-}"

if [[ ! -d "$MUSIC_DIR" ]]; then
    read -rp "Music directory not found at '$MUSIC_DIR'. Enter path to your music: " MUSIC_DIR
    MUSIC_DIR="${MUSIC_DIR/#\~/$HOME}"
    [[ -d "$MUSIC_DIR" ]] || die "Directory '$MUSIC_DIR' does not exist."
fi
info "Music directory: $MUSIC_DIR"

if [[ -z "$MPD_PASSWORD" ]]; then
    MPD_PASSWORD="$(head -c 24 /dev/urandom | base64 | tr -d '/+=' | head -c 20)"
    warn "Generated random MPD password: $MPD_PASSWORD  (saved in $MPD_CONFIG_DIR/mpd.conf)"
fi

# -------------------------------------------------------------- install pkgs
info "Installing packages (mpd, mpc, tailscale)..."
sudo pacman -S --needed --noconfirm mpd mpc tailscale
ok "Packages installed"

# --------------------------------------------------------------- tailscaled
info "Enabling tailscaled..."
sudo systemctl enable --now tailscaled

if ! tailscale status >/dev/null 2>&1; then
    info "Bringing Tailscale up — a login URL will appear, open it in a browser."
    if [[ -n "$TAILSCALE_AUTHKEY" ]]; then
        sudo tailscale up --authkey="$TAILSCALE_AUTHKEY" --accept-dns=true
    else
        sudo tailscale up --accept-dns=true
    fi
fi

TS_IP="$(tailscale ip -4 | head -n1)"
[[ -n "$TS_IP" ]] || die "Could not determine Tailscale IPv4 address."
TS_HOSTNAME="$(tailscale status --json | grep -oP '"DNSName":\s*"\K[^"]+' | sed 's/\.$//' || true)"
ok "Tailscale up — IP: $TS_IP  Hostname: ${TS_HOSTNAME:-unknown}"

# ----------------------------------------------------------------- mpd conf
info "Writing MPD config to $MPD_CONFIG_DIR/mpd.conf"
mkdir -p "$MPD_CONFIG_DIR" "$MPD_DATA_DIR/playlists"

sed -e "s|__MUSIC_DIR__|$MUSIC_DIR|g" \
    -e "s|__TS_IP__|$TS_IP|g" \
    -e "s|__PASSWORD__|$MPD_PASSWORD|g" \
    "$SCRIPT_DIR/mpd.conf" > "$MPD_CONFIG_DIR/mpd.conf"
chmod 600 "$MPD_CONFIG_DIR/mpd.conf"   # contains the password
ok "Config written"

# ------------------------------------------------------------- user service
info "Enabling MPD user service..."
systemctl --user daemon-reload
systemctl --user enable --now mpd.service
ok "MPD running (user service)"

# Keep user services alive without an active login session (headless servers)
if loginctl show-user "$USER" -p Linger 2>/dev/null | grep -q "Linger=no"; then
    warn "Enabling lingering so MPD runs without an active login session"
    sudo loginctl enable-linger "$USER"
fi

# ------------------------------------------------------------------ summary
echo
echo "${GRN}======================================================${RST}"
echo " Setup complete!"
echo
echo " Control (port 6600):"
echo "   Host:     $TS_IP   (or ${TS_HOSTNAME:-<hostname>.ts.net})"
echo "   Password: $MPD_PASSWORD"
echo
echo " Stream URL (for 'stream playback' in your client):"
echo "   http://${TS_HOSTNAME:-$TS_IP}:8000"
echo
echo " Phone setup:"
echo "   1. Install the Tailscale app and sign into the same tailnet"
echo "   2. Android: M.A.L.P. / MPDroid  •  iOS: MaximumMPD / Rigelian"
echo "   3. Add a connection with the host + password above"
echo "   4. Enable streaming output ('Phone Stream') to hear audio"
echo
echo " Useful commands:"
echo "   systemctl --user status mpd     # check MPD"
echo "   mpc update                      # rescan library"
echo "   tailscale status                # check tailnet"
echo "${GRN}======================================================${RST}"

# Initial DB scan (may take a while on first run)
info "Starting initial library scan in the background..."
(sleep 2 && mpc --host="$TS_IP" --password="$MPD_PASSWORD" update >/dev/null 2>&1 || mpc update >/dev/null 2>&1) &
disown
