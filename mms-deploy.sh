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
#
# 0. client sweep (preflight)  remove hand-dropped jars in the live instance that
#                              duplicate a packwiz-managed mod id. Runs FIRST, so
#                              a client that cannot boot is caught before a
#                              release is cut rather than after.
set -e
cd ~/Documents/GitHub/mms-pack

LIVE_CLIENT="$HOME/Library/Application Support/PrismLauncher/instances/MMS Live/minecraft"

# ── client sweep (preflight) ──
# packwiz-installer only manages files listed in packwiz.json, so a jar copied
# in by hand is never cleaned up — and two jars sharing a Fabric mod id stop the
# client booting at all. The server side has always deduped by mod id; this is
# the missing client-side half. Overlay dev jars are exempt (see the script).
python3 ./mms-client-sweep.py "$LIVE_CLIENT"

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
    # the releases API is eventually consistent — a just-created release can
    # be missing from the list for a few seconds, so retry until the toml
    # actually points at the new tag
    for attempt in 1 2 3 4 5; do
        packwiz update "${${toml:t}%.pw.toml}"
        grep -q "^tag = \"v$ver\"" "$toml" && break
        echo "   (release not visible yet, retrying in 5s...)"
        sleep 5
    done
    if ! grep -q "^tag = \"v$ver\"" "$toml"; then
        echo "!! $slug: pack still points at v$tag after release v$ver — re-run mms-deploy" >&2
    fi
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

# Shared with the test lane (mms-deploy-test.sh) — one implementation, so a
# fix to the never-downgrade or supersede rules cannot land on only one of
# the two servers. This was an inline copy that had already drifted from
# mms-server-sync.py by the time it was noticed.
python3 ./mms-server-sync.py "$SERVER_MODS"
