#!/bin/zsh
# mms-deploy — the single entry point for shipping the pack.
#
# There used to be three commands, and knowing which one to run meant knowing
# which branch you were on and which of them was gated to it. Now there is one:
# the BRANCH picks the lane, and flags cover everything else.
#
#   mms-deploy       on main    → deploy prod    (MMSLive01 + MMS Live)
#                    on testing → deploy testing (MMSTesting01 + MMS Dev)
#   mms-deploy --m   switch to MAIN, then deploy it      → touches the LIVE server
#   mms-deploy --t   switch to TESTING, then deploy it
#   mms-deploy --M   MERGE testing → main (strips quarantine), then STOP
#   mms-deploy --d   DRY RUN — rehearse whichever lane the branch selects
#   mms-deploy --p   PRUNE — the lane's server sync also removes jars that are
#                    no longer in the pack (instead of only reporting them).
#                    On main this prunes prod only; the Testing catch-up sync
#                    the prod lane runs never prunes (it would wipe the
#                    quarantine). Combine with --d to see what would go.
#   mms-deploy --y   YES — skip confirmation prompts: mms-ship's "Proceed with
#                    these releases?" (and mms-release's, via ship -y) and
#                    --M's "overlays still active, continue?" prompt. The
#                    branch, dirty-tree and flag-combination guards still apply.
#   mms-deploy --q   QUICK — skip `packwiz update -a` on the prod lane, which
#                    checks every third-party mod against Modrinth/CurseForge and
#                    is most of a deploy's wait. Your own mods still release,
#                    pin and sync as normal; third-party mods stay where they
#                    are until a deploy without --q. The testing lane never
#                    runs update -a, so --q changes nothing there.
#
# Long forms (--main/--testing/--merge/--dev/--prune/--yes/--quick) work too.
#
# ⚠ --m and --M differ ONLY in case, and they are opposites in blast radius:
#   --m deploys to the live server, --M merges and deploys nothing. If you mean
#   to merge and your shift key slips, you ship prod instead. When in doubt use
#   the long form --merge, or run --d first.
#
# --M is merge-only on purpose. It leaves you on main with the merge result so
# you can look at it; run `mms-deploy` after to actually ship.
#
# Any branch other than main/testing is refused. There is no sensible default
# lane for a WIP branch, and guessing one means a typo'd branch name writes to
# a real server.
#
# The lanes live in mms-deploy-prod.sh and mms-deploy-test.sh; the merge lives
# in mms-promote.sh. Call those directly only when debugging — they assume this
# script has already validated the branch.
set -e
cd ~/Documents/GitHub/mms-pack

DEV=0
MERGE=0
PRUNE=0
YES=0
QUICK=0
WANT_BRANCH=""

for arg in "$@"; do
    # NOTE: --m and --M differ only in case, and they are not near-synonyms —
    # --m deploys to the LIVE server, --M merges and stops. zsh's case is
    # case-sensitive so they dispatch correctly, but see the warning below.
    case "$arg" in
        --d|--dev)     DEV=1 ;;
        --p|--prune)   PRUNE=1 ;;
        --y|--yes)     YES=1 ;;
        --q|--quick)   QUICK=1 ;;
        --M|--merge)   MERGE=1 ;;
        --m|--main)    WANT_BRANCH="main" ;;
        --t|--testing) WANT_BRANCH="testing" ;;
        -h|--help)
            # 2..(line before `set -e`) — the whole header block, so adding a
            # flag to the comment above cannot silently truncate --help.
            sed -n "2,$(($(grep -n '^set -e' "$0" | head -1 | cut -d: -f1) - 1))p" "$0" \
                | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *)
            echo "!! mms-deploy: unknown argument '$arg'" >&2
            echo "   usage: mms-deploy [--d] [--p] [--y] [--q] [--m|--t] [--M]" >&2
            echo "     --m main    --t testing    --M merge    --d dry run    --p prune    --y skip prompts    --q skip third-party update" >&2
            echo "   run 'mms-deploy --help' for what each one does." >&2
            exit 2 ;;
    esac
done

# --M ends on main by definition, so pairing it with --m is redundant and
# harmless. Pairing it with --t asks for two different branches at once, which
# has no correct answer — refuse rather than silently picking one.
if [ "$MERGE" = "1" ] && [ "$WANT_BRANCH" = "testing" ]; then
    echo "!! --M and --t cannot be combined." >&2
    echo "   --M merges testing → main and leaves you on main;" >&2
    echo "   --t asks to end up on testing. Pick one." >&2
    exit 2
fi

