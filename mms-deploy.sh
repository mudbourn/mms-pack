#!/bin/zsh
# mms-deploy — update the pack, publish to clients, and sync shared mods to the server.
#
# 1. packwiz update -a         bump every mod to latest
# 2. packwiz refresh           rebuild index
# 3. ./update-title.sh         re-apply preserve flags
# 4. commit + push             clients pick it up on next Prism launch
# 5. server sync               diff side=both/server mods against MMSLive01/mods,
#                              copy new jars in, remove superseded versions
set -e
cd ~/Documents/GitHub/mms-pack

packwiz update -a
packwiz refresh
./update-title.sh

git add -A
if git diff --cached --quiet; then
    echo "pack: no changes to commit"
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
import json, os, re, shutil, sys, urllib.request, zipfile

server_mods = sys.argv[1]
changed = False

def mod_id(path):
    """Fabric mod id from the jar; None if unreadable."""
    try:
        with zipfile.ZipFile(path) as z:
            return json.loads(z.read('fabric.mod.json'))['id']
    except Exception:
        return None

server_jars = {f: mod_id(os.path.join(server_mods, f))
               for f in os.listdir(server_mods) if f.endswith('.jar')}

for name in sorted(os.listdir('mods')):
    if not name.endswith('.pw.toml'):
        continue
    txt = open(f'mods/{name}').read()
    side = re.search(r'^side = "(\w+)"', txt, re.M)
    if side and side.group(1) == 'client':
        continue
    fname = re.search(r'^filename = "(.+)"', txt, re.M).group(1)
    url = re.search(r'^url = "(.+)"', txt, re.M).group(1)

    if fname in server_jars:
        continue  # already in sync

    # fetch the new jar (prefer bundled local copy)
    dest = os.path.join(server_mods, fname)
    local = os.path.join('mods', fname)
    if os.path.exists(local):
        shutil.copy(local, dest)
    else:
        urllib.request.urlretrieve(url, dest)

    # remove superseded versions: any other jar carrying the same fabric mod id
    new_id = mod_id(dest)
    old = [j for j, i in server_jars.items()
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
