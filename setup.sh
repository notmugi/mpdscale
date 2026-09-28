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

# ------------------------------------------------------------------- flags
# ./setup.sh            same as --start: full setup + everything running
# ./setup.sh --start    "
# ./setup.sh --stop     stop playback + remote access (MPD stays up for ncmpcpp)
# ./setup.sh --restart  stop, then start again
HELPER="$HOME/.local/share/mpdscale/mpdscale-outputs.sh"

usage() {
    cat <<EOF
Usage: ./setup.sh [flag]

  (none)      Same as --start
  --start     Full setup: install packages, bring Tailscale up, start MPD,
              route audio to phone
  --stop      Stop playback, disconnect phone (Tailscale down), route audio
              to this machine. MPD keeps running for ncmpcpp.
  --restart   --stop followed by --start
  --phone     Route audio to phone only
  --local     Route audio to this machine only
  --auto      Route audio based on whether Tailscale is up
  --help      Show this message
EOF
}

ACTION="start"
case "${1:---start}" in
    --start)   ACTION="start" ;;
    --stop)    ACTION="stop" ;;
    --restart) ACTION="restart" ;;
    --help|-h) usage; exit 0 ;;
    --phone|--local|--auto)
        [[ -x "$HELPER" ]] || die "Not installed yet — run ./setup.sh once first."
        "$HELPER" "${1#--}"
        exit 0
        ;;
    *) die "Unknown flag '$1'. Use --start, --stop, --restart, --phone, --local, or --auto." ;;
esac

do_stop() {
    info "Stopping playback..."
    mpc stop >/dev/null 2>&1 || true
    info "Switching audio to local machine only..."
    "$HELPER" local 2>/dev/null || true
    info "Stopping Tailscale (remote access off; MPD keeps running locally for ncmpcpp)..."
    sudo systemctl stop tailscaled 2>/dev/null || true
    ok "Stopped — phone disconnected, audio plays on this machine"
}

if [[ "$ACTION" == "stop" ]]; then
    do_stop
    exit 0
elif [[ "$ACTION" == "restart" ]]; then
    do_stop
    info "Starting again..."
    # fall through to the normal start flow below
fi

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
info "Starting MPD user service (NOT enabled — opt-in, won't auto-start at login)..."
systemctl --user daemon-reload
systemctl --user start mpd.socket
if systemctl --user is-active --quiet mpd.service; then
    # Already running with the OLD config — restart so the new one applies
    systemctl --user restart mpd.service
fi
ok "MPD running (user service, socket-activated; start with: systemctl --user start mpd.socket)"

# Linger is NOT enabled: MPD runs only while you're logged in.
# For a headless always-on server, run: sudo loginctl enable-linger "$USER"

# ------------------------------------------------- output mode automation
# Install the output-switch helper and a systemd hook so MPD always starts
# in the right mode: phone outputs if tailscaled is up, local otherwise.
info "Installing output-mode automation..."
mkdir -p "$HOME/.local/share/mpdscale" "$HOME/.config/systemd/user/mpd.service.d"
install -m 755 "$SCRIPT_DIR/mpdscale-outputs.sh" "$HELPER"
cat > "$HOME/.config/systemd/user/mpd.service.d/outputs.conf" <<EOF
[Service]
ExecStartPost=$HELPER auto
EOF
systemctl --user daemon-reload
ok "MPD will default to local audio unless remote access is up"

# Audio goes to the phone only while remote access is up
info "Switching audio to phone streams only (local speakers off)..."
"$HELPER" phone
ok "Outputs: streams on, local off"

# ------------------------------------------------------------------ summary
echo
echo "${GRN}======================================================${RST}"
echo " Setup complete!"
echo
echo " Control (port 6600):"
echo "   Host:     $TS_IP   (or ${TS_HOSTNAME:-<hostname>.ts.net})"
echo "   Password: (none)"
echo
echo " Stream URLs (for 'local playback' in your client):"
echo "   http://${TS_HOSTNAME:-$TS_IP}:8000  (MP3 192k — wifi)"
echo "   http://${TS_HOSTNAME:-$TS_IP}:8001  (Opus 96k — cellular)"
echo
echo " Phone setup:"
echo "   1. Install the Tailscale app and sign into the same tailnet"
echo "   2. Android: M.A.L.P.  •  iOS: MPD Pilot (both free, control + listen)"
echo "   3. Add a connection with the host above (no password)"
echo "   4. Point its 'local playback/stream URL' at a stream:"
echo "      http://${TS_HOSTNAME:-$TS_IP}:8001  (Opus 96k — cellular/low data)"
echo "      http://${TS_HOSTNAME:-$TS_IP}:8000  (MP3 192k — wifi)"
echo
echo " Useful commands:"
echo "   systemctl --user start mpd.socket   # start MPD (does not auto-start)
   systemctl --user stop mpd.socket mpd.service  # stop MPD
   systemctl --user status mpd     # check MPD"
echo "   mpc update                      # rescan library"
echo "   tailscale status                # check tailnet"
echo "${GRN}======================================================${RST}"

# Initial DB scan (may take a while on first run)
info "Starting initial library scan in the background..."
(sleep 2 && mpc update >/dev/null 2>&1) &
disown
