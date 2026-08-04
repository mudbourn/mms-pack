#!/bin/zsh
# mms-deploy-test — stage pack changes on the `testing` branch and push them to
# the test targets ONLY. Mirror of mms-deploy.sh for the staging lane.
#
# It deliberately does NOT:
#   • cut GitHub releases          (dev builds ride overlay.list, not the pack)
#   • run `packwiz update -a`      (staging is for specific changes, not a bump)
#   • touch main or MMSLive01      (promotion does that, via mms-deploy.sh)
#   • push the testing branch      (see below)
#
# It DOES:
#   1. commit pack edits to `testing` locally and refresh the index
#   2. sync released side=both/server mods into MMSTesting01/mods
#   3. apply overlay.list dev jars on top, on both the test server and the
#      dev client instance
#
# Transport note: this script used to `git push -u origin testing` and claim the
# test client would pull it. That never worked — there is no origin/testing, and
# the test clients' pre-launch step pointed at main. The dev client now installs
# from a local `packwiz serve` instead (./mms-dev-serve.sh), so the branch only
# has to exist locally. Keep that server running while testing.
#
# Promote a validated fix with ./mms-promote.sh (or by hand: remove its slug
# from overlay.list, git checkout main && git merge testing, ./mms-deploy.sh).
set -e
cd ~/Documents/GitHub/mms-pack

# Symlink → /Volumes/AMP-Instances/instances/MMSTesting01/Minecraft/. Renamed
# from "MMSTesting01" on 2026-07-23; the old name no longer resolves.
TEST_SERVER_MODS="$HOME/Documents/GitHub/Server Testing/mods"
TEST_CLIENT_MODS="$HOME/Library/Application Support/PrismLauncher/instances/MMS Dev/minecraft/mods"

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
echo "pack: testing branch updated — served to MMS Dev by ./mms-dev-serve.sh"

if ! curl -fsS --max-time 2 http://127.0.0.1:8080/pack.toml >/dev/null 2>&1; then
    echo "   note: nothing serving on 127.0.0.1:8080 — start ./mms-dev-serve.sh"
    echo "         before launching MMS Dev, or its pre-launch step will fail."
fi

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
    echo "overlay: dev client mods dir not found yet ($TEST_CLIENT_MODS)"
    echo "         (launch 'MMS Dev' once so packwiz creates it, then re-run.)"
fi

echo "── done. Restart MMSTesting01 if jars changed. ──"
