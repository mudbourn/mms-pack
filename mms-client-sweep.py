#!/usr/bin/env python3
"""Remove orphaned duplicate-mod-id jars from a client instance's mods folder.

    mms-client-sweep.py <instance_minecraft_dir> [pack_dir]

Why this exists
---------------
The server sync (mms-server-sync.py) has always removed superseded jars by
Fabric mod id. The client side had no equivalent, because packwiz-installer
only manages files it has in packwiz.json — a jar dropped in by hand is
invisible to it and is never cleaned up. Fabric refuses to start with two mods
sharing an id, so one stale hand-copied jar bricks the client, and no amount of
re-running the deploy fixes it.

Found on 2026-07-23: the live instance held both
mms-mod-compat-support-0.6.1.jar (hand-dropped, untracked) and 0.6.7.jar
(packwiz-managed). Releasing 0.7.0 would only have changed which pair collided.

What counts as an orphan
------------------------
A jar in mods/ that (a) shares its Fabric mod id with another jar there, and
(b) is NOT the packwiz-managed copy. packwiz.json is the authority: an entry's
own key, plus its `cachedLocation`, are the managed paths.

Overlay dev jars are deliberately exempt
----------------------------------------
mms-overlay-apply.sh installs unreleased builds that are untracked by design
and DO duplicate a managed mod id — that is the whole mechanism. Sweeping them
would silently uninstall whatever is under test. Any mod id belonging to a slug
in overlay.list is therefore skipped entirely; overlay-apply already dedupes
its own targets.

Ambiguous collisions (two untracked jars, or two managed ones) are reported and
exit non-zero rather than guessed at — the caller should stop and let a human
look.
"""
import json
import os
import subprocess
import sys
import zipfile

instance = sys.argv[1]
pack_dir = sys.argv[2] if len(sys.argv) > 2 else os.path.dirname(os.path.abspath(__file__))
mods_dir = os.path.join(instance, 'mods')
packwiz_json = os.path.join(instance, 'packwiz.json')


def jar_id(path):
    """Fabric mod id of a jar, or None if unreadable."""
    try:
        with zipfile.ZipFile(path) as z:
            return json.loads(z.read('fabric.mod.json'))['id']
    except Exception:
        return None


def managed_jar_names():
    """Basenames of the jars packwiz-installer considers its own."""
    if not os.path.exists(packwiz_json):
        return None  # instance never reconciled; caller decides what that means
    with open(packwiz_json) as fh:
        cached = json.load(fh).get('cachedFiles', {})
    paths = set(cached)
    for entry in cached.values():
        loc = entry.get('cachedLocation')
        if loc:
            paths.add(loc)
    return {os.path.basename(p) for p in paths
            if p.startswith('mods/') and p.endswith('.jar')}


def overlay_protected_ids():
    """Mod ids currently under test via overlay.list — never sweep these."""
    list_path = os.path.join(pack_dir, 'overlay.list')
    if not os.path.exists(list_path):
        return set()
    ids = set()
    for raw in open(list_path):
        slug = raw.split('#', 1)[0].strip()
        if not slug:
            continue
        libs = os.path.expanduser(f'~/Documents/GitHub/{slug}/build/libs')
        if not os.path.isdir(libs):
            continue
        jars = [os.path.join(libs, f) for f in os.listdir(libs)
                if f.endswith('.jar') and '-sources' not in f]
        if not jars:
            continue
        newest = max(jars, key=os.path.getmtime)
        mid = jar_id(newest)
        if mid:
            ids.add(mid)
    return ids


if not os.path.isdir(mods_dir):
    print(f"client sweep: no mods dir at {mods_dir} — skipping "
          "(launch the instance once so packwiz creates it)")
    sys.exit(0)

managed = managed_jar_names()
if managed is None:
    print(f"client sweep: no packwiz.json in {instance} — skipping "
          "(nothing to call authoritative)")
    sys.exit(0)

protected = overlay_protected_ids()

by_id = {}
for name in sorted(os.listdir(mods_dir)):
    if not name.endswith('.jar'):
        continue
    mid = jar_id(os.path.join(mods_dir, name))
    if mid:
        by_id.setdefault(mid, []).append(name)

removed = 0
exempt = 0
unresolved = []
for mid, jars in sorted(by_id.items()):
    if len(jars) < 2:
        continue
    if mid in protected:
        print(f"client sweep: '{mid}' has {len(jars)} jars but is under test "
              f"via overlay.list — leaving alone ({', '.join(jars)})")
        exempt += 1
        continue
    tracked = [j for j in jars if j in managed]
    if len(tracked) != 1:
        unresolved.append((mid, jars, tracked))
        continue
    for j in jars:
        if j == tracked[0]:
            continue
        os.remove(os.path.join(mods_dir, j))
        print(f"client sweep: removed orphan {j} "
              f"(duplicate id '{mid}', packwiz manages {tracked[0]})")
        removed += 1

if unresolved:
    print()
    for mid, jars, tracked in unresolved:
        which = f"{len(tracked)} of them packwiz-managed"
        print(f"!! client sweep: '{mid}' has {len(jars)} jars, {which} — "
              f"cannot pick automatically: {', '.join(jars)}", file=sys.stderr)
    print("!! Fabric will not start with duplicate mod ids. Resolve by hand, "
          "then re-run.", file=sys.stderr)
    sys.exit(1)

if removed:
    print(f"client sweep: {removed} orphan(s) removed")
elif exempt:
    print(f"client sweep: nothing to remove ({exempt} overlay-exempt id(s) left as-is)")
else:
    print("client sweep: no duplicate mod ids")
