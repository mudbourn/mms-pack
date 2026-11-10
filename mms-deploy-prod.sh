#!/bin/zsh
# mms-deploy — update the pack, publish to clients, and sync shared mods to the server.
#
# 1. commit + push             any pending local changes ship first, untangled
#                              from whatever packwiz is about to touch
# 2. PARALLEL PHASE            two things at once, then wait for both:
#      mod releases            the plan mms-deploy.sh confirmed, one task per
#                              repo (mms-ship --run). Cuts releases only.
#      packwiz update -a       bump every third-party mod to latest
# 3. pin + release reconcile   one after the other, since each rewrites the
#                              index: point the pack at the releases just cut
#                              (mms-ship --pin), then ADOPT any release GitHub
#                              has that the pack is still behind (you pushed +
#                              released it yourself).
# 4. packwiz refresh           rebuild index, once
# 5. ./update-title.sh         re-apply preserve flags
# 6. commit + push             the packwiz changes; clients pick both up on
#                              next Prism launch
# 7. PARALLEL PHASE            three things at once, then wait for all:
#      server sync (prod)      diff side=both/server mods against MMSLive01/mods,
#                              copy new jars in, remove superseded versions
#      server sync (testing)   same, against MMSTesting01/mods, but read-only
#                              about anything the test lane owns — see
#                              testing-hold.txt. Never prunes, never fatal.
#      octane rebuild          the low-end branch, from the main just pushed.
#                              Never fatal.
#
# 0. client sweep (preflight)  remove hand-dropped jars in the live instance that
#                              duplicate a packwiz-managed mod id. Runs FIRST, so
#                              a client that cannot boot is caught before a
#                              release is cut rather than after.
#
# --dev  rehearsal. Runs every step above and reports what a real deploy would
#        do, but pushes nothing, cuts no release, and writes to no server. This
#        is not the test lane (that is mms-deploy-test.sh) — it is prod's own
#        pipeline with the irreversible half disarmed, so a bad release or a
#        netdrift failure is caught before it is permanent rather than after.
#
#        packwiz still rewrites the working tree (update -a, refresh,
#        update-title), so --dev requires a clean tree and restores it at the
#        end. That is why it refuses to start on a dirty one: the restore is a
#        hard reset and it must not be able to eat uncommitted work.
set -e
cd ~/Documents/GitHub/mms-pack
source ./mms-deploy-phase.sh

# ── NOT THE ENTRY POINT ──
# This is the prod LANE, invoked by mms-deploy.sh. Run `mms-deploy` instead —
# it parses flags, picks the lane from the branch, and calls this.
DEV=0
PRUNEFLAG=""
for arg in "$@"; do
    case "$arg" in
        --dev)   DEV=1 ;;
        --prune) PRUNEFLAG="--prune" ;;
    esac
done

# ── branch guard (belt and braces) ──
# mms-deploy.sh routes by branch and will only ever call this on `main`, so in
# normal use this never fires. It stays because the consequence of being wrong
# is unbounded: the prod server sync reads the WORKING TREE (mms-server-sync.py
# defaults pack_dir to "."), not the `main` branch, and nothing downstream
# re-checks which branch that tree is on. Running this lane from `testing`
# installs the testing index — quarantine and all — straight onto prod, with no
# prune to take it back off afterwards.
#
# That is exactly what happened on 2026-08-04: Aerial Hell, DDD, Mutant
# Monsters and Useless Reptile all landed on MMSLive01, which both broke client
# logins (registry mismatch against the `main` pack) and put unstable worldgen
# into the live world.
#
# Cheap to check, so check it — a dispatcher bug must not be able to reach prod.
BRANCH=$(git rev-parse --abbrev-ref HEAD)
if [ "$BRANCH" != "main" ]; then
    echo "!! mms-deploy-prod: refusing to run from '$BRANCH' — prod lane is main-only." >&2
    echo "   This is a guard against a dispatcher bug; you should not see it." >&2
    echo "   Use 'mms-deploy' rather than calling this lane directly." >&2
    exit 1
fi

# Belt and braces: the branch check above is the real guard, but a quarantined
# mod reaching the prod index by any other route (a bad merge, a hand edit)
# must not reach the server either. mms-promote.sh already proves this after
# its strip; prove it again here, at the last point before prod is touched.
for slug in $(grep -vE '^\s*#|^\s*$' quarantine.txt); do
    if grep -q "mods/$slug.pw.toml" index.toml; then
        echo "!! quarantined mod '$slug' is in the prod pack index — aborting." >&2
        echo "   See quarantine.txt. Nothing has been pushed or synced." >&2
        exit 1
    fi
done

