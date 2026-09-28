# mpdscale

Listen to your home music library from your phone, anywhere.

## Setup (home machine)

```bash
git clone https://github.com/notmugi/mpdscale
cd mpdscale
./setup.sh
```

It installs everything and prints your connection info at the end. Open the Tailscale link it gives you in a browser to log in.

## Setup (phone)

1. Install the **Tailscale** app, log in with the same account
2. Install an MPD app: **MPD Pilot** (iOS) or **M.A.L.P.** (Android)
3. Add a server with the host and port from setup (port `6600`, no password)
4. In the app, add the stream URL so you can hear audio:
   - `http://<host>:8001` — cellular
   - `http://<host>:8000` — wifi

Press play. That's it.

## Commands

```bash
./setup.sh            # start everything (run this after a reboot)
./setup.sh --stop     # stop playback + phone access (MPD keeps running locally)
./setup.sh --restart  # stop, then start again
mpc update            # rescan library
./setup.sh --phone    # audio to phone only
./setup.sh --local    # audio to this machine only
./setup.sh --auto     # decide from whether Tailscale is up
```

Nothing starts on its own after a reboot — run `./setup.sh` when you want it.
