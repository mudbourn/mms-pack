#!/usr/bin/env python3
"""Sync a pack's side=both/server mods into a server's mods folder.

    mms-server-sync.py <server_mods_dir> [pack_dir] [--prune]

Extracted verbatim from mms-deploy.sh so the prod flow (→ MMSLive01) and the
test flow (→ MMSTesting01) share one implementation. pack_dir defaults to the
directory this script lives in. Adds new released jars, removes superseded
same-id jars, and refuses to downgrade a mod the server already runs a newer
build of — all as extracted.

It also reports jars the pack no longer lists at all (a mod deleted from the
pack leaves no .pw.toml for the add loop to notice, so its jar used to live on
the server forever). `--prune` removes them; without it they are only reported,
since a hand-installed server-only mod is indistinguishable from an orphan here.
"""
import json, os, re, shutil, sys, urllib.parse, urllib.request, zipfile

args = [a for a in sys.argv[1:] if not a.startswith('--')]
prune = '--prune' in sys.argv[1:]

server_mods = args[0]
pack_dir = args[1] if len(args) > 1 else os.path.dirname(os.path.abspath(__file__))
mods_dir = os.path.join(pack_dir, 'mods')
changed = False
expected = set()   # filenames the pack expects this server to hold


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
    fname = re.search(r'^filename = "(.+)"', txt, re.M).group(1)
    # Recorded for EVERY entry, client-side included, before the side filter
    # below skips it. The orphan pass asks "does the pack still list this jar",
    # not "should this jar be here": client mods do end up in server mods dirs
    # and are none of this script's business, but they are emphatically not
    # abandoned. Filtering them into the orphan list flagged a dozen of them.
    expected.add(fname)
    side = re.search(r'^side = "(\w+)"', txt, re.M)
    if side and side.group(1) == 'client':
        continue
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


def base_name(jar):
    """Filename with its version tail cut off: modmenu-17.0.1-beta.1.jar -> modmenu.

    An exact filename match is too strict to decide a mod has LEFT the pack. A
    client mod sitting in the server's mods folder at an older version than the
    pack lists ('modmenu-17.0.0' vs 'modmenu-17.0.1-beta.1') is skew, not
    abandonment, and flagging it invited a prune that would delete a mod the
    pack still ships. Cutting at the first version-looking token compares the
    mod, not the build.
    """
    stem = jar[:-4] if jar.endswith('.jar') else jar
    return re.split(r'-v?\d', stem, maxsplit=1)[0]


def overlay_protected_ids():
    """Mod ids under test via overlay.list — never orphan these.

    Same rule, and same reason, as mms-client-sweep.py: an overlay jar is an
    unreleased build deliberately absent from the pack index, so it looks
    exactly like an orphan and must not be treated as one.
    """
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
        mid, _ = mod_info(max(jars, key=os.path.getmtime))
        if mid:
            ids.add(mid)
    return ids


# Orphans: jars the pack no longer asks for.
#
# The add loop above only ever ADDS, and only removes other builds of a mod it
# is currently installing. A mod DELETED from the pack is invisible to it — its
# .pw.toml is gone, so nothing iterates over it and nothing removes its jar. The
# server then keeps running a mod the clients have already dropped (packwiz
# -installer removes what leaves the index), which is the version-skew that
# shifts blockstate palettes. Found 2026-07-23 with mdm still live after eight
# mods were pulled from the pack.
#
# Report-only unless --prune, because "not in the pack" is not proof of junk:
# a server-only jar someone installed by hand looks identical from here. The
# caller decides; this just makes the drift visible instead of silent.
protected = overlay_protected_ids()
expected_bases = {base_name(f) for f in expected}
orphans = []
for f in sorted(os.listdir(server_mods)):
    if not f.endswith('.jar') or f in expected or base_name(f) in expected_bases:
        continue
    mid, _ = mod_info(os.path.join(server_mods, f))
    if mid is not None and mid in protected:
        continue  # dev build under test
    orphans.append((f, mid))

if orphans:
    for f, mid in orphans:
        if prune:
            os.remove(os.path.join(server_mods, f))
            print(f"pruned {f}  ({mid or 'unreadable jar'} — not in pack)")
            changed = True
        else:
            print(f"?? {f}  ({mid or 'unreadable jar'}) is on the server but not "
                  f"in the pack — re-run with --prune to remove", file=sys.stderr)

if changed:
    print("\nserver: jars updated — RESTART to apply (clients desync until then).")
else:
    print("server: already in sync")
