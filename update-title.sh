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

# Update fabric_loader_dependencies version check
for f in \
  "$PACK_DIR/config/fabric_loader_dependencies.json" \
  "$PACK_DIR/config/modpack_defaults/config/fabric_loader_dependencies.json"; do
  if [ -f "$f" ]; then
    sed -i '' "s/\"MMS Live\":\">[0-9.]*\"/\"MMS Live\":\">$VERSION\"/g" "$f"
  fi
done

# Re-apply preserve flags (packwiz refresh strips them)
for entry in "options.txt" "servers.dat"; do
  sed -i '' "/file = \"$entry\"/{
    n
    /preserve/!a\\
preserve = true
  }" "$PACK_DIR/index.toml"
done

# Update pack.toml index hash
NEW_HASH=$(sha256sum "$PACK_DIR/index.toml" | cut -d' ' -f1)
sed -i '' "s/hash = \"[a-f0-9]*\"/hash = \"$NEW_HASH\"/" "$PACK_DIR/pack.toml"

echo "Title updated to: $TITLE"
