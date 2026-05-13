#!/usr/bin/env python3
"""
pin-lc-uuid.py — overwrite LC_UUID in a Mach-O with a deterministic value.

macOS Local Network privacy keeps a per-LC_UUID cache (nehelper's
"UUID cache", backing the rows in System Settings -> Privacy & Security
-> Local Network). Apple's linker emits a content-hashed UUID by
default, so every dev build of the same app gets a fresh UUID and a
fresh row in that panel. Over time the list fills with ghosts.

Pinning LC_UUID to a UUIDv5 derived from the bundle ID means every
build of the same app — regardless of how the source changed — produces
the same UUID, so the cache hits and the panel keeps one row.

This is unsupported by Apple (radar 134842755 acknowledges the problem
but no first-class fix exists). It works today because the cache is
keyed on the bytes of LC_UUID, not on a hash of the binary. If a
future macOS changes that, this script becomes a no-op rather than
actively harmful.

The binary's code signature is invalidated by this rewrite (LC_UUID is
part of what codesign hashes), so the caller MUST re-codesign after
running this script. `bin/ship` does that.

Usage:
  pin-lc-uuid.py <mach-o-path> <bundle-id> [--namespace UUID] [-v]

Exit codes:
  0  one or more LC_UUID load commands rewritten
  1  parse error or no LC_UUID found (binary linked with -no_uuid)
  2  bad arguments (handled by argparse)
"""

import argparse
import struct
import sys
import uuid

# Stable, arbitrary namespace UUID for this tool. The whole point is
# determinism, so don't change it casually — every binary that has been
# pinned with the previous namespace would suddenly get a different UUID
# and re-prompt for Local Network access.
DEFAULT_NAMESPACE = "a1f1d8a4-1d6e-5b87-9c5d-1f9e1f8d1e7a"

# Mach-O magic numbers
FAT_MAGIC    = 0xCAFEBABE   # 32-bit fat (big-endian on disk)
FAT_MAGIC_64 = 0xCAFEBABF   # 64-bit fat (big-endian on disk)
MH_MAGIC     = 0xFEEDFACE   # 32-bit thin, host-endian
MH_MAGIC_64  = 0xFEEDFACF   # 64-bit thin, host-endian
MH_CIGAM     = 0xCEFAEDFE   # 32-bit thin, byte-swapped
MH_CIGAM_64  = 0xCFFAEDFE   # 64-bit thin, byte-swapped
LC_UUID      = 0x1B


def parse_args():
    p = argparse.ArgumentParser(
        description="Pin LC_UUID in a Mach-O to a deterministic value.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="See the file header comment for the why.",
    )
    p.add_argument("binary", help="path to the Mach-O (thin or fat)")
    p.add_argument("bundle_id", help="app bundle identifier; the UUID is UUIDv5(namespace, bundle_id)")
    p.add_argument("--namespace", default=DEFAULT_NAMESPACE,
                   help="UUIDv5 namespace (default: built-in)")
    p.add_argument("-v", "--verbose", action="store_true")
    return p.parse_args()


def find_lc_uuid_offsets(buf, slice_offset):
    """
    Walk the load commands in the Mach-O slice that starts at
    `slice_offset`, returning byte offsets in `buf` where each
    LC_UUID's 16-byte payload lives.
    """
    # The slice's first 4 bytes are the magic. We read it little-endian
    # then check both byte orders; the CIGAM variants indicate the
    # slice's fields are big-endian and we should swap.
    magic = struct.unpack_from("<I", buf, slice_offset)[0]

    if magic in (MH_MAGIC_64, MH_CIGAM_64):
        is_64 = True
    elif magic in (MH_MAGIC, MH_CIGAM):
        is_64 = False
    else:
        raise ValueError(f"slice@{slice_offset}: unknown Mach-O magic 0x{magic:08x}")

    endian = ">" if magic in (MH_CIGAM, MH_CIGAM_64) else "<"

    # mach_header(_64) layout from the slice's start:
    #   magic(4) cputype(4) cpusubtype(4) filetype(4) ncmds(4) sizeofcmds(4) flags(4)
    #   [reserved(4) only on 64-bit]
    # → ncmds lives at offset 16 from the slice start.
    ncmds = struct.unpack_from(endian + "I", buf, slice_offset + 16)[0]

    # Load commands begin immediately after the header.
    lc_cursor = slice_offset + (32 if is_64 else 28)

    offsets = []
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from(endian + "II", buf, lc_cursor)
        if cmd == LC_UUID:
            # uuid_command: cmd(4) cmdsize(4) uuid(16) = 24 bytes total.
            # The 16-byte UUID payload starts 8 bytes after the cursor.
            offsets.append(lc_cursor + 8)
        lc_cursor += cmdsize
    return offsets


def slice_offsets_of(buf):
    """
    Return a list of byte offsets at which Mach-O slices start.
    For a thin binary that's [0]; for a fat binary it's the contained
    slice offsets parsed out of the fat header (always big-endian).
    """
    first = struct.unpack_from(">I", buf, 0)[0]

    if first not in (FAT_MAGIC, FAT_MAGIC_64):
        return [0]

    is_fat_64 = (first == FAT_MAGIC_64)
    nfat = struct.unpack_from(">I", buf, 4)[0]
    # fat_arch    (32-bit): cputype(4) cpusubtype(4) offset(4) size(4) align(4) = 20
    # fat_arch_64        : cputype(4) cpusubtype(4) offset(8) size(8) align(4) reserved(4) = 32
    arch_size = 32 if is_fat_64 else 20

    slice_offsets = []
    for i in range(nfat):
        # offset field sits past cputype + cpusubtype (8 bytes into the arch entry).
        off_field = 8 + i * arch_size + 8
        if is_fat_64:
            slice_offsets.append(struct.unpack_from(">Q", buf, off_field)[0])
        else:
            slice_offsets.append(struct.unpack_from(">I", buf, off_field)[0])
    return slice_offsets


def main():
    args = parse_args()

    pinned = uuid.uuid5(uuid.UUID(args.namespace), args.bundle_id)
    # uuid.UUID.bytes is big-endian (network order) — same byte order
    # Mach-O stores LC_UUID in, so we can drop them in directly.
    pinned_bytes = pinned.bytes
    assert len(pinned_bytes) == 16

    with open(args.binary, "rb") as f:
        data = bytearray(f.read())

    total = 0
    for so in slice_offsets_of(data):
        for uo in find_lc_uuid_offsets(data, so):
            data[uo:uo + 16] = pinned_bytes
            total += 1
            if args.verbose:
                print(f"  slice@{so}: wrote {pinned} at offset {uo}", file=sys.stderr)

    if total == 0:
        print(f"error: no LC_UUID load command found in {args.binary}", file=sys.stderr)
        print("       (was the binary linked with -Wl,-no_uuid?)", file=sys.stderr)
        sys.exit(1)

    with open(args.binary, "wb") as f:
        f.write(bytes(data))

    print(f"pinned {total} LC_UUID -> {pinned} in {args.binary}")


if __name__ == "__main__":
    main()
