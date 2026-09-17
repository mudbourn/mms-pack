#!/usr/bin/env bash
# mms-release — cut a tagged GitHub release for one of our own mods, and point
# the pack at it.
#
# Usage:
#   mms-release                  Release the repo in the current directory
#   mms-release <repo-name>      Release ~/Documents/GitHub/<repo-name>
#   mms-release --all            Release every manifest repo whose source is
#                                ahead of the tag the pack pins (see mms-repos.py
#                                releasable). Iterates in bottom-up build order.
#   mms-release -b <spec> ...    Bump mod_version first: patch | minor | major,
#                                or an explicit X.Y.Z. Rewrites gradle.properties
#                                BEFORE the build so the jar is stamped with the
#                                new version, then releases it. Refuses to go
#                                backwards. Without -b the version is whatever
#                                gradle.properties already says.
#   mms-release -n ...           Dry run: show what would happen
#   mms-release -y ...           Skip the confirmation prompt
#   mms-release --no-pack ...    Cut the release only; leave the pack alone
#
# This is the standalone half of what mms-deploy does in its "release reconcile"
# step, for when you want a release without also running packwiz update -a and
# syncing both servers. Same rules: the version comes from gradle.properties (or
# -b sets it), the built jar must actually carry that version, and a release is
# never cut for a version at or behind the one the pack already points at.
set -euo pipefail

PACK_DIR="$HOME/Documents/GitHub/mms-pack"
GITHUB_DIR="$HOME/Documents/GitHub"
DRY=0
YES=0
UPDATE_PACK=1
ALL=0
BUMP=""

while [[ "${1:-}" == -* ]]; do
    case "$1" in
        -n) DRY=1 ;;
        -y) YES=1 ;;
        --no-pack) UPDATE_PACK=0 ;;
        --all) ALL=1 ;;
        -b|--bump)
            shift
            BUMP="${1:-}"
            [[ -n "$BUMP" ]] || { echo "ERROR: -b needs an argument: patch | minor | major | X.Y.Z" >&2; exit 1; }
            ;;
        *) echo "Unknown flag: $1" >&2; exit 1 ;;
    esac
    shift
done

# Compute a bumped version. $1 = current, $2 = patch|minor|major|X.Y.Z.
# A keyword bump operates on the leading numeric core and drops any pre-release
# or build suffix (1.2.4+mms.1 --patch-> 1.2.5). An explicit spec is validated
# but otherwise passed through, so +suffixes can be set deliberately.
bump_version() {
    local cur="$1" spec="$2"
    case "$spec" in
        major|minor|patch)
            local core="${cur%%[!0-9.]*}"
            local M m p _
            IFS=. read -r M m p _ <<< "$core"
            M=${M:-0}; m=${m:-0}; p=${p:-0}
            case "$spec" in
                major) M=$((M + 1)); m=0; p=0 ;;
                minor) m=$((m + 1)); p=0 ;;
                patch) p=$((p + 1)) ;;
            esac
            printf '%s.%s.%s\n' "$M" "$m" "$p"
            ;;
        *)
            [[ "$spec" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]] \
                || { echo "ERROR: -b '$spec' is not patch|minor|major or an X.Y.Z version." >&2; return 1; }
            printf '%s\n' "$spec"
            ;;
    esac
}

