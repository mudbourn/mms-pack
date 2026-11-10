# mms-deploy-phase.sh — the release steps both deploy lanes share (zsh).
# Sourced by mms-deploy-prod.sh and mms-deploy-test.sh; not run on its own.
#
# mms-deploy.sh plans the releases (mms-ship --plan-out) and hands the plan
# over in MMS_SHIP_PLAN. A lane called directly has no plan, and every function
# here is then a no-op.

SHIP_PID=""
SHIP_LOG=""

# Start the planned releases in the background: mms-ship --run fans out one
# task per repo and touches nothing in the pack index, so the lane is free to
# run packwiz next to it. Output goes to a log, because the lane may be holding
# the terminal for a packwiz prompt at the same time.
ship_start() {
    [ -n "$MMS_SHIP_PLAN" ] && [ -s "$MMS_SHIP_PLAN" ] || return 0
    SHIP_LOG=$(mktemp -t mms-ship-log)
    ./scripts/mms-ship.py --run "$MMS_SHIP_PLAN" >"$SHIP_LOG" 2>&1 &
    SHIP_PID=$!
}

# Wait for every release task. Prints what they have logged so far and follows
# the rest live. Sets SHIP_RC; never exits, so the caller decides what a failed
# release means once its own parallel work is also accounted for.
ship_wait() {
    SHIP_RC=0
    [ -n "$SHIP_PID" ] || return 0
    tail -n +1 -f "$SHIP_LOG" &
    local tail_pid=$!
    wait "$SHIP_PID" || SHIP_RC=$?
    sleep 1                      # let tail drain the last block
    kill "$tail_pid" 2>/dev/null
    wait "$tail_pid" 2>/dev/null || true
    rm -f "$SHIP_LOG"
    SHIP_PID=""
}

# Point the pack at whatever was released, one metafile at a time (packwiz
# rewrites index.toml on each). Runs even when some releases failed: the ones
# that are out are permanent, and the pack should say so. Sets PIN_RC.
ship_pin() {
    PIN_RC=0
    [ -n "$MMS_SHIP_PLAN" ] && [ -s "$MMS_SHIP_PLAN" ] || return 0
    ./scripts/mms-ship.py --pin "$MMS_SHIP_PLAN" || PIN_RC=$?
    rm -f "$MMS_SHIP_PLAN"
}

# Drift heads-up (informational, never blocks). Surfaces any repo whose source,
# pack pin and latest release still disagree after the releases and the pin.
# Reconcile deliberately with `mms-release <repo>` (or --all).
drift_report() {
    [ -x ./scripts/mms-repos.py ] || return 0
    local out
    if ! out="$(./scripts/mms-repos.py drift --no-online 2>/dev/null)"; then
        echo "── heads-up: version drift detected (pack pin vs source) ──"
        echo "$out" | sed 's/^/   /'
        echo "   (informational only — deploying anyway; run ./scripts/mms-repos.py drift for the online view)"
        echo
    fi
}
