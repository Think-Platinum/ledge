# Cleaning up macOS Local Network privacy duplicates

Apple does not provide a supported way to reset the "Local Network" list in
System Settings → Privacy & Security. The state lives in four SIP-protected
plists that can only be deleted from Recovery Mode. This doc walks you through
it.

There's a script that does it interactively — `bin/recovery-lnp-cleanup.sh` in
this repo. The procedure below covers both the scripted path and the manual
fallback (in case Terminal in Recovery can't find the script for some reason).

## Before you reboot — read this on another device

Recovery Mode is a stripped-down environment with limited tools. **Open this
doc on your iPhone or print it before continuing.** You won't have your
browser or normal notes app while in Recovery.

Quick links to put on your phone:

- This file (read on phone): open the GitHub web view of `ledge/docs/recovery-lnp-cleanup.md`
- Apple DTS confirmation that there's no other way: <https://developer.apple.com/forums/thread/766270>

## What gets deleted

Four plists in `/Library/Preferences`:

- `com.apple.networkextension.plist` — registered Network Extensions
- `com.apple.networkextension.uuidcache.plist` — the UUID cache that's accumulating duplicates
- `com.apple.networkextension.control.plist` — control state
- `com.apple.networkextension.necp.plist` — Network Extension Control Policy rules

The script backs each up to `*.bak-<timestamp>` next to the original before
deleting, so you can restore if something goes wrong.

## Side effects

VPN / Network Extension apps lose their config registration:

- **Tailscale, WireGuard, Mullvad, NordVPN etc.** — open the app, click through
  the "approve system extension" prompt once, you're back in business.
- **Little Snitch / Lulu / etc. (network filters)** — same: re-approve the
  system extension on next launch.
- **Corporate / MDM-pushed VPN profiles** — you may need IT to re-push.

Wi-Fi networks, saved passwords, DNS settings, firewall rules — all untouched.
This only resets the Network Extension framework's registration store.

## Procedure

### 1. Reboot to Recovery Mode

**Apple Silicon (your M5 Max):**

1. Apple menu → Shut Down.
2. Press and hold the Power button until "Loading startup options…" appears.
3. Click **Options** → **Continue**.
4. Pick your admin user, enter password.

### 2. Mount the Data volume

Recovery defaults to read-only access to the system. Your writable home and
preferences live on the Data volume, which you must mount manually.

1. From the Recovery menu bar, choose **Utilities → Disk Utility**.
2. In the sidebar, find your internal disk (usually "APPLE SSD …"). Expand it.
3. Click the volume named **Macintosh HD - Data** (or just **Data**).
4. Click **Mount** in the toolbar. Enter your password if prompted.
5. Note the mounted path — Disk Utility shows it under the volume name, usually
   `/Volumes/Macintosh HD - Data`.
6. Quit Disk Utility.

### 3. Open Terminal

**Utilities → Terminal** from the menu bar.

### 4a. Run the script (preferred)

```sh
bash "/Volumes/Macintosh HD - Data/Users/john/Dev/Ledge/ledge/bin/recovery-lnp-cleanup.sh"
```

If your Data volume is mounted under a different name, replace the path.
The script will:

1. Auto-detect the Data volume (or accept it as an argument).
2. List which of the four plists exist, with sizes and modification times.
3. Ask you to confirm.
4. Back up each file with a `.bak-<timestamp>` suffix.
5. Delete the originals.
6. Print next-step instructions.

Skip to step 5 below.

### 4b. Manual fallback (if the script isn't reachable)

If for some reason you can't find or run the script, type these by hand. Replace
`Macintosh HD - Data` with whatever your Data volume is actually named.

```sh
# Confirm you're looking at the right place — should list .plist files.
ls -la "/Volumes/Macintosh HD - Data/Library/Preferences/com.apple.networkextension."*

# Back them up first (paranoia is cheap).
stamp=$(date +%Y%m%d-%H%M%S)
cd "/Volumes/Macintosh HD - Data/Library/Preferences"
for f in com.apple.networkextension.plist \
         com.apple.networkextension.uuidcache.plist \
         com.apple.networkextension.control.plist \
         com.apple.networkextension.necp.plist; do
    [ -f "$f" ] && cp "$f" "$f.bak-$stamp" && echo "backed up $f"
done

# Delete the originals.
for f in com.apple.networkextension.plist \
         com.apple.networkextension.uuidcache.plist \
         com.apple.networkextension.control.plist \
         com.apple.networkextension.necp.plist; do
    [ -f "$f" ] && rm "$f" && echo "deleted $f"
done
```

### 5. Reboot normally

Apple menu → **Restart**. Don't hold any keys this time — just a normal boot.

### 6. Verify

1. After login, open **System Settings → Privacy & Security → Local Network**.
2. The list should be empty.
3. Launch Ledge. The first time it tries to find something on the LAN, macOS
   will prompt you for Local Network access. Click **Allow**. **One** new row
   will appear in the panel.
4. With the LC_UUID-pinning step in `bin/ship`, every subsequent ship will
   reuse that one row instead of adding more.
5. Re-approve any VPN / network filter system extensions if their apps
   complain.

### 7. Clean up the backups

After a day or two of confirming everything works, you can delete the
backup files. This can be done from a normal boot:

```sh
sudo rm "/Library/Preferences/com.apple.networkextension."*.bak-*
```

## If things go wrong

- **Boot fails after reboot, or kernel panic.** Boot back to Recovery, mount the
  Data volume, restore one or more backups:
  ```sh
  cd "/Volumes/Macintosh HD - Data/Library/Preferences"
  # Find the most recent backup of, say, the necp file:
  ls -t com.apple.networkextension.necp.plist.bak-* | head -1
  # Restore it:
  cp com.apple.networkextension.necp.plist.bak-<timestamp> com.apple.networkextension.necp.plist
  ```
- **VPN/filter apps don't reconnect.** Open the app, follow the system
  extension approval prompt. If no prompt appears, look in System Settings →
  Login Items & Extensions → Network Extensions and toggle the relevant
  extension off and on.
- **The Local Network list comes back populated immediately.** That means apps
  are being launched too quickly post-boot and immediately requesting LAN
  access. Expected — the goal is one row per app, not zero rows forever.

## Why this is necessary

Apple manages most privacy permissions through TCC (`tccutil` resets them).
Local Network is one of two outliers (the other is Location); it lives in the
Network Extension framework instead, with no developer-facing reset tool. Quinn
"The Eskimo!" at Apple DTS has confirmed this on the developer forums multiple
times — the open Apple radar is `r. 134842755`.

The `bin/ship` script handles the *cause* (LC_UUID pinning so future builds
reuse one row), but it can't retroactively merge the rows that already exist.
That's what this Recovery procedure is for.
