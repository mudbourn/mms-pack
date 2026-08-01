#!/usr/bin/env bash
# mms-release — cut a tagged GitHub release for one of our own mods, and point
# the pack at it.
#
# Usage:
#   mms-release                  Release the repo in the current directory
#   mms-release <repo-name>      Release ~/Documents/GitHub/<repo-name>
#   mms-release -n ...           Dry run: show what would happen
#   mms-release -y ...           Skip the confirmation prompt
#   mms-release --no-pack ...    Cut the release only; leave the pack alone
#
# This is the standalone half of what mms-deploy does in its "release reconcile"
# step, for when you want a release without also running packwiz update -a and
# syncing both servers. Same rules: the version comes from gradle.properties, the
# built jar must actually carry that version, and a release is never cut for a
# version at or behind the one the pack already points at.
set -euo pipefail

PACK_DIR="$HOME/Documents/GitHub/mms-pack"
GITHUB_DIR="$HOME/Documents/GitHub"
DRY=0
YES=0
UPDATE_PACK=1

while [[ "${1:-}" == -* ]]; do
    case "$1" in
        -n) DRY=1 ;;
        -y) YES=1 ;;
        --no-pack) UPDATE_PACK=0 ;;
        *) echo "Unknown flag: $1" >&2; exit 1 ;;
    esac
    shift
done

# ── resolve the repo ──
if [[ -n "${1:-}" ]]; then
    REPO="$GITHUB_DIR/$(basename "$1")"
else
    REPO="$(pwd)"
fi
[[ -d "$REPO/.git" ]] || { echo "ERROR: $REPO is not a git repo." >&2; exit 1; }
[[ -f "$REPO/gradle.properties" ]] || { echo "ERROR: no gradle.properties in $REPO." >&2; exit 1; }

NAME="$(basename "$REPO")"
export PATH="$HOME/go/bin:$PATH"

prop() { grep -m1 "^$1=" "$REPO/gradle.properties" | cut -d= -f2- | tr -d '[:space:]'; }
VERSION="$(prop mod_version)"
BASE="$(prop archives_base_name)"
[[ -n "$VERSION" ]] || { echo "ERROR: no mod_version in gradle.properties." >&2; exit 1; }

# ── the jar has to match the version, not just exist ──
# A stale jar is the classic failure here: bump mod_version but forget to
# rebuild, and the release ships the previous build under the new tag.
jar_version() {
    python3 -c "import json,zipfile,sys; print(json.loads(zipfile.ZipFile(sys.argv[1]).read('fabric.mod.json'))['version'])" "$1" 2>/dev/null
}

JAR="$REPO/build/libs/$BASE-$VERSION.jar"
if [[ ! -f "$JAR" ]] || [[ "$(jar_version "$JAR")" != "$VERSION" ]]; then
    if [[ $DRY -eq 1 ]]; then
        echo "note: $BASE-$VERSION.jar is missing or stale — a real run would rebuild."
    else
        echo "Building $NAME $VERSION…"
        (cd "$REPO" && ./gradlew build -q)
    fi
fi
if [[ $DRY -eq 0 ]]; then
    [[ -f "$JAR" ]] || { echo "ERROR: build produced no $JAR" >&2; exit 1; }
    BUILT="$(jar_version "$JAR")"
    [[ "$BUILT" == "$VERSION" ]] || {
        echo "ERROR: $JAR reports version '$BUILT', expected '$VERSION'." >&2
        exit 1
    }
fi

TAG="v$VERSION"

# ── find the pack metafile that tracks this repo, if any ──
TOML=""
if [[ $UPDATE_PACK -eq 1 ]]; then
    TOML="$(grep -l "^slug = \"mudbourn/$NAME\"" "$PACK_DIR"/mods/*.pw.toml 2>/dev/null | head -1 || true)"
    if [[ -z "$TOML" ]]; then
        echo "note: no pack metafile points at mudbourn/$NAME — releasing only."
        UPDATE_PACK=0
    else
        PACK_TAG="$(grep -m1 '^tag = ' "$TOML" | sed 's/tag = "//; s/"//')"
        if [[ "$PACK_TAG" == "$TAG" ]]; then
            echo "Pack already points at $TAG — nothing to release."
            exit 0
        fi
        # never walk a release backwards; sort -V puts the newer one last
        newest="$(printf '%s\n%s\n' "${PACK_TAG#v}" "$VERSION" | sort -V | tail -1)"
        if [[ "$newest" != "$VERSION" ]]; then
            echo "ERROR: local build $VERSION is BEHIND the released $PACK_TAG." >&2
            echo "       Bump mod_version before releasing." >&2
            exit 1
        fi
    fi
fi

if git -C "$REPO" rev-parse "$TAG" >/dev/null 2>&1 \
   || gh release view "$TAG" --repo "mudbourn/$NAME" >/dev/null 2>&1; then
    echo "ERROR: $TAG already exists. Bump mod_version." >&2
    exit 1
fi

# ── plan ──
echo "Release $NAME $TAG"
echo "  jar        $(basename "$JAR")"
DIRTY="$(git -C "$REPO" status --porcelain | wc -l | tr -d ' ')"
if [[ "$DIRTY" != "0" ]]; then
    echo "  commit     $DIRTY uncommitted path(s) as \"$TAG\""
    git -C "$REPO" status --short | sed 's/^/               /'
fi
echo "  push       $(git -C "$REPO" remote get-url origin 2>/dev/null || echo '(no remote)')"
echo "  gh release create $TAG"
[[ $UPDATE_PACK -eq 1 ]] && echo "  pack       $(basename "$TOML"): $PACK_TAG -> $TAG"

if [[ $DRY -eq 1 ]]; then
    echo "Dry run — nothing changed."
    exit 0
fi

if [[ $YES -eq 0 ]]; then
    read -r -p "Proceed? [y/N] " reply
    [[ "$reply" == [yY]* ]] || { echo "Aborted."; exit 1; }
fi

# ── release ──
(
    cd "$REPO"
    git add -A
    git diff --cached --quiet || git commit -m "$TAG"
    git push
    gh release create "$TAG" "$JAR" --title "$TAG" --notes "released by mms-release"
)
echo "Released $NAME $TAG"

# ── point the pack at it ──
if [[ $UPDATE_PACK -eq 1 ]]; then
    cd "$PACK_DIR"
    slug="$(basename "$TOML" .pw.toml)"
    # The releases API is eventually consistent: a just-created release can be
    # missing from the list for a few seconds, so retry until the toml moves.
    for attempt in 1 2 3 4 5; do
        packwiz update "$slug" || true
        grep -q "^tag = \"$TAG\"" "$TOML" && break
        echo "   (release not visible yet, retrying in 5s...)"
        sleep 5
    done
    if ! grep -q "^tag = \"$TAG\"" "$TOML"; then
        echo "!! pack still points at $PACK_TAG — re-run mms-release once the release is visible." >&2
        exit 1
    fi
    packwiz refresh
    ./update-title.sh
    echo "Pack updated: $slug -> $TAG (uncommitted — commit when you're ready)."
fi
