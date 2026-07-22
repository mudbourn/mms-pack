#!/bin/bash
# Reads version from pack.toml and updates main menu title text
set -e

PACK_DIR="$(cd "$(dirname "$0")" && pwd)"
VERSION=$(grep '^version' "$PACK_DIR/pack.toml" | sed 's/.*"\(.*\)"/\1/')
TITLE="MMS Live Official Modpack $VERSION"

for f in \
  "$PACK_DIR/config/isxander-main-menu-credits.json" \
  "$PACK_DIR/config/modpack_defaults/config/isxander-main-menu-credits.json"; do
  if [ -f "$f" ]; then
    sed -i '' "s/MMS Live Official Modpack [0-9.]*/MMS Live Official Modpack $VERSION/g" "$f"
  fi
done

echo "Title updated to: $TITLE"