# ── branch switching ──
# Only ever with a clean tree. `git checkout` carries uncommitted changes across
# branches rather than leaving them behind, so switching dirty would drag pack
# edits into the wrong lane — and the lane scripts commit whatever they find.
switch_to() {
    local target="$1"
    local current
    current=$(git rev-parse --abbrev-ref HEAD)
    [ "$current" = "$target" ] && return 0
    if [ -n "$(git status --porcelain)" ]; then
        echo "!! cannot switch $current → $target with uncommitted changes:" >&2
        git status --short >&2
        echo "   Commit or stash them first: git checkout would carry them over." >&2
        exit 1
    fi
    echo "── switching $current → $target ──"
    git checkout "$target"
}

[ -n "$WANT_BRANCH" ] && switch_to "$WANT_BRANCH"

# ── merge lane ──
if [ "$MERGE" = "1" ]; then
    if [ "$DEV" = "1" ]; then
        echo "!! --d does not apply to --M." >&2
        echo "   --M is already the safe half: it merges and stops without" >&2
        echo "   deploying. Run it, look at the result, then 'mms-deploy --d'." >&2
        exit 2
    fi
    switch_to "main"
    PROMOTEFLAG=""
    [ "$YES" = "1" ] && PROMOTEFLAG="-y"
    exec ./mms-promote.sh $PROMOTEFLAG
fi

# ── lane selection ──
# Whatever branch the tree is actually on decides the target. No guard to trip
# over: being on testing is not an error, it just means the testing lane.
BRANCH=$(git rev-parse --abbrev-ref HEAD)
DEVFLAG=""
[ "$DEV" = "1" ] && DEVFLAG="--dev"
PRUNEFLAG=""
[ "$PRUNE" = "1" ] && PRUNEFLAG="--prune"

# ── release suite, stage 1: plan (mms-ship --plan-out) ──
# Bring every MMS mod's GitHub release up to date with the work in its local
# repo BEFORE the server sync: diff each mod against what the lane's server
# runs and decide which repos need a bump or a release. This is what makes
# `mms-deploy` the one-stop shop for shipping a whole suite of mod updates.
#
# Only the PLAN happens here: the diff table, the resource pack mirror, and the
# one "Proceed with these releases?" prompt (skipped under --y). The plan goes
# to a file the lane picks up through MMS_SHIP_PLAN. The lane then runs the
# releases in parallel, one task per repo, next to its own packwiz work, waits
# for all of it, and pins the pack once (see "parallel phase" in each lane).
# Asking here keeps the question at the top, before anything is in flight.
#
# Under --d the plan is marked dry, so the lane runs `mms-release -n` per repo
# and cuts nothing. A non-zero exit (a declined plan) stops the deploy under
# `set -e`.
SHIP_SERVER=""
case "$BRANCH" in
    main)    SHIP_SERVER="$HOME/Documents/GitHub/Server Prod/mods" ;;
    testing) SHIP_SERVER="$HOME/Documents/GitHub/Server Testing/mods" ;;
esac
if [ -n "$SHIP_SERVER" ] && [ -x ./mms-ship.py ]; then
    echo "── release plan (mms-ship, diff vs ${BRANCH} server) ──"
    SHIPFLAG=""
    [ "$DEV" = "1" ] && SHIPFLAG="-n"
    [ "$DEV" != "1" ] && [ "$YES" = "1" ] && SHIPFLAG="-y"
    export MMS_SHIP_PLAN="$(mktemp -t mms-ship-plan)"
    ./mms-ship.py --server "$SHIP_SERVER" $SHIPFLAG --plan-out "$MMS_SHIP_PLAN"
fi
# The drift heads-up that used to print here now prints in the lane, after the
# releases and the pin. Up here it would list every repo the plan above is
# about to release.

# --y reaches the lanes through the environment, so their packwiz calls
# (update -a and the per-mod adopts) skip their "Do you want to update?" prompts.
export MMS_YES="$YES"
# --q likewise: the prod lane skips `packwiz update -a`.
export MMS_QUICK="$QUICK"

case "$BRANCH" in
    main)
        echo "── branch 'main' → PROD lane (MMSLive01) ──"
        exec ./mms-deploy-prod.sh $DEVFLAG $PRUNEFLAG ;;
    testing)
        echo "── branch 'testing' → TESTING lane (MMSTesting01) ──"
        exec ./mms-deploy-test.sh $DEVFLAG $PRUNEFLAG ;;
    *)
        echo "!! mms-deploy: on branch '$BRANCH', which has no lane." >&2
        echo "   Only 'main' (prod) and 'testing' (staging) can be deployed." >&2
        echo "   Nothing has been deployed anywhere." >&2
        echo >&2
        echo "   mms-deploy --m    # switch to main and deploy prod" >&2
        echo "   mms-deploy --t    # switch to testing and deploy staging" >&2
        exit 1 ;;
esac
