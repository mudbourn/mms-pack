#!/bin/zsh
# mms-deploy-test — stage pack changes on the `testing` branch and push them to
# the test targets ONLY. Mirror of mms-deploy.sh for the staging lane.
#
# It deliberately does NOT:
#   • cut GitHub releases          (dev builds ride overlay.list, not the pack)
#   • run `packwiz update -a`      (staging is for specific changes, not a bump)
#   • touch main or MMSLive01      (promotion does that, via mms-deploy.sh)
#
# It DOES:
#   1. refresh + commit + push the `testing` branch  → test client pulls it
#      through packwiz-installer on next launch
#   2. sync released side=both/server mods into MMSTesting01/mods
#   3. apply overlay.list dev jars on top, on both the test server and the
#      test client instance
#
# Promote a validated fix with ./mms-promote.sh (or by hand: remove its slug
# from overlay.list, git checkout main && git merge testing, ./mms-deploy.sh).
set -e
cd ~/Documents/GitHub/mms-pack

# Symlink → /Volumes/AMP-Instances/instances/MMSTesting01/Minecraft/. Renamed
# from "MMSTesting01" on 2026-07-23; the old name no longer resolves.
TEST_SERVER_MODS="$HOME/Documents/GitHub/Server Testing/mods"
TEST_CLIENT_MODS="$HOME/Library/Application Support/PrismLauncher/instances/MMS Live II/minecraft/mods"

branch=$(git rev-parse --abbrev-ref HEAD)
if [ "$branch" != "testing" ]; then
    echo "!! not on 'testing' branch (on '$branch'). Run: git checkout testing" >&2
    exit 1
fi

# ship pending branch edits, then refresh the index and ship that too
git add -A
if git diff --cached --quiet; then
    echo "pack: no local changes to commit"
else
    git commit -m "testing pack changes"
fi
packwiz refresh
git add -A
git diff --cached --quiet || git commit -m "refresh index"
git push -u origin testing
echo "pack: testing branch pushed — test client updates on next launch"

echo "── server sync (MMSTesting01, released mods) ──"
if [ ! -d "$TEST_SERVER_MODS" ]; then
    echo "!! test server mods not found at $TEST_SERVER_MODS — skipping server sync." >&2
    exit 1
fi
python3 ./mms-server-sync.py "$TEST_SERVER_MODS"

echo "── dev-jar overlay ──"
./mms-overlay-apply.sh "$TEST_SERVER_MODS"
if [ -d "$TEST_CLIENT_MODS" ]; then
    ./mms-overlay-apply.sh "$TEST_CLIENT_MODS"
else
    echo "overlay: test client mods dir not found yet ($TEST_CLIENT_MODS)"
    echo "         (launch 'MMS Live II' once so packwiz creates it, then re-run.)"
fi

echo "── done. Restart MMSTesting01 if jars changed. ──"
