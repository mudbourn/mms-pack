#!/usr/bin/env python3
"""Flag network-path mods that overlap each other or sit on only one side.

    mms-netdrift-check.py <server_mods_dir> [pack_dir]

Why this exists
---------------
The client and server encode and decode the same byte stream. Two things break
that agreement, and neither is visible to the existing tooling:

  1. A mod that patches the packet pipeline is installed on only one side, so
     the two ends disagree about framing.
  2. Two mods patch the *same* vanilla networking class. Mixin application order
     between unrelated mods is not deterministic, and the order the server
     resolves need not match the order any given client resolves — so the same
     pair of mods can produce different pipelines on each end.

Either way the stream desyncs, the reader lands mid-packet, and you get a
garbage read followed by a decode failure.

mms-server-sync.py already reports jars the server holds that the pack does not
list, but it treats them all alike and says so explicitly: "a hand-installed
server-only mod is indistinguishable from an orphan here". For most mods that is
fine — a client-only mod in the server's mods/ is inert baggage. For a mod on
the packet path it is not.

Observed on MMSLive01: four disconnects across 2026-07-24/25/26 were all
client->server stream desyncs — each a bogus "moved too quickly" with ~2e7/3e7
deltas, immediately followed by DecoderException (`incorrect header check`, or
`Badly compressed packet - size of N is below server threshold of 256`).
PacketFixer and XXLPackets are both installed, both side="both", and both mixin
CompressionDecoder, the encoder and the byte-buf class. That is case 2, and it
is what the OVERLAP finding is for.

How network mods are detected
-----------------------------
A jar declaring at least one mixin whose compiled class references a Minecraft
networking class. This is a bytecode constant-pool scan rather than a name
match: mixin targets land in the pool either way, and matching on
`CompressionDecoderMixin`-style names misses anything named differently.
Heuristic, so it over-reports rather than under-reports — a false positive costs
one look at a jar. Intermediary keeps the `net/minecraft/network` package path
even where class names are obfuscated, so remapped and unremapped builds both
match.

Findings
--------
OVERLAP  two or more mods patch the same networking choke point.
HIGH     a network-path mod is installed on only one side.
NOTE     non-network drift — baggage, the mms-server-sync.py case, reported
         only for completeness.

Exits non-zero on any OVERLAP or HIGH finding, so a deploy script can gate on it.
"""
import json
import os
import re
import sys
import zipfile
from collections import defaultdict

server_mods = sys.argv[1]
pack_dir = sys.argv[2] if len(sys.argv) > 2 else os.path.dirname(os.path.abspath(__file__))
pack_mods = os.path.join(pack_dir, 'mods')

# Constant-pool markers for the networking stack. The first is the broad net —
# anything touching the packet path at all. The rest are the specific choke
# points where two mods overlapping corrupts the stream rather than merely
# changing behaviour, so only these are worth an OVERLAP report.
BROAD_MARKER = b'net/minecraft/network'
CHOKE_MARKERS = (
    b'CompressionDecoder',
    b'CompressionEncoder',
    b'Varint21',
    b'FriendlyByteBuf',
    b'PacketByteBuf',
    b'NbtAccounter',
    b'PacketEncoder',
    b'PacketDecoder',
)


def jar_meta(path):
    """(mod id, list of mixin config names) for a jar; (None, []) if unreadable."""
    try:
        with zipfile.ZipFile(path) as z:
            fm = json.loads(z.read('fabric.mod.json'))
    except Exception:
        return None, []
    configs = []
    for cfg in fm.get('mixins', []):
        configs.append(cfg['config'] if isinstance(cfg, dict) else cfg)
    return fm.get('id'), configs


def network_markers(path, configs):
    """Set of markers matched across a jar's declared mixin classes.

    BROAD_MARKER present means "touches the packet path"; any CHOKE_MARKERS
    present name the specific vanilla classes it patches.
    """
    found = set()
    if not configs:
        return found
    try:
        with zipfile.ZipFile(path) as z:
            for cfg in configs:
                try:
                    m = json.loads(z.read(cfg))
                except Exception:
                    continue
                pkg = m.get('package', '').replace('.', '/')
                for name in m.get('mixins', []) + m.get('client', []) + m.get('server', []):
                    entry = f"{pkg}/{name.replace('.', '/')}.class"
                    try:
                        blob = z.read(entry)
                    except KeyError:
                        continue
                    for marker in (BROAD_MARKER,) + CHOKE_MARKERS:
                        if marker in blob:
                            found.add(marker)
    except Exception:
        return found
    return found