# run a mutating command, or announce it, depending on the mode
run() {
    if [ "$DEV" = "1" ]; then
        echo "[dry-run] would: $*"
    else
        "$@"
    fi
}

if [ "$DEV" = "1" ]; then
    if [ -n "$(git status --porcelain)" ]; then
        echo "!! --dev needs a clean tree: it lets packwiz rewrite the working" >&2
        echo "   tree and then hard-restores it, which would destroy these edits:" >&2
        git status --short >&2
        exit 1
    fi
    START_REF=$(git rev-parse HEAD)
    # restore on ANY exit path — a netdrift failure or a ctrl-C must not leave
    # the tree holding a half-applied packwiz update that a later real deploy
    # would then commit blind
    trap 'echo "── [dry-run] restoring working tree to $START_REF ──"; \
          git reset --hard "$START_REF" >/dev/null; git clean -fd >/dev/null; \
          echo "   tree restored; nothing was pushed, released, or synced."' EXIT
    echo "══ DRY RUN — no push, no release, no server writes ══"
fi

LIVE_CLIENT="$HOME/Library/Application Support/PrismLauncher/instances/MMS Live/minecraft"
DRYFLAG=""
[ "$DEV" = "1" ] && DRYFLAG="--dry-run"
# mms-deploy --y exports MMS_YES=1: packwiz then applies its update list
# without asking, same as every other prompt --y skips.
PWYES=""
[ "$MMS_YES" = "1" ] && PWYES="-y"

# ── client sweep (preflight) ──
# packwiz-installer only manages files listed in packwiz.json, so a jar copied
# in by hand is never cleaned up — and two jars sharing a Fabric mod id stop the
# client booting at all. The server side has always deduped by mod id; this is
# the missing client-side half. Overlay dev jars are exempt (see the script).
python3 ./mms-client-sweep.py "$LIVE_CLIENT" $DRYFLAG

# ship pending local edits before packwiz mixes its changes in with them.
# --dev guarantees a clean tree, so this branch has nothing to do there.
git add -A
if git diff --cached --quiet; then
    echo "pack: no local changes to commit"
else
    run git commit -m "local pack changes"
    run git push
    echo "pack: local changes pushed"
fi

# ── parallel phase: mod releases ‖ third-party update ──
# The releases only build, push and cut GitHub releases; packwiz update -a only
# rewrites the pack. Neither reads what the other writes, so they run together.
# The releases go to the background and log to a file. packwiz keeps the
# terminal, because it asks before applying its update list.
#
# packwiz may or may not see a release cut while it runs. That does not matter:
# the pin below repoints every mod that was released, whatever packwiz saw.
if [ -n "$MMS_SHIP_PLAN" ] && [ -s "$MMS_SHIP_PLAN" ]; then
    if [ "$MMS_QUICK" = "1" ]; then
        echo "── mod releases (--q: packwiz update -a skipped) ──"
    else
        echo "── parallel: mod releases (background) + packwiz update -a ──"
    fi
elif [ "$MMS_QUICK" = "1" ]; then
    echo "── --q: packwiz update -a skipped (third-party mods unchanged) ──"
else
    echo "── packwiz update -a ──"
fi
ship_start
PW_RC=0
# --q (MMS_QUICK=1): skip the third-party bump. The pin below repoints every
# released MMS mod on its own, so a quick deploy still ships them.
[ "$MMS_QUICK" = "1" ] || packwiz $PWYES update -a || PW_RC=$?
# A release in flight cannot be taken back, so wait for all of them before
# acting on a packwiz failure.
[ -n "$SHIP_PID" ] && echo "── waiting for mod releases ──"
ship_wait

echo "── pin released mods ──"
ship_pin
if [ "$PW_RC" -ne 0 ]; then
    echo "!! packwiz update -a failed (exit $PW_RC). Nothing pushed or synced." >&2
    exit "$PW_RC"
fi
if [ "$SHIP_RC" -ne 0 ] || [ "$PIN_RC" -ne 0 ]; then
    # Same stop as before the rework: a half-released suite must not reach the
    # server. What did release is pinned in the working tree, uncommitted.
    echo "!! a mod release or its pack pin failed — see above. Nothing synced." >&2
    exit 1
fi
drift_report

