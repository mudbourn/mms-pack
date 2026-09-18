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
#
# Long forms (--main/--testing/--merge/--dev) work too.
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
WANT_BRANCH=""

for arg in "$@"; do
    # NOTE: --m and --M differ only in case, and they are not near-synonyms —
    # --m deploys to the LIVE server, --M merges and stops. zsh's case is
    # case-sensitive so they dispatch correctly, but see the warning below.
    case "$arg" in
        --d|--dev)     DEV=1 ;;
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
            echo "   usage: mms-deploy [--d] [--m|--t] [--M]" >&2
            echo "     --m main    --t testing    --M merge    --d dry run" >&2
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
    exec ./mms-promote.sh
fi

# ── lane selection ──
# Whatever branch the tree is actually on decides the target. No guard to trip
# over: being on testing is not an error, it just means the testing lane.
BRANCH=$(git rev-parse --abbrev-ref HEAD)
DEVFLAG=""
[ "$DEV" = "1" ] && DEVFLAG="--dev"

# ── release suite (mms-ship) ──
# Bring every MMS mod's GitHub release up to date with the work in its local
# repo BEFORE the pack update + server sync: diff each mod against what the
# lane's server runs, auto-bump repos with unreleased local work, build, and cut
# the releases. This is what makes `mms-deploy` the one-stop shop for shipping a
# whole suite of mod updates at once. mms-ship only cuts releases + repoints pack
# pins; the packwiz update -a and the server sync stay in the lane below (which
# then adopts what ship just released). It reuses mms-release.sh per repo, so the
# jar==version / never-walk-backward / pack-pin guards all still apply, and it
# prompts before cutting anything (we do not pass -y here).
#
# Under --d it runs `mms-ship -n` — a full rehearsal that shows the prod diff and
# the per-repo release plan without cutting anything. A non-zero exit (a failed
# or declined release) stops the deploy under `set -e`, before a half-released
# suite can reach the server.
SHIP_SERVER=""
case "$BRANCH" in
    main)    SHIP_SERVER="$HOME/Documents/GitHub/Server Prod/mods" ;;
    testing) SHIP_SERVER="$HOME/Documents/GitHub/Server Testing/mods" ;;
esac
if [ -n "$SHIP_SERVER" ] && [ -x ./mms-ship.py ]; then
    echo "── release suite (mms-ship, diff vs ${BRANCH} server) ──"
    SHIPFLAG=""
    [ "$DEV" = "1" ] && SHIPFLAG="-n"
    ./mms-ship.py --server "$SHIP_SERVER" $SHIPFLAG
fi

# ── drift pre-flight (informational, never blocks) ──
# Surface any repo whose source, pack pin, and latest release disagree before we
# ship. This does NOT reconcile anything — it is the heads-up so you notice, say,
# a mod you bumped locally but never released, or a release the pack hasn't
# picked up. Reconcile deliberately with `mms-release <repo>` (or --all).
if [ -x ./mms-repos.py ]; then
    if ! ./mms-repos.py drift --no-online >/dev/null 2>&1; then
        echo "── heads-up: version drift detected (pack pin vs source) ──"
        ./mms-repos.py drift --no-online 2>/dev/null | sed 's/^/   /' || true
        echo "   (informational only — deploying anyway; run ./mms-repos.py drift for the online view)"
        echo
    fi
fi

case "$BRANCH" in
    main)
        echo "── branch 'main' → PROD lane (MMSLive01) ──"
        exec ./mms-deploy-prod.sh $DEVFLAG ;;
    testing)
        echo "── branch 'testing' → TESTING lane (MMSTesting01) ──"
        exec ./mms-deploy-test.sh $DEVFLAG ;;
    *)
        echo "!! mms-deploy: on branch '$BRANCH', which has no lane." >&2
        echo "   Only 'main' (prod) and 'testing' (staging) can be deployed." >&2
        echo "   Nothing has been deployed anywhere." >&2
        echo >&2
        echo "   mms-deploy --m    # switch to main and deploy prod" >&2
        echo "   mms-deploy --t    # switch to testing and deploy staging" >&2
        exit 1 ;;
esac
