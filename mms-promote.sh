#!/bin/zsh
# mms-promote — promote validated testing-branch changes to production.
#
#   1. warn if any dev-jar overlays are still active (those must be released,
#      not merged — they are not tracked in the pack)
#   2. merge `testing` → `main`
#   3. strip quarantined mods back out on the main side (see quarantine.txt)
#   4. hand off to mms-deploy.sh, which cuts GitHub releases for any local mod
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

# ── quarantine strip ──
# The testing pack deliberately ships mods prod must never see (Aerial Hell and
# friends): the dev client has to install them or Server Testing kicks it at
# login for unknown registry entries. The merge above drags their metafiles onto
# main, so remove them again here — this is the ONLY thing standing between the
# quarantine and the live world, so it runs before mms-deploy.sh, not after.
#
# The deletion lands on main only. Because testing never sees it, later promotes
# keep them deleted with no conflict — unless testing edits a quarantined
# metafile (a version bump), which surfaces as a modify/delete conflict. That is
# the correct loud failure, not a bug.
stripped=()
while IFS= read -r slug; do
    slug="${${slug%%\#*}## }"; slug="${slug%% }"
    [ -z "$slug" ] && continue
    meta="mods/${slug}.pw.toml"
    if [ -f "$meta" ]; then
        git rm -q "$meta"
        stripped+=("$slug")
    fi
done < quarantine.txt

if [ ${#stripped[@]} -gt 0 ]; then
    echo "── quarantine: removed ${#stripped[@]} mod(s) from the prod pack ──"
    printf '     %s\n' "${stripped[@]}"
    packwiz refresh
    git add -A
    git commit -q -m "strip quarantined mods from prod pack"
else
    echo "quarantine: nothing to strip"
fi

# Belt and braces: prove the quarantine is actually gone before prod is touched.
# A typo'd slug in quarantine.txt would silently strip nothing above.
for slug in $(grep -vE '^\s*#|^\s*$' quarantine.txt); do
    if [ -f "mods/${slug}.pw.toml" ]; then
        echo "!! quarantined mod '$slug' is STILL in the prod pack — aborting." >&2
        echo "   Prod deploy not run. Investigate before re-promoting." >&2
        exit 1
    fi
done

echo "── handing off to mms-deploy.sh (release + prod sync) ──"
./mms-deploy.sh

echo "── promoted. Return to staging with: git checkout testing && git merge main ──"
