#!/usr/bin/env bash
# mms-remove — Remove a mod from the mms-pack.
# Usage:
#   mms-remove <slug-or-name-or-jar>   Remove a mod and its leftovers
#   mms-remove -n ...                  Dry run: show what would be removed
#   mms-remove -y ...                  Skip the confirmation prompt
#
# Matches against the .pw.toml basename, its `name =`, and its `filename =`
# (a mod's jar name and its .pw.toml name often disagree — grep both).
# Also cleans the mod's config/ files and any fabric_loader_dependencies
# override keyed to it, then refreshes the index.
set -euo pipefail

PACK_DIR="$HOME/Documents/GitHub/mms-pack"
MODS_DIR="$PACK_DIR/mods"
DRY=0
YES=0

while [[ "${1:-}" == -* ]]; do
    case "$1" in
        -n) DRY=1 ;;
        -y) YES=1 ;;
        *) echo "Unknown flag: $1" >&2; exit 1 ;;
    esac
    shift
done

ARG="${1:-}"
if [[ -z "$ARG" ]]; then
    echo "Usage: mms-remove [-n] [-y] <slug-or-name-or-jar>"
    exit 1
fi

cd "$PACK_DIR"
export PATH="$HOME/go/bin:$PATH"

# Normalize: strip a .jar/.pw.toml suffix and any path the user pasted
NEEDLE="$(basename "$ARG")"
NEEDLE="${NEEDLE%.jar}"
NEEDLE="${NEEDLE%.pw.toml}"
NEEDLE_LC="$(echo "$NEEDLE" | tr '[:upper:]' '[:lower:]')"

# Collect candidate .pw.toml files by basename, name = or filename =
MATCHES=()
EXACT=()
for toml in "$MODS_DIR"/*.pw.toml; do
    [[ -f "$toml" ]] || continue
    base="$(basename "$toml" .pw.toml)"
    name="$(sed -n 's/^name *= *"\(.*\)"$/\1/p' "$toml" | head -1)"
    file="$(sed -n 's/^filename *= *"\(.*\)"$/\1/p' "$toml" | head -1)"
    base_lc="$(echo "$base" | tr '[:upper:]' '[:lower:]')"
    name_lc="$(echo "$name" | tr '[:upper:]' '[:lower:]')"
    file_lc="$(echo "${file%.jar}" | tr '[:upper:]' '[:lower:]')"
    if [[ "$base_lc" == "$NEEDLE_LC" || "$name_lc" == "$NEEDLE_LC" || "$file_lc" == "$NEEDLE_LC" ]]; then
        EXACT+=("$toml")
    elif [[ "$base_lc|$name_lc|$file_lc" == *"$NEEDLE_LC"* ]]; then
        MATCHES+=("$toml")
    fi
done

# An exact hit wins outright — "sodium" shouldn't be ambiguous with sodium-extra
if [[ ${#EXACT[@]} -gt 0 ]]; then
    MATCHES=("${EXACT[@]}")
fi

if [[ ${#MATCHES[@]} -eq 0 ]]; then
    echo "No mod matching '$NEEDLE' found in mods/." >&2
    exit 1
fi

if [[ ${#MATCHES[@]} -gt 1 ]]; then
    echo "'$NEEDLE' matches multiple mods — be more specific:" >&2
    for m in "${MATCHES[@]}"; do
        echo "  $(basename "$m" .pw.toml)  ($(sed -n 's/^filename *= *"\(.*\)"$/\1/p' "$m" | head -1))" >&2
    done
    exit 1
fi

TOML="${MATCHES[0]}"
SLUG="$(basename "$TOML" .pw.toml)"
JAR="$(sed -n 's/^filename *= *"\(.*\)"$/\1/p' "$TOML" | head -1)"

# Everything we intend to delete
TARGETS=("$TOML")
[[ -n "$JAR" && -f "$MODS_DIR/$JAR" ]] && TARGETS+=("$MODS_DIR/$JAR")   # bundled local jars
for cfg in "config/$SLUG.json" "config/$SLUG.json5" "config/$SLUG.toml" \
           "config/$SLUG.properties" "config/$SLUG.txt" "config/$SLUG"; do
    [[ -e "$cfg" ]] && TARGETS+=("$cfg")
done

# fabric_loader_dependencies overrides keyed to this mod
FLD_FILES=()
for fld in config/fabric_loader_dependencies.json \
           config/modpack_defaults/config/fabric_loader_dependencies.json; do
    [[ -f "$fld" ]] || continue
    if grep -q "\"$SLUG\"" "$fld"; then
        FLD_FILES+=("$fld")
    fi
done

echo "Removing: $SLUG${JAR:+  ($JAR)}"
for t in "${TARGETS[@]}"; do echo "  delete  ${t#$PACK_DIR/}"; done
for f in "${FLD_FILES[@]}"; do echo "  edit    $f  (drop \"$SLUG\" override)"; done

if [[ $DRY -eq 1 ]]; then
    echo "Dry run — nothing changed."
    exit 0
fi

if [[ $YES -eq 0 ]]; then
    read -r -p "Proceed? [y/N] " reply
    [[ "$reply" == [yY]* ]] || { echo "Aborted."; exit 1; }
fi

rm -rf "${TARGETS[@]}"

for fld in "${FLD_FILES[@]}"; do
    python3 - "$fld" "$SLUG" <<'EOF'
import json, sys
path, slug = sys.argv[1], sys.argv[2]
with open(path) as fh:
    data = json.load(fh)
if data.get("overrides", {}).pop(slug, None) is not None:
    with open(path, "w") as fh:
        fh.write(json.dumps(data, separators=(",", ":")))
EOF
done

packwiz refresh

echo "Done. Removed $SLUG from the pack."
echo "Note: client jars are not swept — run mms-client-sweep.py if it's in your instance."
