#!/bin/zsh
# mms-deploy — update the pack, publish to clients, and sync shared mods to the server.
#
# 1. commit + push             any pending local changes ship first, untangled
#                              from whatever packwiz is about to touch
# 2. release reconcile         for our own mods (mudbourn/* slugs): if the local
#                              repo has a build newer than the released version,
#                              commit+push that repo, cut the GitHub release with
#                              the jar, and point the pack at it
# 3. packwiz update -a         bump every mod to latest
# 4. packwiz refresh           rebuild index
# 5. ./update-title.sh         re-apply preserve flags
# 6. commit + push             the packwiz changes; clients pick both up on
#                              next Prism launch
# 7. server sync               diff side=both/server mods against MMSLive01/mods,
#                              copy new jars in, remove superseded versions
set -e
cd ~/Documents/GitHub/mms-pack

# ship pending local edits before packwiz mixes its changes in with them
git add -A
if git diff --cached --quiet; then
    echo "pack: no local changes to commit"
else
    git commit -m "local pack changes"
    git push
    echo "pack: local changes pushed"
fi

echo "── release reconcile (local mods) ──"
for toml in mods/*.pw.toml; do
    slug=$(grep -m1 '^slug = "mudbourn/' "$toml" | sed 's|.*mudbourn/||; s|"||')
    [ -z "$slug" ] && continue
    repo="$HOME/Documents/GitHub/$slug"
    [ -d "$repo/.git" ] || continue
    jar=$(ls -t "$repo"/build/libs/*.jar 2>/dev/null | grep -v -- -sources | head -1)
    [ -z "$jar" ] && continue
    ver=$(python3 -c "import json,zipfile,sys; print(json.loads(zipfile.ZipFile(sys.argv[1]).read('fabric.mod.json'))['version'])" "$jar" 2>/dev/null)
    tag=$(grep -m1 '^tag = ' "$toml" | sed 's/tag = "v\{0,1\}//; s/"//')
    { [ -z "$ver" ] || [ -z "$tag" ] || [ "$ver" = "$tag" ]; } && continue
    # act only when the local build is strictly newer than the released tag
    [ "$(printf '%s\n%s\n' "$tag" "$ver" | sort -V | tail -1)" = "$ver" ] || continue
    echo "→ $slug: local build $ver ahead of released $tag — releasing v$ver"
    (
        cd "$repo"
        git add -A
        git diff --cached --quiet || git commit -m "v$ver"
        git push
        gh release view "v$ver" >/dev/null 2>&1 \
            || gh release create "v$ver" "$jar" --title "v$ver" --notes "released by mms-deploy"
    )
    packwiz update "${${toml:t}%.pw.toml}"
done

packwiz update -a
packwiz refresh
./update-title.sh

git add -A
if git diff --cached --quiet; then
    echo "pack: no mod updates to commit"
else
    git commit -m "update mods"
    git push
    echo "pack: pushed — clients update on next launch"
fi

echo "── server sync (MMSLive01) ──"
SERVER_MODS="$HOME/Documents/GitHub/MMSLive01/mods"
if [ ! -d "$SERVER_MODS" ]; then
    echo "!! server mods folder not mounted at $SERVER_MODS — skipping server sync." >&2
    echo "!! Mount the AMP share and re-run, or the server will drift out of sync." >&2
    exit 1
fi

python3 - "$SERVER_MODS" <<'EOF'
import json, os, re, shutil, sys, urllib.parse, urllib.request, zipfile

server_mods = sys.argv[1]
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

for name in sorted(os.listdir('mods')):
    if not name.endswith('.pw.toml'):
        continue
    txt = open(f'mods/{name}').read()
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
    local = os.path.join('mods', fname)
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
    print("\nserver: jars updated — RESTART MMSLive01 to apply (clients desync until then).")
else:
    print("server: already in sync")
EOF
