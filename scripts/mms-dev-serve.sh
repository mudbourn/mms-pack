#!/bin/zsh
. "$(dirname "$0")/paths.local.env" || { echo "!! missing scripts/paths.local.env (copy scripts/paths.env.example)" >&2; exit 1; }
# mms-dev-serve — serve the local `testing` checkout to the MMS Dev client.
#
# The dev client's pre-launch step fetches http://127.0.0.1:8080/pack.toml, so
# pack edits reach it with no commit, no push, and no GitHub round trip: edit,
# `packwiz refresh`, relaunch. That is why the dev lane does not need an
# origin/testing branch (there isn't one) the way mms-deploy-test.sh assumed.
#
# Leave this running in its own terminal for the whole dev session.
set -e
cd "$MMS_PACK_DIR"

branch=$(git rev-parse --abbrev-ref HEAD)
if [ "$branch" != "testing" ]; then
    echo "!! serving the '$branch' branch, not 'testing'." >&2
    echo "   The dev client will install whatever is checked out right now." >&2
    printf "   Continue? [y/N] " >&2
    read -r ans
    [ "$ans" = "y" ] || [ "$ans" = "Y" ] || { echo "aborted."; exit 1; }
fi

# refresh so the index matches the working tree before anyone installs from it
packwiz --pack-file pack/pack.toml refresh

echo "── serving $branch on http://127.0.0.1:8080/pack.toml (ctrl-C to stop) ──"
echo "   After editing the pack, run 'packwiz refresh' and relaunch MMS Dev."
exec packwiz --pack-file pack/pack.toml serve --port 8080
