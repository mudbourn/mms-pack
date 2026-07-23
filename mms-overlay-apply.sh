#!/bin/zsh
# mms-overlay-apply — drop locally-built "dev jars" into a mods folder, on top
# of whatever packwiz already installed there.
#
#   ./mms-overlay-apply.sh <target_mods_dir>
#
# An unreleased build has no packwiz download URL, so it can't ride the pack.
# Instead, `overlay.list` names the repo slugs currently under active testing;
# for each, this takes the newest non-sources jar from ~/Documents/GitHub/<slug>/
# build/libs, removes any jar in the target carrying the same Fabric mod id, and
# copies the dev jar in. Idempotent — safe to run every launch.
#
# Used by mms-deploy-test.sh (→ MMSTesting01 + test client) and by the test
# client's Prism PreLaunchCommand (runs after packwiz-installer reconciles).
set -e

TARGET="$1"
PACK="$HOME/Documents/GitHub/mms-pack"
LIST="$PACK/overlay.list"

[ -n "$TARGET" ] || { echo "overlay: usage: mms-overlay-apply.sh <target_mods_dir>" >&2; exit 2; }
[ -d "$TARGET" ] || { echo "overlay: target '$TARGET' does not exist" >&2; exit 1; }
[ -f "$LIST" ] || { echo "overlay: no overlay.list — nothing to apply"; exit 0; }

jar_id() {  # print the fabric mod id of a jar, or empty on failure
    python3 -c "import json,zipfile,sys
try: print(json.loads(zipfile.ZipFile(sys.argv[1]).read('fabric.mod.json'))['id'])
except Exception: print('')" "$1"
}

applied=0
while IFS= read -r raw; do
    slug="${raw%%#*}"                       # strip comments
    slug="${slug//[[:space:]]/}"            # strip whitespace
    [ -z "$slug" ] && continue

    repo="$HOME/Documents/GitHub/$slug"
    jar=$(ls -t "$repo"/build/libs/*.jar 2>/dev/null | grep -v -- -sources | head -1)
    if [ -z "$jar" ]; then
        echo "overlay: no build/libs jar for '$slug' — skipping" >&2
        continue
    fi

    id=$(jar_id "$jar")
    [ -z "$id" ] && { echo "overlay: can't read mod id from $jar — skipping" >&2; continue; }

    # remove any jar already in the target with the same fabric id (the
    # packwiz-managed release, or a stale overlay from a previous build)
    for j in "$TARGET"/*.jar(N); do
        [ "$(jar_id "$j")" = "$id" ] && rm -f "$j"
    done

    cp "$jar" "$TARGET/"
    echo "overlay: $slug → $(basename "$jar")"
    applied=$((applied + 1))
done < "$LIST"

echo "overlay: applied $applied dev jar(s) to $TARGET"
