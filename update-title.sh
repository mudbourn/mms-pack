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
PRESERVE_ENTRIES=(
  "options.txt"
  "servers.dat"
  "config/Easy Shop Mod/My Skin/skin.png"
  "config/xaero/minimap/Multiplayer_mc.mudbourn.info/config.txt"
)
for entry in "${PRESERVE_ENTRIES[@]}"; do
  # An entry can legitimately leave the index — Easy Shop Mod renamed skin.png to
  # a per-UUID filename, for one. Skip it rather than falling through to the sed:
  # the address below is unescaped, so a path with slashes aborts the script under
  # `set -e` and the pack.toml hash update at the bottom never runs.
  if ! grep -q "file = \"$entry\"" "$PACK_DIR/index.toml"; then
    echo "note: '$entry' is not in the index — preserve flag skipped."
    continue
  fi
  # Only add if not already present
  if ! grep -A2 "file = \"$entry\"" "$PACK_DIR/index.toml" | grep -q "preserve"; then
    # escape / and & so a path with slashes is a valid sed address
    esc=$(printf '%s' "$entry" | sed 's/[\/&]/\\&/g')
    sed -i '' "/file = \"$esc\"/{
      n
      a\\
preserve = true
    }" "$PACK_DIR/index.toml"
  fi
done

# Update pack.toml index hash
NEW_HASH=$(sha256sum "$PACK_DIR/index.toml" | cut -d' ' -f1)
sed -i '' "s/hash = \"[a-f0-9]*\"/hash = \"$NEW_HASH\"/" "$PACK_DIR/pack.toml"

echo "Title updated to: $TITLE"