def allowed_overlaps():
    """{choke marker: {mod ids}} for overlaps signed off in netdrift-allow.txt.

    A hard gate is only useful if it stays quiet about things already reviewed,
    so an accepted overlap is recorded here rather than weakening the check.
    Format is `marker: modid, modid, ...`, blank lines and # comments ignored.
    An allowed entry silences the overlap only if the mod set matches exactly —
    a fourth mod joining the pile re-raises it.
    """
    path = os.path.join(pack_dir, 'netdrift-allow.txt')
    out = {}
    if not os.path.exists(path):
        return out
    for line in open(path, encoding='utf-8'):
        line = line.split('#', 1)[0].strip()
        if not line or ':' not in line:
            continue
        marker, mods = line.split(':', 1)
        out[marker.strip()] = {m.strip() for m in mods.split(',') if m.strip()}
    return out


def pack_entries():
    """{filename: side} for every mod the pack lists."""
    out = {}
    if not os.path.isdir(pack_mods):
        return out
    for toml in sorted(os.listdir(pack_mods)):
        if not toml.endswith('.pw.toml'):
            continue
        text = open(os.path.join(pack_mods, toml), encoding='utf-8').read()
        # NB: match the `filename` field, not the .pw.toml's own name — they
        # differ often enough that grepping filenames silently misses mods.
        fn = re.search(r'^filename\s*=\s*"(.+?)"', text, re.M)
        side = re.search(r'^side\s*=\s*"(.+?)"', text, re.M)
        if fn:
            # packwiz omits `side` when it means both.
            out[fn.group(1)] = side.group(1) if side else 'both'
    return out


def main():
    listed = pack_entries()
    if not listed:
        print(f"!! no .pw.toml entries under {pack_mods} — wrong pack_dir?", file=sys.stderr)
        return 2

    overlap = defaultdict(list)   # choke marker -> [mod ids]
    high, note = [], []

    for name in sorted(os.listdir(server_mods)):
        if not name.endswith('.jar'):
            continue
        path = os.path.join(server_mods, name)
        mod_id, configs = jar_meta(path)
        if mod_id is None:
            continue

        side = listed.get(name)
        markers = network_markers(path, configs)

        for choke in CHOKE_MARKERS:
            if choke in markers:
                overlap[choke.decode()].append(mod_id)

        # Only a choke-point patch makes one-sided installation a desync risk.
        # A mod that merely references net/minecraft/network is almost always
        # running its own custom payload channel: installing it on one side
        # means the other side lacks a feature, not that framing disagrees.
        # REI is the standing example — server-side, not in the pack, and
        # entirely harmless to the stream.
        framing = any(c in markers for c in CHOKE_MARKERS)

        if side is None:
            # On the server, unknown to the pack -> clients never receive it.
            (high if framing else note).append(
                (name, mod_id, 'on server, not in pack'
                 + (' — patches packet framing' if framing else ''))
            )
        elif side == 'server' and framing:
            # Listed, but the pack deliberately withholds it from clients.
            high.append((name, mod_id, 'pack side="server" but patches packet framing'))
        elif side == 'client':
            note.append((name, mod_id, 'pack side="client" but installed on server'))

    allowed = allowed_overlaps()
    contested, accepted = {}, {}
    for k, v in overlap.items():
        mods = set(v)
        if len(mods) < 2:
            continue
        (accepted if allowed.get(k) == mods else contested)[k] = mods

    for choke, mods in sorted(contested.items()):
        print(f"OVERLAP  {choke}  patched by: {', '.join(sorted(mods))}")
    for choke, mods in sorted(accepted.items()):
        print(f"ALLOWED  {choke}  patched by: {', '.join(sorted(mods))}  (netdrift-allow.txt)")
    for name, mod_id, why in high:
        print(f"HIGH     {name}  [{mod_id}]  {why}")
    for name, mod_id, why in note:
        print(f"NOTE     {name}  [{mod_id}]  {why}")

    failed = bool(contested or high)
    print(f"\nnet drift check: {'FAILED' if failed else 'OK'} "
          f"({len(contested)} overlap, {len(high)} high, {len(note)} note)")
    return 1 if failed else 0


if __name__ == '__main__':
    sys.exit(main())
