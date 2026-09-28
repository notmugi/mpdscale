# mpd-tailscale

Stream and control your music from anywhere. MPD runs natively on your home
machine; Tailscale gives your phone a private, encrypted tunnel to it — no
port forwarding, no dynamic DNS, nothing exposed to the public internet.

Targets Arch-based distros (Arch, CachyOS, EndeavourOS, Manjaro). No Docker.

## How it works

```
[ Phone ] --- Tailscale (WireGuard) ---> [ Home machine ]
  M.A.L.P. / MaximumMPD                    MPD (user service)
      |                                      ├─ :6600 control (password-protected, tailnet+localhost only)
      └--- HTTP audio stream --------------- └─ :8000 mp3 stream
```

MPD binds its control port only to localhost and your Tailscale IP, so it's
not reachable from your LAN or the internet — only devices on your tailnet.

## Quick start

```bash
git clone <this-repo> && cd mpd-tailscale
cp .env.example .env   # optional — edit MUSIC_DIR etc.
./setup.sh
```

The script will:
1. Install `mpd`, `mpc`, `tailscale` via pacman
2. Start `tailscaled` and bring your node up (browser login, or auth key)
3. Write `~/.config/mpd/mpd.conf` (music dir, tailnet IP, password, HTTP stream output)
4. Enable MPD as a **user service** + enable lingering (runs headless, can read files in your home dir)
5. Kick off the initial library scan

## Phone setup

1. Install the **Tailscale** app, sign into the same tailnet.
2. Install an MPD client:
   - **Android:** [M.A.L.P.](https://play.google.com/store/apps/details?id=org.gateshipone.malp) (best), MPDroid
   - **iOS:** MaximumMPD, Rigelian, MPDluxe
3. Add a connection:
   - **Host:** the Tailscale IP or MagicDNS hostname printed by setup (e.g. `homeserver.tail1234.ts.net`)
   - **Port:** `6600`
   - **Password:** printed by setup / stored in `~/.config/mpd/mpd.conf`
4. Enable the **"Phone Stream"** HTTP output (clients expose output toggles) to
   hear audio on the phone. Some clients let you set the stream URL directly:
   `http://<hostname>.ts.net:8000`

## Files

| File | Purpose |
|---|---|
| `setup.sh` | One-shot installer/configurer |
| `mpd.conf` | MPD config template (placeholders substituted at install) |
| `.env.example` | Optional pre-seeded settings |
| `uninstall.sh` | Remove MPD service + config |

## Config notes

- MPD runs as **your user**, not the `mpd` system user — no permission
  gymnastics for music in your home directory.
- The HTTP stream is 192kbps MP3 (`lame` encoder). Edit
  `~/.config/mpd/mpd.conf` to change bitrate/encoder, then
  `systemctl --user restart mpd`.
- `always_on = yes` keeps the stream alive between tracks.
- If your Tailscale IP ever changes (rare), re-run `./setup.sh` — it rewrites
  the config with the current IP. MagicDNS hostname is stable, so prefer that
  in your phone client.

## Useful commands

```bash
systemctl --user status mpd     # service status
journalctl --user -u mpd -f     # logs
mpc update                      # rescan library
mpc --host <ts-ip> --password <pw> stats
tailscale status                # tailnet peers
```

## Security

- Control port is bound to localhost + tailnet IP only.
- Password required for all client commands.
- All traffic between phone and server is WireGuard-encrypted via Tailscale.
- Port 8000 (HTTP stream) binds on all interfaces — it's only audio out, but
  if you want to restrict it to the tailnet too, change `bind_to_address` in
  the httpd output block to your Tailscale IP.

## Troubleshooting

- **No audio on phone:** make sure the "Phone Stream" output is enabled
  (`mpc outputs` / client output toggle) and volume > 0.
- **Client can't connect:** check `tailscale status` on both devices;
  verify `ss -tlnp | grep 6600` shows the tailnet IP.
- **Empty library:** run `mpc update` and check `~/.config/mpd/mpd.conf`'s
  `music_directory`.
- **MPD dies on logout:** `sudo loginctl enable-linger $USER`
