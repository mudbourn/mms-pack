#!/bin/zsh
# mms-promote — promote validated testing-branch changes to production.
#
#   1. warn if any dev-jar overlays are still active (those must be released,
#      not merged — they are not tracked in the pack)
#   2. merge `testing` → `main`
#   3. hand off to mms-deploy.sh, which cuts GitHub releases for any local mod
#      builds ahead of their release, updates main, and syncs MMSLive01
#
# Run from a clean tree.
set -e
cd ~/Documents/GitHub/mms-pack

# active overlays are dev builds with no release — surface them before promoting
active=$(grep -vE '^\s*#|^\s*$' overlay.list 2>/dev/null || true)
if [ -n "$active" ]; then
    echo "!! overlay.list still lists dev jars under test:" >&2
    echo "$active" | sed 's/^/     /' >&2
    echo "   Promotion cuts their real release via mms-deploy (release reconcile)." >&2
    echo "   After a clean prod deploy, clear them from overlay.list." >&2
    printf "   Continue merging testing → main? [y/N] " >&2
    read -r ans
    [ "$ans" = "y" ] || [ "$ans" = "Y" ] || { echo "aborted."; exit 1; }
fi

git checkout main
git pull --ff-only
git merge --no-ff testing -m "promote testing → main"

echo "── handing off to mms-deploy.sh (release + prod sync) ──"
./mms-deploy.sh

echo "── promoted. Return to staging with: git checkout testing && git merge main ──"