# ── --all: fan out over the manifest ──
# The set of repos to release is not hardcoded here; it comes from mms-repos.py,
# which reads mms-repos.toml and compares each repo's source version to the tag
# the pack pins. We re-invoke this same script per repo (in bottom-up build
# order, so a library releases before the mods that pin it) and forward the
# other flags. Each sub-run does its own version/jar validation, so a stale repo
# in the list simply fails its own guard without poisoning the rest.
if [[ "$ALL" -eq 1 ]]; then
    [[ -n "${1:-}" ]] && { echo "ERROR: --all takes no repo argument." >&2; exit 1; }
    [[ -n "$BUMP" ]] && { echo "ERROR: -b cannot be combined with --all — a single bump" >&2; \
                          echo "       across every repo makes no sense. Bump each one on its own run." >&2; exit 1; }
    PY="$PACK_DIR/mms-repos.py"
    [[ -x "$PY" ]] || { echo "ERROR: $PY not found." >&2; exit 1; }
    TARGETS=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && TARGETS+=("$line")
    done < <("$PY" releasable)
    if [[ ${#TARGETS[@]} -eq 0 ]]; then
        echo "Nothing to release — every repo's source matches its pack pin."
        exit 0
    fi
    echo "Releasable (source ahead of pack pin): ${TARGETS[*]}"
    echo
    FLAGS=()
    [[ $DRY -eq 1 ]] && FLAGS+=(-n)
    [[ $YES -eq 1 ]] && FLAGS+=(-y)
    [[ $UPDATE_PACK -eq 0 ]] && FLAGS+=(--no-pack)
    rc=0
    for repo in "${TARGETS[@]}"; do
        echo "──────── $repo ────────"
        "$0" "${FLAGS[@]}" "$repo" || { rc=1; echo "!! $repo failed; continuing." >&2; }
        echo
    done
    exit $rc
fi

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

# ── -b: rewrite mod_version BEFORE the build ──
# Done here, before the jar path is computed, so the build below stamps the new
# version into the jar and the jar/version match check passes. The bump commit
# is not separate: the existing "git add -A && commit -m $TAG" in the release
# step sweeps gradle.properties in with everything else.
if [[ -n "$BUMP" ]]; then
    NEW="$(bump_version "$VERSION" "$BUMP")" || exit 1
    newest="$(printf '%s\n%s\n' "$VERSION" "$NEW" | sort -V | tail -1)"
    if [[ "$NEW" == "$VERSION" || "$newest" != "$NEW" ]]; then
        echo "ERROR: -b $BUMP would set $NEW, which is not ahead of the current $VERSION." >&2
        exit 1
    fi
    if [[ $DRY -eq 1 ]]; then
        echo "note: would bump mod_version $VERSION -> $NEW (gradle.properties; not written in dry run)."
    else
        sed -i.bak -E "s|^mod_version=.*|mod_version=${NEW}|" "$REPO/gradle.properties"
        rm -f "$REPO/gradle.properties.bak"
        echo "Bumped mod_version: $VERSION -> $NEW"
    fi
    VERSION="$NEW"
fi

# ── the jar has to match the version, not just exist ──
# A stale jar is the classic failure here: bump mod_version but forget to
# rebuild, and the release ships the previous build under the new tag.
jar_version() {
    python3 -c "import json,zipfile,sys; print(json.loads(zipfile.ZipFile(sys.argv[1]).read('fabric.mod.json'))['version'])" "$1" 2>/dev/null
}

# The built jar name can carry a repo-specific suffix (e.g. -MC1.21.11), so
# match by content (fabric.mod.json version) rather than a hardcoded filename —
# the same way the CI release engine globs build/libs for the main jar.
find_jar() {
    local f
    for f in "$REPO"/build/libs/*.jar; do
        [[ -e "$f" ]] || continue
        case "$f" in *-sources.jar|*-dev.jar|*-dev-shadow.jar) continue;; esac
        if [[ "$(jar_version "$f")" == "$VERSION" ]]; then
            printf '%s\n' "$f"
            return 0
        fi
    done
    return 1
}

JAR="$(find_jar || true)"
if [[ -z "$JAR" ]]; then
    if [[ $DRY -eq 1 ]]; then
        echo "note: no build/libs jar matches $VERSION — a real run would rebuild."
    else
        echo "Building $NAME ${VERSION}…"
        (cd "$REPO" && ./gradlew build -q)
        JAR="$(find_jar || true)"
    fi
fi
if [[ $DRY -eq 0 ]]; then
    [[ -n "$JAR" && -f "$JAR" ]] || { echo "ERROR: build produced no jar for $VERSION in $REPO/build/libs" >&2; exit 1; }
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
