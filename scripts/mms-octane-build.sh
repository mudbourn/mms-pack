#!/bin/zsh
# mms-octane-build — rebuild the `octane` (low-end PC) branch from main.
#
#   ./scripts/mms-octane-build.sh             rebuild octane from main and push it
#   ./scripts/mms-octane-build.sh --dry-run   build it in a scratch worktree, show the
#                                     diff against main, push nothing
#
# octane is a derived branch: main minus octane.list. Each run resets octane to
# main's current commit, applies the list, runs packwiz refresh and commits one
# "octane build" commit on top. The push is a force push, since the branch is
# rebuilt rather than merged. Never commit to octane by hand; edit octane.list
# on main instead.
#
# The build happens in a temporary git worktree, so your checkout, its branch
# and any uncommitted work are never touched.
#
# Called by mms-deploy-prod.sh after main is pushed.
set -e

DRY=0
case "$1" in
    "") ;;
    --dry-run|--dev) DRY=1 ;;
    *) echo "usage: mms-octane-build.sh [--dry-run]" >&2; exit 2 ;;
esac

PACK="${0:A:h:h}"
LIST="$PACK/lists/octane.list"
cd "$PACK"
[ -f "$LIST" ] || { echo "!! octane: no octane.list at $LIST" >&2; exit 1; }

MAIN_SHA=$(git rev-parse --short main)
WT=$(mktemp -d "${TMPDIR:-/tmp}/mms-octane.XXXXXX")
cleanup() { git -C "$PACK" worktree remove --force "$WT" >/dev/null 2>&1 || rm -rf "$WT"; }
trap cleanup EXIT

echo "── octane: building from main @ $MAIN_SHA ──"
if [ "$DRY" = "1" ]; then
    git worktree add --detach "$WT" main >/dev/null
else
    git worktree add -B octane "$WT" main >/dev/null
fi
cd "$WT"

OPTS=(pack/options.txt pack/config/modpack_defaults/options.txt)
missing=0
packs=()

while IFS= read -r raw; do
    line="${raw%%#*}"
    line="${line%"${line##*[![:space:]]}"}"   # trim trailing space
    [ -z "$line" ] && continue
    kind="${line%% *}"
    arg="${line#* }"
    case "$kind" in
        mod)
            if [ -f "pack/mods/$arg.pw.toml" ]; then rm "pack/mods/$arg.pw.toml"
            else echo "?? octane: mod '$arg' is not in main any more" >&2; missing=1; fi ;;
        pack)
            if [ -e "pack/resourcepacks/$arg" ]; then rm -rf "pack/resourcepacks/$arg"
            else echo "?? octane: resource pack '$arg' is not in main any more" >&2; missing=1; fi
            packs+=("$arg") ;;
        copy)
            src="octane/${arg%% *}"
            dest="pack/${arg#* }"
            if [ -f "$src" ]; then mkdir -p "${dest:h}" && cp "$src" "$dest"
            else echo "!! octane: no $src to copy" >&2; exit 1; fi ;;
        option)
            key="${arg%%:*}"
            for f in $OPTS; do
                [ -f "$f" ] && python3 - "$f" "$key" "$arg" <<'EOF'
import sys
path, key, new = sys.argv[1:]
lines = open(path, encoding="utf-8").read().splitlines()
lines = [new if l.split(":", 1)[0] == key else l for l in lines]
open(path, "w", encoding="utf-8").write("\n".join(lines) + "\n")
EOF
            done ;;
        *) echo "!! octane: unknown line '$raw' in octane.list" >&2; exit 1 ;;
    esac
done < "$LIST"

# Drop cut packs from the enabled-pack list so the options don't point at
# folders that no longer exist.
for f in $OPTS; do
    [ -f "$f" ] && python3 - "$f" "${packs[@]}" <<'EOF'
import json, sys
path, cut = sys.argv[1], {"file/" + p for p in sys.argv[2:]}
lines = open(path, encoding="utf-8").read().splitlines()
for i, l in enumerate(lines):
    for key in ("resourcePacks:", "incompatibleResourcePacks:"):
        if l.startswith(key):
            packs = json.loads(l[len(key):])
            lines[i] = key + json.dumps([p for p in packs if p not in cut], separators=(",", ":"))
open(path, "w", encoding="utf-8").write("\n".join(lines) + "\n")
EOF
done

sed -i '' 's/^name = "MMS Live"$/name = "MMS Live Octane"/' pack/pack.toml
(cd pack && packwiz refresh) >/dev/null

git add -A
echo "── octane vs main ──"
git diff --cached --stat | tail -1
[ "$missing" = "1" ] && echo "?? octane: some list entries no longer match main; prune octane.list." >&2

if [ "$DRY" = "1" ]; then
    echo "[dry-run] octane not committed or pushed."
    exit 0
fi

git commit -q -m "octane build from main @ $MAIN_SHA"
git push -q --force-with-lease origin octane
echo "octane: pushed — Octane clients update on next launch"
