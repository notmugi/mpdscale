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
MUSIC_DIR_SET=""
if [[ -f "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    [[ -n "${MUSIC_DIR:-}" ]] && MUSIC_DIR_SET=1
    info "Loaded settings from .env"
fi

MUSIC_DIR="${MUSIC_DIR:-$HOME/Music}"
TAILSCALE_AUTHKEY="${TAILSCALE_AUTHKEY:-}"

if [[ ! -d "$MUSIC_DIR" ]]; then
    read -rp "Music directory not found at '$MUSIC_DIR'. Enter path to your music: " MUSIC_DIR
    MUSIC_DIR="${MUSIC_DIR/#\~/$HOME}"
    [[ -d "$MUSIC_DIR" ]] || die "Directory '$MUSIC_DIR' does not exist."
fi
info "Music directory: $MUSIC_DIR"

# No password — tailnet is already authenticated + encrypted.

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

# If firewalld is running, trust the tailnet interface so phone traffic
# isn't dropped (default zone blocks inbound 6600/8000).
if systemctl is-active --quiet firewalld; then
    if ! sudo firewall-cmd --permanent --zone=trusted --query-interface=tailscale0 2>/dev/null; then
        info "firewalld detected — adding tailscale0 to the trusted zone"
        sudo firewall-cmd --permanent --zone=trusted --add-interface=tailscale0
        sudo firewall-cmd --reload
        ok "tailscale0 trusted in firewalld"
    fi
fi

TS_IP="$(tailscale ip -4 | head -n1)"
[[ -n "$TS_IP" ]] || die "Could not determine Tailscale IPv4 address."
TS_HOSTNAME="$(tailscale status --json | grep -oP '"DNSName":\s*"\K[^"]+' | sed 's/\.$//' || true)"
ok "Tailscale up — IP: $TS_IP  Hostname: ${TS_HOSTNAME:-unknown}"

# ------------------------------------------------- existing install detect
EXISTING_CONF=""
for candidate in "$MPD_CONFIG_DIR/mpd.conf" /etc/mpd.conf; do
    [[ -f "$candidate" ]] && EXISTING_CONF="$candidate" && break
done

if [[ -n "$EXISTING_CONF" && -z "$MUSIC_DIR_SET" && "${MUSIC_DIR}" == "$HOME/Music" ]]; then
    # Adopt the music dir from the existing config
    detected="$(grep -m1 -oP '^\s*music_directory\s+"\K[^"]+' "$EXISTING_CONF" || true)"
    detected="${detected/#\~/$HOME}"
    if [[ -n "$detected" && -d "$detected" ]]; then
        MUSIC_DIR="$detected"
        info "Adopted music directory from existing config: $MUSIC_DIR"
    fi
fi

# Is an MPD already running? (user service, system service, or manual)
MPD_WAS_RUNNING=""
if systemctl --user is-active --quiet mpd.service 2>/dev/null; then
    MPD_WAS_RUNNING="user"
elif systemctl is-active --quiet mpd.service 2>/dev/null; then
    MPD_WAS_RUNNING="system"
    warn "A SYSTEM mpd.service is running."
    warn "This script sets up a USER service. The system one will conflict (port 6600)."
    read -rp "Stop & disable the system mpd.service and switch to the user service? [Y/n] " yn
    if [[ "${yn:-Y}" =~ ^[Yy]?$ ]]; then
        sudo systemctl disable --now mpd.service
        ok "System mpd.service disabled"
    else
        die "Cannot continue while system mpd.service holds port 6600."
    fi
elif pgrep -x mpd >/dev/null 2>&1; then
    MPD_WAS_RUNNING="manual"
    warn "An MPD process is already running outside systemd — it will conflict on port 6600."
    read -rp "Kill it and let the user service take over? [Y/n] " yn
    if [[ "${yn:-Y}" =~ ^[Yy]?$ ]]; then
        pkill -x mpd || true
        sleep 1
    else
        die "Cannot continue while another MPD process holds port 6600."
    fi
fi

# Back up an existing user config instead of clobbering it
if [[ -f "$MPD_CONFIG_DIR/mpd.conf" ]]; then
    backup="$MPD_CONFIG_DIR/mpd.conf.bak.$(date +%Y%m%d-%H%M%S)"
    cp -a "$MPD_CONFIG_DIR/mpd.conf" "$backup"
    warn "Existing config backed up to: $backup"
fi

# ----------------------------------------------------------------- mpd conf
info "Writing MPD config to $MPD_CONFIG_DIR/mpd.conf"
mkdir -p "$MPD_CONFIG_DIR" "$MPD_DATA_DIR/playlists"

sed -e "s|__MUSIC_DIR__|$MUSIC_DIR|g" \
    "$SCRIPT_DIR/mpd.conf" > "$MPD_CONFIG_DIR/mpd.conf"
ok "Config written"
warn "ncmpcpp note: your existing client connects to localhost — that still works."
warn "If ncmpcpp needs the DB/playlists, they now live in $MPD_DATA_DIR (was possibly elsewhere)."

# ------------------------------------------------------------- user service
info "Enabling MPD user service..."
systemctl --user daemon-reload
systemctl --user enable --now mpd.socket mpd.service
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
echo "   Password: (none)"
echo
echo " Stream URL (for 'stream playback' in your client):"
echo "   http://${TS_HOSTNAME:-$TS_IP}:8000"
echo
echo " Phone setup:"
echo "   1. Install the Tailscale app and sign into the same tailnet"
echo "   2. Android: M.A.L.P. / MPDroid  •  iOS: MaximumMPD / Rigelian"
echo "   3. Add a connection with the host above (no password)"
echo "   4. Enable streaming output ('Phone Stream') to hear audio"
echo
echo " Useful commands:"
echo "   systemctl --user status mpd     # check MPD"
echo "   mpc update                      # rescan library"
echo "   tailscale status                # check tailnet"
echo "${GRN}======================================================${RST}"

# Initial DB scan (may take a while on first run)
info "Starting initial library scan in the background..."
(sleep 2 && mpc update >/dev/null 2>&1) &
disown
