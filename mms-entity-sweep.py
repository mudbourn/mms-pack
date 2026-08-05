#!/usr/bin/env python3
"""mms-entity-sweep — find orphaned marker entities in saved world data.

Some mods implement mechanics by summoning invisible helper entities and
killing them again later. When the cleanup path misses one, the helper is
left behind forever: invisible, silent, usually Invulnerable, and often
still occupying a block of collision. `to_crawl` did exactly this — its
crawl hitbox was a shulker riding a text_display, and only the vehicle got
killed. See the KNOWN table below.

This reads the region files directly, so it finds orphans in chunks nobody
has loaded and needs no server downtime. It never writes to the world; it
prints `kill` commands for you to paste into the server console.

Usage:
    mms-entity-sweep.py [WORLD_DIR] [-t TAG] [--all-entities]

    WORLD_DIR   defaults to the prod server's world/
    -t TAG      sweep for an arbitrary scoreboard tag (repeatable)
    --all       report every entity carrying any KNOWN tag, orphan or not

Exit status is 1 when anything was found, so it can gate a restart script.
"""

import argparse
import glob
import os
import re
import struct
import sys
import zlib

DEFAULT_WORLD = os.path.expanduser("~/Documents/GitHub/Server Prod/world")

# tag -> (entity id that leaks, human description)
KNOWN = {
    "to_crawl.hitbox": ("minecraft:shulker", "to_crawl crawl hitbox"),
    "to_crawl.collision": ("minecraft:shulker", "to_crawl crawl hitbox"),
}

# Dimension subpaths relative to the world dir, with their command namespace.
DIMENSIONS = [
    ("", "minecraft:overworld"),
    ("DIM-1", "minecraft:the_nether"),
    ("DIM1", "minecraft:the_end"),
]

ID_RE = re.compile(rb"\x08\x00\x02id\x00.(minecraft:[a-z_]+)", re.S)
POS_RE = re.compile(rb"\x09\x00\x03Pos\x06\x00\x00\x00\x03(.{24})", re.S)


def chunks(path):
    """Yield each decompressed chunk payload from an Anvil region file."""
    with open(path, "rb") as fh:
        header = fh.read(4096)
        if len(header) < 4096:
            return  # empty or truncated region file
        for i in range(1024):
            offset = struct.unpack(">I", b"\0" + header[i * 4 : i * 4 + 3])[0]
            sectors = header[i * 4 + 3]
            if offset == 0:
                continue
            fh.seek(offset * 4096)
            raw = fh.read(sectors * 4096)
            if len(raw) < 5:
                continue
            length, scheme = struct.unpack(">I", raw[:4])[0], raw[4]
            payload = raw[5 : 4 + length]
            try:
                if scheme == 1:
                    payload = zlib.decompress(payload, 47)  # gzip
                elif scheme == 2:
                    payload = zlib.decompress(payload)
                elif scheme != 3:
                    continue  # 3 is uncompressed; anything else is unknown
            except zlib.error:
                continue
            yield payload


def find_in_chunk(data, tag):
    """Locate entities carrying `tag`, returning (entity_id, pos, flags).

    The region payload is scanned rather than fully parsed: for each hit on
    the tag we take the nearest preceding entity id and Pos triple, which is
    reliable because an entity's own id and Pos always sit closer to its tag
    list than a sibling entity's do.
    """
    needle = tag.encode()
    for hit in re.finditer(re.escape(needle), data):
        lo = max(0, hit.start() - 3000)
        hi = min(len(data), hit.start() + 3000)
        window, rel = data[lo:hi], hit.start() - lo

        ids = [(m.start(), m.group(1).decode()) for m in ID_RE.finditer(window)]
        poss = [
            (m.start(), struct.unpack(">ddd", m.group(1)))
            for m in POS_RE.finditer(window)
        ]
        entity_id = min(ids, key=lambda t: abs(t[0] - rel))[1] if ids else "?"
        pos = min(poss, key=lambda t: abs(t[0] - rel))[1] if poss else None

        ctx = window[max(0, rel - 400) : rel + 400]
        flags = [
            f
            for f in (b"Invulnerable", b"NoAI", b"Silent", b"Glowing")
            if f in ctx
        ]
        yield entity_id, pos, [f.decode() for f in flags]


def sweep(world, tags):
    found = []
    for sub, namespace in DIMENSIONS:
        ent_dir = os.path.join(world, sub, "entities") if sub else os.path.join(world, "entities")
        if not os.path.isdir(ent_dir):
            continue
        for mca in sorted(glob.glob(os.path.join(ent_dir, "*.mca"))):
            for data in chunks(mca):
                for tag in tags:
                    if tag.encode() not in data:
                        continue
                    for entity_id, pos, flags in find_in_chunk(data, tag):
                        found.append((namespace, entity_id, pos, tag, flags, mca))
    return found


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("world", nargs="?", default=DEFAULT_WORLD)
    ap.add_argument("-t", "--tag", action="append", default=[],
                    help="extra scoreboard tag to sweep for (repeatable)")
    args = ap.parse_args()

    if not os.path.isdir(args.world):
        sys.exit(f"World dir not found: {args.world}\n"
                 f"Is the AMP share mounted?")

    tags = args.tag or list(KNOWN)
    found = sweep(args.world, tags)

    # A tag can appear on both a vehicle and its passenger; de-duplicate by
    # position so a single leaked entity is reported once.
    seen, unique = set(), []
    for row in found:
        key = (row[0], row[2])
        if key not in seen:
            seen.add(key)
            unique.append(row)

    if not unique:
        print(f"Clean — no orphaned marker entities in {args.world}")
        return 0

    print(f"Found {len(unique)} orphaned marker entit"
          f"{'y' if len(unique) == 1 else 'ies'} in {args.world}\n")

    for namespace, entity_id, pos, tag, flags, mca in unique:
        where = f"{pos[0]:.1f} {pos[1]:.1f} {pos[2]:.1f}" if pos else "?"
        desc = KNOWN.get(tag, (None, tag))[1]
        print(f"  {namespace:22} {entity_id:24} {where:26} "
              f"[{desc}] {','.join(flags)}")

    print("\nConsole commands (forceload, kill, release):\n")
    for namespace, entity_id, pos, tag, flags, mca in unique:
        if not pos:
            continue
        x, y, z = int(pos[0]), int(pos[1]), int(pos[2])
        short = entity_id.split(":", 1)[1]
        print(f"execute in {namespace} run forceload add {x} {z}")
        print(f"execute in {namespace} positioned {x} {y} {z} run "
              f"kill @e[type={short},tag={tag},distance=..16]")
        print(f"execute in {namespace} run forceload remove {x} {z}")
        print()

    return 1


if __name__ == "__main__":
    sys.exit(main())
