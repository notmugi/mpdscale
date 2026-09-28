#!/usr/bin/env bash
# mpdscale-outputs.sh — switch MPD audio outputs
#   mpdscale-outputs.sh phone   -> streams on, local speakers off
#   mpdscale-outputs.sh local   -> local speakers on, streams off
#   mpdscale-outputs.sh auto    -> phone if tailscaled is up, else local
set -euo pipefail

MODE="${1:-auto}"
if [[ "$MODE" == "auto" ]]; then
    if systemctl is-active --quiet tailscaled; then
        MODE="phone"
    else
        MODE="local"
    fi
fi

if [[ "$MODE" == "phone" ]]; then
    ENABLE="Phone Stream Phone Stream (Cellular)"
    DISABLE="Local Playback"
else
    ENABLE="Local Playback"
    DISABLE="Phone Stream Phone Stream (Cellular)"
fi

# MPD may need a moment to open its control port after startup
for _ in 1 2 3 4 5; do
    mpc outputs >/dev/null 2>&1 && break
    sleep 1
done

while read -r line; do
    id="$(grep -oP 'Output \K[0-9]+' <<< "$line")"
    name="$(sed -E 's/Output [0-9]+ \((.*)\) is .*/\1/' <<< "$line")"
    [[ -z "${id}" || -z "${name}" ]] && continue
    if [[ " ${ENABLE} " == *" ${name} "* ]]; then
        mpc enable "$id" >/dev/null 2>&1 || true
    elif [[ " ${DISABLE} " == *" ${name} "* ]]; then
        mpc disable "$id" >/dev/null 2>&1 || true
    fi
done <<< "$(mpc outputs 2>/dev/null)"

if [[ "$MODE" == "phone" ]]; then
    # MPD quirk: a re-enabled httpd output listens but refuses connections
    # until playback restarts. Probe the stream; if dead, nudge playback
    # for a second to force the outputs open, then restore the prior state.
    if ! curl -s -m 3 -o /dev/null http://127.0.0.1:8000/; then
        state="$(mpc status | sed -n '2p')"
        mpc play >/dev/null 2>&1 || true
        sleep 1.5
        case "$state" in
            *paused*)  mpc pause >/dev/null 2>&1 || true ;;
            *stopped*|"") mpc stop >/dev/null 2>&1 || true ;;
        esac
    fi
fi
