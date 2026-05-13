#!/bin/bash
#
# recovery-lnp-cleanup.sh — wipe macOS Local Network privacy state.
#
# Run this from macOS Recovery's Terminal AFTER mounting the Data volume
# in Disk Utility. It removes the four plists that back the "Local
# Network" rows in System Settings → Privacy & Security, plus the
# nehelper UUID cache. On next normal boot the list is empty and each
# app re-prompts the next time it tries to discover something on the LAN.
#
# Side effect: VPN / Network Extension configs are also wiped (VLAN
# filters, WireGuard profiles, Tailscale's Network Extension, etc.).
# These apps will prompt you to re-add their system extension on first
# launch — usually one click each.
#
# Why Recovery: the files are SIP-protected and cannot be deleted from
# a running macOS. Recovery has SIP relaxed enough to write to the
# mounted Data volume.
#
# Author note: this script is read-only of your code repo (it lives in
# the repo only because that's where you'll have it staged when you
# need it). It does NOT touch anything in your home directory.

set -u
# Intentionally not -e: we want to report partial failures, not abort.

# ---------------------------------------------------------------------------
# Find the Data volume
# ---------------------------------------------------------------------------
#
# In Recovery, your normal macOS Data volume mounts under /Volumes/ with
# whatever name you gave it (commonly "Macintosh HD - Data" or just
# "Data"). Rather than hard-code, we look for the marker files.

PREF_REL="Library/Preferences"
MARKER="com.apple.networkextension.plist"

CANDIDATES=()
if [[ -d /Volumes ]]; then
    for vol in /Volumes/*; do
        if [[ -f "$vol/$PREF_REL/$MARKER" ]]; then
            CANDIDATES+=("$vol")
        fi
    done
fi

# Also handle the case where the script is being run on a regular
# (non-Recovery) boot — refuse, because the writes will silently fail.
if [[ -f "/$PREF_REL/$MARKER" && ${#CANDIDATES[@]} -eq 0 ]]; then
    cat >&2 <<EOF
error: you appear to be running this on a NORMAL boot, not Recovery.
       The file /$PREF_REL/$MARKER exists at the root path, which means
       SIP is active and the deletes below would fail with
       "Operation not permitted".

       Reboot into Recovery (hold Power on Apple Silicon → Options →
       Continue), mount the Data volume in Disk Utility, open Terminal,
       and run this script again from there.
EOF
    exit 2
fi

case ${#CANDIDATES[@]} in
    0)
        cat >&2 <<EOF
error: could not find a mounted Data volume containing
       $PREF_REL/$MARKER under /Volumes.

Did you mount the Data volume in Disk Utility first?
  Disk Utility → select the Data volume in the sidebar → click Mount.

If you have a non-standard volume layout, pass the path explicitly:
  $0 /Volumes/YourVolume
EOF
        exit 1
        ;;
    1)
        DATA_VOL="${CANDIDATES[0]}"
        ;;
    *)
        # More than one match — could happen if you have multiple
        # macOS installs (Time Machine, dual-boot, external). Let the
        # user pick.
        echo "Multiple candidate Data volumes found:"
        for i in "${!CANDIDATES[@]}"; do
            echo "  $((i+1))) ${CANDIDATES[$i]}"
        done
        echo
        read -rp "Pick one [1-${#CANDIDATES[@]}], or q to quit: " choice
        if [[ "$choice" == "q" ]]; then exit 0; fi
        idx=$((choice - 1))
        if [[ $idx -lt 0 || $idx -ge ${#CANDIDATES[@]} ]]; then
            echo "error: invalid choice" >&2
            exit 1
        fi
        DATA_VOL="${CANDIDATES[$idx]}"
        ;;
esac

# Allow an explicit override on the command line.
if [[ $# -ge 1 ]]; then
    if [[ ! -d "$1" ]]; then
        echo "error: $1 is not a directory" >&2
        exit 1
    fi
    DATA_VOL="$1"
fi

PREF_DIR="$DATA_VOL/$PREF_REL"
echo "Using Data volume: $DATA_VOL"
echo "Preferences dir:  $PREF_DIR"
echo

# ---------------------------------------------------------------------------
# Enumerate target files
# ---------------------------------------------------------------------------

# All four files in the family. uuidcache is the one that's actually
# accumulating duplicate rows; the others store filter configs etc. but
# Apple's docs lump them together for a reset.
TARGETS=(
    "com.apple.networkextension.plist"
    "com.apple.networkextension.uuidcache.plist"
    "com.apple.networkextension.control.plist"
    "com.apple.networkextension.necp.plist"
)

echo "Files to remove:"
FOUND=()
for name in "${TARGETS[@]}"; do
    path="$PREF_DIR/$name"
    if [[ -f "$path" ]]; then
        size=$(stat -f%z "$path" 2>/dev/null || echo "?")
        mtime=$(stat -f%Sm -t%Y-%m-%dT%H:%M:%S "$path" 2>/dev/null || echo "?")
        echo "  $name  ($size bytes, modified $mtime)"
        FOUND+=("$path")
    else
        echo "  $name  (not present — already clean)"
    fi
done
echo

if [[ ${#FOUND[@]} -eq 0 ]]; then
    echo "Nothing to do — the Local Network state is already empty."
    exit 0
fi

# ---------------------------------------------------------------------------
# Confirm + back up + delete
# ---------------------------------------------------------------------------

echo "These files will be backed up next to themselves with a .bak-<timestamp>"
echo "suffix, then deleted. Backups are kept so you can restore if something"
echo "goes wrong (e.g. VPN config you needed was in there)."
echo
read -rp "Proceed? [y/N] " confirm
if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    echo "Aborted."
    exit 0
fi

stamp=$(date +%Y%m%d-%H%M%S)
echo
echo "Backing up + deleting…"
fail=0
for path in "${FOUND[@]}"; do
    bak="$path.bak-$stamp"
    if cp "$path" "$bak" 2>/dev/null; then
        echo "  ✓ backed up $(basename "$path") → $(basename "$bak")"
    else
        echo "  ✗ could NOT back up $path — aborting before deletion" >&2
        echo "    (likely SIP is still active; are you sure you're in Recovery?)" >&2
        fail=1
        break
    fi
    if rm "$path" 2>/dev/null; then
        echo "  ✓ deleted   $(basename "$path")"
    else
        echo "  ✗ could NOT delete $path" >&2
        fail=1
    fi
done

echo
if [[ $fail -ne 0 ]]; then
    echo "FAILED — see errors above. Backups (if any) remain at *.bak-$stamp." >&2
    exit 1
fi

cat <<EOF
DONE.

Backups remain at:
  $PREF_DIR/*.bak-$stamp

Next steps:
  1. Quit Terminal.
  2. From the Apple menu, choose Restart.
  3. After boot, open System Settings → Privacy & Security → Local Network.
     The list should be empty.
  4. Launch the apps you actually use (Ledge, Chrome, etc.). Each will
     prompt once for Local Network access — approve, and one fresh row
     appears per app.
  5. If VPN apps complain about missing Network Extensions, open them
     and approve the system extension prompt.
  6. After you've confirmed everything works, delete the backups:
       sudo rm $PREF_DIR/*.bak-$stamp
     (You can do this from a normal boot — backups aren't SIP-protected.)
EOF
