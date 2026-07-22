#!/usr/bin/env bash
# mms-add — Add a mod to the mms-pack.
# Usage:
#   mms-add <modrinth-slug-or-url>   Add from Modrinth
#   mms-add /path/to/mod.jar         Bundle a local JAR
#   mms-add /path/to/dir/            Find and bundle the JAR in a directory
#   mms-add -u ...                   Update a previously bundled local JAR
set -euo pipefail

PACK_DIR="$HOME/Documents/GitHub/mms-pack"
MODS_DIR="$PACK_DIR/mods"
UPDATE=0

if [[ "${1:-}" == "-u" ]]; then
    UPDATE=1
    shift
fi

ARG="${1:-}"
if [[ -z "$ARG" ]]; then
    echo "Usage: mms-add [-u] <modrinth-slug-or-url | /path/to/mod.jar | /path/to/dir/>"
    exit 1
fi

cd "$PACK_DIR"
export PATH="$HOME/go/bin:$PATH"

# Resolve directory → single JAR inside it
resolve_jar() {
    local target="$1"
    if [[ -f "$target" ]]; then
        echo "$target"
        return
    fi
    if [[ -d "$target" ]]; then
        local jars=("$target"/*.jar)
        if [[ ${#jars[@]} -eq 0 || ! -f "${jars[0]}" ]]; then
            echo "ERROR: No .jar files found in $target" >&2
            exit 1
        fi
        if [[ ${#jars[@]} -gt 1 ]]; then
            echo "ERROR: Multiple .jar files found in $target:" >&2
            printf '  %s\n' "${jars[@]}" >&2
            exit 1
        fi
        echo "${jars[0]}"
        return
    fi
    # Not a file or directory — try as Modrinth slug
    echo ""
}

JAR_PATH="$(resolve_jar "$ARG")"

if [[ -n "$JAR_PATH" ]]; then
    # Local JAR (file or resolved from directory)
    JAR_NAME="$(basename "$JAR_PATH")"
    DEST="$MODS_DIR/$JAR_NAME"

    SLUG="$(echo "$JAR_NAME" | sed 's/\.jar$//' | sed 's/[-_][0-9][0-9.]*.*//; s/[-_]/-/g' | tr '[:upper:]' '[:lower:]')"
    [[ -z "$SLUG" ]] && SLUG="$(echo "$JAR_NAME" | sed 's/\.jar$//')"
    TOML="$MODS_DIR/$SLUG.pw.toml"

    HASH="$(shasum -a 512 "$JAR_PATH" | awk '{print $1}')"

    if [[ $UPDATE -eq 1 ]]; then
        EXISTING="$(grep -rl "filename = \"$JAR_NAME\"" "$MODS_DIR"/*.pw.toml 2>/dev/null | head -1 || true)"
        if [[ -n "$EXISTING" ]]; then
            TOML="$EXISTING"
            echo "Updating: $JAR_NAME"
        else
            echo "No existing .pw.toml found for $JAR_NAME, creating new one."
        fi
    fi

    cp "$JAR_PATH" "$DEST"
    echo "Copied: $JAR_NAME → mods/"

    cat > "$TOML" <<EOF
name = "$SLUG"
filename = "$JAR_NAME"
side = "both"

[download]
url = "file://$JAR_PATH"
hash-format = "sha512"
hash = "$HASH"

[update]
EOF
    echo "Metadata: $(basename "$TOML")"

    packwiz refresh
    echo "Done. Bundled $JAR_NAME into the pack."

else
    # Modrinth slug or URL
    packwiz modrinth add "$ARG" -y
fi