echo "── release reconcile (local mods) ──"
# Runs after the parallel phase so it also adopts anything a release above
# made visible that the pin did not cover.
# Two ways one of our mods gets a new version, and this handles both:
#
#   A. You released it yourself — pushed the repo to main and let its release.yml
#      (or `gh release create`) cut the tag. CI bumps gradle.properties and
#      commits on origin, so your LOCAL clone is now behind. We must not try to
#      re-release or push from here. Instead: if GitHub already has a release the
#      pack is behind, just `packwiz update` to ADOPT it. This needs nothing
#      local — the repo need not even be checked out.
#
#   B. You built locally and want the deploy to publish it. Only when the local
#      build is strictly ahead of BOTH the pack pin AND the newest GitHub release
#      do we commit+push the repo and cut the release. That upper bound is what
#      keeps case A from ever colliding with a release you already made.
#
# So: adopt-first, release-only-if-genuinely-unreleased. `packwiz update -a`
# below would eventually adopt too, but doing it here gives clear per-mod
# messaging and absorbs the releases-API lag with a retry.
#
# The latest-release lookups are fetched up front, all at once: one gh round
# trip per mod, one at a time, was most of this step's wait. The loop below
# still acts on them in order.
RELEASE_TAGS=$(mktemp -d)
for toml in mods/*.pw.toml; do
    slug=$(grep -m1 '^slug = "mudbourn/' "$toml" | sed 's|.*mudbourn/||; s|"||')
    [ -z "$slug" ] && continue
    gh release view --repo "mudbourn/$slug" --json tagName -q .tagName \
        >"$RELEASE_TAGS/$slug" 2>/dev/null &
done
wait
for toml in mods/*.pw.toml; do
    slug=$(grep -m1 '^slug = "mudbourn/' "$toml" | sed 's|.*mudbourn/||; s|"||')
    [ -z "$slug" ] && continue
    base="${${toml:t}%.pw.toml}"
    tag=$(grep -m1 '^tag = ' "$toml" | sed 's/tag = "v\{0,1\}//; s/"//')

    # ── case A: adopt a release that already exists on GitHub ──
    # Read-only, so it runs under --dev too. Empty when there is no release or gh
    # is offline — in which case we simply fall through to the local path.
    latest=$(sed 's/^v//' "$RELEASE_TAGS/$slug" 2>/dev/null)
    if [ -n "$latest" ] && [ -n "$tag" ] && [ "$latest" != "$tag" ] \
       && [ "$(printf '%s\n%s\n' "$tag" "$latest" | sort -V | tail -1)" = "$latest" ]; then
        echo "→ $slug: released v$latest is ahead of pack v$tag — adopting (you released it)"
        if [ "$DEV" = "1" ]; then
            echo "  [dry-run] would packwiz update $base to v$latest"
        else
            for attempt in 1 2 3 4 5; do
                packwiz $PWYES update "$base"
                grep -q "^tag = \"v$latest\"" "$toml" && break
                echo "   (release not visible yet, retrying in 5s...)"
                sleep 5
            done
            grep -q "^tag = \"v$latest\"" "$toml" \
                || echo "!! $slug: pack still at v$tag after adopting v$latest — check branch = \"main\" in $toml and re-run." >&2
        fi
        continue
    fi

    # ── case B: cut a release for genuinely-unreleased local work ──
    repo="$HOME/Documents/GitHub/$slug"
    [ -d "$repo/.git" ] || continue
    # (N) is the NULL_GLOB qualifier: expand to nothing when the repo has never
    # been built, instead of erroring. The 2>/dev/null only ever covered ls's
    # own stderr — zsh raises "no matches found" at glob-expansion time, before
    # ls runs, so an unbuilt repo (Vertigo-ScalableLux-Compat-Backports has no
    # build/libs at all) printed a scary error on every deploy. Harmless — jar
    # came back empty and the next line skipped the repo — but it looked like a
    # failure, so it hid whether release reconcile had actually done anything.
    # Collect into an array first. Globbing straight into `ls` is not safe here:
    # with no (N) zsh aborts the expansion ("no matches found") for a repo that
    # has never been built, and WITH (N) the pattern vanishes and `ls -t` falls
    # back to listing the CWD — which hands back a pack file as though it were a
    # build artifact. The array makes "nothing built" an explicit empty case.
    jars=("$repo"/build/libs/*.jar(N))
    [ ${#jars[@]} -eq 0 ] && continue
    jar=$(ls -t "${jars[@]}" | grep -v -- -sources | head -1)
    [ -z "$jar" ] && continue
    ver=$(python3 -c "import json,zipfile,sys; print(json.loads(zipfile.ZipFile(sys.argv[1]).read('fabric.mod.json'))['version'])" "$jar" 2>/dev/null)
    # `tag` is the pack pin from the top of the loop. Case A already adopted (and
    # skipped) anything where a GitHub release outran it, so here the newest
    # release is at or behind `tag` — meaning "ahead of the pin" also means ahead
    # of every existing release, and cutting v$ver can never duplicate one.
    { [ -z "$ver" ] || [ -z "$tag" ] || [ "$ver" = "$tag" ]; } && continue
    # act only when the local build is strictly newer than the released tag
    [ "$(printf '%s\n%s\n' "$tag" "$ver" | sort -V | tail -1)" = "$ver" ] || continue
    echo "→ $slug: local build $ver ahead of released ${latest:-none}/pack v$tag — releasing v$ver"
    if [ "$DEV" = "1" ]; then
        echo "  [dry-run] would commit+push $slug and cut release v$ver with $(basename "$jar")"
        # The retry loop below waits on a release that will never exist here,
        # so skip it rather than burn 25s of sleeps and print a false warning.
        echo "  [dry-run] would then point $toml at v$ver"
        continue
    fi
    (
        cd "$repo"
        git add -A
        git diff --cached --quiet || git commit -m "v$ver"
        git push
        gh release view "v$ver" >/dev/null 2>&1 \
            || gh release create "v$ver" "$jar" --title "v$ver" --notes "released by mms-deploy"
    )
    # the releases API is eventually consistent — a just-created release can
    # be missing from the list for a few seconds, so retry until the toml
    # actually points at the new tag
    for attempt in 1 2 3 4 5; do
        packwiz $PWYES update "${${toml:t}%.pw.toml}"
        grep -q "^tag = \"v$ver\"" "$toml" && break
        echo "   (release not visible yet, retrying in 5s...)"
        sleep 5
    done
    if ! grep -q "^tag = \"v$ver\"" "$toml"; then
        echo "!! $slug: pack still points at v$tag after release v$ver — re-run mms-deploy" >&2
    fi
done

packwiz refresh
./update-title.sh

# An empty file cannot be fetched by the installer, which then warns on every
# member's launch. Globs cannot match "empty", so each one needs its own line
# in .packwizignore. Warn here; do not block a deploy over it.
EMPTY=$(grep -B1 '^hash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"' index.toml \
        | sed -n 's/^file = "\(.*\)"$/\1/p')
if [ -n "$EMPTY" ]; then
    echo "?? empty file(s) in the index — clients will warn. Add to .packwizignore:" >&2
    echo "$EMPTY" | sed 's/^/     /' >&2
fi

git add -A
if git diff --cached --quiet; then
    echo "pack: no mod updates to commit"
else
    if [ "$DEV" = "1" ]; then
        echo "[dry-run] would commit + push these pack changes:"
        git diff --cached --stat
    else
        git commit -m "update mods"
        git push
        echo "pack: pushed — clients update on next launch"
    fi
fi

rm -rf "$RELEASE_TAGS"

# ── octane (low-end PC branch) ──
# Rebuild octane from the main just pushed, so it never lags behind. Client
# only: no server runs octane. A failure here must not block the server sync.
#
# It builds in its own git worktree from the pushed commit and never reads the
# server folders, so it runs in the background alongside both server syncs.
# Its output is held and printed after theirs.
OCTANE_LOG=$(mktemp)
if [ "$DEV" = "1" ]; then
    ./mms-octane-build.sh --dry-run >"$OCTANE_LOG" 2>&1 &
else
    ./mms-octane-build.sh >"$OCTANE_LOG" 2>&1 &
fi
OCTANE_PID=$!

echo "── server sync (Server Prod / MMSLive01) ──"
# Symlink → /Volumes/AMP-Instances/instances/MMSLive01/Minecraft/. Renamed from
# "MMSLive01" on 2026-07-23; the old name is gone, so this path is the only one
# that resolves. A dangling link (share unmounted) fails the -d test below just
# as a missing one does.
SERVER_MODS="$HOME/Documents/GitHub/Server Prod/mods"
if [ ! -d "$SERVER_MODS" ]; then
    echo "!! server mods folder not mounted at $SERVER_MODS — skipping server sync." >&2
    if [ "$DEV" = "1" ]; then
        # A rehearsal that aborts here has still told you about the release and
        # pack half, which is most of what it is for. Do not fail it — but do
        # not let it read as a clean pass either.
        echo "?? [dry-run] server sync NOT rehearsed — mount the share to check it." >&2
    else
        echo "!! Mount the AMP share and re-run, or the server will drift out of sync." >&2
        exit 1
    fi
fi
# Shared with the test lane (mms-deploy-test.sh) — one implementation, so a
# fix to the never-downgrade or supersede rules cannot land on only one of
# the two servers. This was an inline copy that had already drifted from
# mms-server-sync.py by the time it was noticed.
# Guarded because --dev tolerates an unmounted share; a real deploy exited above.
#
# The two syncs write to different folders and only read the pack, so Testing's
# (below) runs in the background alongside prod's. Its output is held and
# printed after prod's, so the log still reads prod-then-testing, and a failed
# prod sync waits for it before stopping the deploy.
TEST_SERVER_MODS="$HOME/Documents/GitHub/Server Testing/mods"
TEST_PID=""
if [ -d "$TEST_SERVER_MODS" ]; then
    TEST_LOG=$(mktemp)
    python3 ./mms-server-sync.py "$TEST_SERVER_MODS" . --hold testing-hold.txt $DRYFLAG \
        >"$TEST_LOG" 2>&1 &
    TEST_PID=$!
fi
PROD_RC=0
if [ -d "$SERVER_MODS" ]; then
    # --prune (mms-deploy --p) applies here only; the Testing sync above never
    # prunes, for the quarantine reason given below.
    python3 ./mms-server-sync.py "$SERVER_MODS" $DRYFLAG $PRUNEFLAG || PROD_RC=$?
fi

echo "── server sync (Server Testing / MMSTesting01) ──"
# Testing used to be synced only by mms-deploy-test.sh, on the `testing` branch.
# In practice that lane is paused, so every prod deploy left the test server a
# little further behind until it was no longer a useful rehearsal of prod. This
# brings it along with released mod updates.
#
# It is deliberately weaker than the prod sync:
#   • --hold testing-hold.txt   mods the test lane owns are never touched
#   • no --prune                a jar that is not in the pack is REPORTED, never
#                               removed. The unstable quarantine (Aerial Hell,
#                               DDD, Mutant Monsters, Useless Reptile) lives on
#                               Testing and not in prod's pack, so a prune here
#                               would wipe the entire quarantine.
#   • non-fatal                 prod has already been synced by this point.
#                               Testing being unmounted must not fail the deploy
#                               or leave prod half-deployed.
if [ -z "$TEST_PID" ]; then
    echo "?? test server mods not mounted at $TEST_SERVER_MODS — skipped." >&2
    echo "   (prod is already synced; re-run when the share is up to catch Testing up.)" >&2
else
    wait "$TEST_PID" && TEST_RC=0 || TEST_RC=$?
    cat "$TEST_LOG"
    rm -f "$TEST_LOG"
    [ "$TEST_RC" -eq 0 ] || echo "?? testing sync reported problems — prod is unaffected." >&2
fi

echo "── octane rebuild ──"
wait "$OCTANE_PID" && OCTANE_RC=0 || OCTANE_RC=$?
cat "$OCTANE_LOG"
rm -f "$OCTANE_LOG"
if [ "$OCTANE_RC" -ne 0 ]; then
    if [ "$DEV" = "1" ]; then
        echo "?? octane dry run failed — prod is unaffected." >&2
    else
        echo "?? octane rebuild failed — prod is unaffected; rerun ./mms-octane-build.sh." >&2
    fi
fi
[ "$PROD_RC" -eq 0 ] || { echo "!! prod server sync failed (exit $PROD_RC)." >&2; exit "$PROD_RC"; }

# Gate the deploy on network-path drift, after the sync so it checks the state
# the server will actually run. A mod that patches packet framing on only one
# side, or two mods patching the same framing class, desyncs the byte stream —
# the client lands mid-packet and drops with a DecoderException. That failure
# looks like a network problem and cost a long investigation on 2026-07-26.
# Accepted overlaps live in netdrift-allow.txt; NOTE-level drift never blocks.
#
# Captured rather than piped: this script has no pipefail, so a pipeline would
# report grep's status and the gate would never fire.
#
# Read-only, so it runs unchanged under --dev — and it is the single most
# valuable thing to rehearse, since a desync here is what a dry run exists to
# catch before the jars are on the server rather than after.
if [ ! -d "$SERVER_MODS" ]; then
    echo "?? netdrift check skipped — $SERVER_MODS not mounted." >&2
else
    NETDRIFT_OUT="$(python3 ./mms-netdrift-check.py "$SERVER_MODS" .)" && NETDRIFT_RC=0 || NETDRIFT_RC=$?
    # NOTE lines are baggage-level drift and are intentionally not shown here.
    echo "$NETDRIFT_OUT" | grep -vE '^NOTE' || true
    if [ "$NETDRIFT_RC" -ne 0 ]; then
        echo "!! network drift check failed — see the OVERLAP/HIGH lines above." >&2
        echo "!! Resolve the conflict, or record a reviewed overlap in netdrift-allow.txt." >&2
        exit 1
    fi
fi

if [ "$DEV" = "1" ]; then
    echo
    echo "══ dry run complete — rerun without --dev to deploy for real ══"
fi
