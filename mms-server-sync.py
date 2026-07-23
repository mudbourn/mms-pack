#!/usr/bin/env python3
"""Sync a pack's side=both/server mods into a server's mods folder.

    mms-server-sync.py <server_mods_dir> [pack_dir]

Extracted verbatim from mms-deploy.sh so the prod flow (→ MMSLive01) and the
test flow (→ MMSTesting01) share one implementation. pack_dir defaults to the
directory this script lives in. Behaviour is identical to the original inline
version: adds new released jars, removes superseded same-id jars, and refuses
to downgrade a mod the server already runs a newer build of.
"""
import json, os, re, shutil, sys, urllib.parse, urllib.request, zipfile

server_mods = sys.argv[1]
pack_dir = sys.argv[2] if len(sys.argv) > 2 else os.path.dirname(os.path.abspath(__file__))
mods_dir = os.path.join(pack_dir, 'mods')
changed = False


def mod_info(path):
    """(id, version) from the jar's fabric.mod.json; (None, None) if unreadable."""
    try:
        with zipfile.ZipFile(path) as z:
            meta = json.loads(z.read('fabric.mod.json'))
            return meta['id'], meta.get('version')
    except Exception:
        return None, None


def ver_key(v):
    """Sortable key from a version string; None if it has no numeric parts."""
    nums = re.findall(r'\d+', v or '')
    return tuple(int(n) for n in nums) if nums else None


server_jars = {f: mod_info(os.path.join(server_mods, f))
               for f in os.listdir(server_mods) if f.endswith('.jar')}

for name in sorted(os.listdir(mods_dir)):
    if not name.endswith('.pw.toml'):
        continue
    txt = open(os.path.join(mods_dir, name)).read()
    side = re.search(r'^side = "(\w+)"', txt, re.M)
    if side and side.group(1) == 'client':
        continue
    fname = re.search(r'^filename = "(.+)"', txt, re.M).group(1)
    url_m = re.search(r'^url = "(.+)"', txt, re.M)
    if url_m:
        url = url_m.group(1)
    else:
        # CurseForge metadata mode: no direct url; build the forgecdn one
        fid = re.search(r'^file-id = (\d+)', txt, re.M)
        if not fid:
            print(f"!! {name}: no url and no file-id — skipping", file=sys.stderr)
            continue
        fid = int(fid.group(1))
        url = (f"https://edge.forgecdn.net/files/{fid // 1000}/{fid % 1000}/"
               + urllib.parse.quote(fname))

    if fname in server_jars:
        continue  # already in sync

    # fetch the new jar (prefer bundled local copy)
    dest = os.path.join(server_mods, fname)
    local = os.path.join(mods_dir, fname)
    if os.path.exists(local):
        shutil.copy(local, dest)
    else:
        urllib.request.urlretrieve(url, dest)

    new_id, new_ver = mod_info(dest)

    # never downgrade: if the server already runs a NEWER build of this mod
    # (e.g. a locally built mms-mod-compat-support ahead of its release),
    # keep the server's jar and skip — cut the release / update the pack
    # instead of silently rolling the server back.
    newer = [(j, v) for j, (i, v) in server_jars.items()
             if i is not None and i == new_id and j != fname
             and ver_key(v) is not None and ver_key(new_ver) is not None
             and ver_key(v) > ver_key(new_ver)]
    if newer:
        os.remove(dest)
        for j, v in newer:
            print(f"!! {name}: server has NEWER {new_id} {v} ({j}) than pack's "
                  f"{new_ver} — NOT downgrading. Update the pack to {v}.", file=sys.stderr)
        continue

    # remove superseded versions: any other jar carrying the same fabric mod id
    old = [j for j, (i, v) in server_jars.items()
           if i is not None and i == new_id and j != fname]
    for j in old:
        os.remove(os.path.join(server_mods, j))
    print(f"synced {fname}" + (f"  (replaced {', '.join(old)})" if old else "  (new)"))
    changed = True

if changed:
    print("\nserver: jars updated — RESTART to apply (clients desync until then).")
else:
    print("server: already in sync")
