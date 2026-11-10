#!/usr/bin/env python3
"""mms-ship — one pass that brings every MMS mod's RELEASE up to date with the
work sitting in its local repo, so a single deploy can ship a whole suite of
mod updates at once.

This is the "release half" of a deploy, pulled out so it can be run on its own
and so mms-deploy has one well-tested thing to call instead of an inline loop.
It does NOT touch any server or run packwiz update -a — that stays in
mms-deploy, which calls this first and then syncs. Run `mms-deploy` for the
full pipeline; run this directly when you only want to cut the releases.

What it does, per repo, in bottom-up build order (a library releases before the
mods that includeBuild it):

  1. DIFF against prod. It reads the actual jar versions running on the live
     server (Server Prod/mods by default) and lines each mod up:
         repo    prod_ver    source_ver    latest_release    decision
     so you can see, before anything happens, exactly what is ahead of what.

  2. Decide what each repo needs:
       • BUMP   — the repo has local work (a dirty tree or unpushed commits)
                  that its source version does not yet reflect. mms-ship stamps
                  a new version (default: patch; override globally with --bump
                  or per repo as `repo:minor`), builds, and releases it. This is
                  the auto-bump the old flow never did: you change code, forget
                  to bump, and it bumps for you rather than shipping the old
                  version under a stale number.
       • RELEASE— source is already ahead of every existing release (you bumped
                  deliberately, or it has never been released). Build and cut
                  the release at the source version, no bump.
       • ADOPT  — a release already exists that prod/the pack is merely behind
                  on. Nothing to build or cut; reported and left for the deploy's
                  own `packwiz update` to pick up. mms-ship does not act here so
                  it never has to reimplement the adopt path.
       • IN SYNC— source, latest release and prod all agree. Skipped.

  3. For every BUMP/RELEASE, hand the repo to mms-release.sh, which owns the
     irreversible part: it rewrites gradle.properties (for a bump), builds,
     verifies the built jar actually carries the target version, refuses to walk
     a release backwards, and cuts the tagged GitHub release. mms-ship never
     re-implements any of that; it only decides the set and the bump level.

     The releases run AT THE SAME TIME, one task per repo, and mms-ship waits
     for all of them. Two rules bound that:
       • build order still holds. Repos are released in waves by sibling depth,
         so a library is out before anything that includeBuilds it starts.
       • two repos that share a sibling never build together. A composite build
         compiles the included sibling inside the sibling's own directory, so
         two Gradle processes would write the same build/ at once. Each task
         holds its own repo and its transitive siblings for its whole run.
     Each task's output is held and printed as one block when it finishes.

  4. PIN. Once every release is out, repoint the pack metafiles one after the
     other (`packwiz update <mod>`), then refresh the index once. This part is
     never parallel: packwiz rewrites index.toml on every update. That is why
     the releases above run with `mms-release --defer-pack`.

Stages (for mms-deploy, which runs other work between and alongside them):
  --plan-out FILE  Steps 1-2 and the confirmation prompt only. Writes the plan
                   to FILE and releases nothing.
  --run FILE       Step 3 for the plan in FILE. Never prompts and never touches
                   the pack index, so `packwiz update -a` can run beside it.
                   Records which releases succeeded back into FILE.
  --pin FILE       Step 4 for the releases --run recorded. Leaves the final
                   `packwiz refresh` to the caller.
With none of these, mms-ship runs all four steps itself and refreshes the index.

Selection:
  • No repo arguments  → auto-select every enabled pack mod that is not IN SYNC.
                         Disabled-in-pack mods (see `mms-repos list`) are skipped
                         unless named explicitly, so a prod ship never quietly
                         re-enables one.
  • repo [repo…]       → ship exactly those, whatever their state (still refusing
                         to walk backwards). Append `:patch|:minor|:major|:X.Y.Z`
                         to set that repo's bump; otherwise --bump / the default.

Flags:
  --server DIR   Server mods folder to diff against (default: Server Prod/mods).
                 The deploy's testing lane passes its own server here.
  --bump LEVEL   Default bump for repos that need one (patch|minor|major).
                 Default: patch. A `repo:LEVEL` argument overrides it per repo.
  -n / --dry-run Show the diff and the plan; change nothing. Passes -n through to
                 mms-release, so even the per-repo rehearsal is real.
  -y / --yes     Skip the confirmation prompt (and pass -y to mms-release).

Exit status: non-zero if any repo's release failed, so a caller (mms-deploy) can
stop before syncing a half-released suite to the server.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
import threading
import time
import zipfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

PACK_DIR = Path(__file__).resolve().parent
RELEASE_SH = PACK_DIR / "mms-release.sh"
DEFAULT_SERVER = Path(os.path.expanduser("~/Documents/GitHub/Server Prod/mods"))


# ── reuse mms-repos.py's discovery rather than re-deriving any of it ───────────
def _load_repos_module():
    """Import mms-repos.py as a module despite the dash in its filename."""
    path = PACK_DIR / "mms-repos.py"
    spec = importlib.util.spec_from_file_location("mms_repos", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


R = _load_repos_module()


# ── read what prod is actually running (the diff anchor) ──────────────────────
def jar_mod_info(path: Path) -> tuple[str | None, str | None]:
    try:
        with zipfile.ZipFile(path) as z:
            meta = json.loads(z.read("fabric.mod.json"))
            return meta["id"], meta.get("version")
    except Exception:
        return None, None


def server_versions(server_mods: Path) -> dict[str, tuple[str, str | None]]:
    """{fabric_mod_id: (jar_filename, version)} for every jar on the server."""
    out: dict[str, tuple[str, str | None]] = {}
    if not server_mods.is_dir():
        return out
    for f in os.listdir(server_mods):
        if f.endswith(".jar"):
            mid, ver = jar_mod_info(server_mods / f)
            if mid:
                out[mid] = (f, ver)
    return out


# ── a repo's Fabric mod id, discovered from source (no build needed) ──────────
def repo_mod_id(repo: Path) -> str | None:
    """The mod's Fabric id. Read from source resources first (the id is a literal
    even when the version there is a ${version} placeholder); fall back to the
    newest built jar for repos with a non-standard resource layout."""
    for res in repo.glob("src/main/resources/**/fabric.mod.json"):
        try:
            m = json.loads(res.read_text())
            if m.get("id"):
                return m["id"]
        except Exception:
            pass
    libs = repo / "build" / "libs"
    if libs.is_dir():
        jars = [libs / f for f in os.listdir(libs)
                if f.endswith(".jar") and "-sources" not in f and "-dev" not in f]
        if jars:
            mid, _ = jar_mod_info(max(jars, key=lambda p: p.stat().st_mtime))
            return mid
    return None


# ── does the local repo hold work its version number does not reflect? ────────
def has_local_work(repo: Path, rel: str | None = None) -> bool:
    """True if the tree is dirty, has commits not yet on its upstream, or has
    commits (pushed or not) after the latest release's tag — i.e. there is work
    that a release would not currently capture. Falls back to 'commits since the
    latest tag' when there is no release and no tracked upstream."""
    def git(*a):
        return subprocess.run(["git", "-C", str(repo), *a],
                              capture_output=True, text=True)
    if git("status", "--porcelain").stdout.strip():
        return True
    if rel:
        tag = f"v{rel}"
        if git("rev-parse", "-q", "--verify", f"refs/tags/{tag}").returncode != 0:
            git("fetch", "-q", "origin", f"refs/tags/{tag}:refs/tags/{tag}")
        since = git("rev-list", "--count", f"{tag}..HEAD")
        if since.returncode == 0 and since.stdout.strip() not in ("", "0"):
            return True
    up = git("rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}")
    if up.returncode == 0 and up.stdout.strip():
        ahead = git("rev-list", "--count", "@{u}..HEAD").stdout.strip()
        return ahead not in ("", "0")
    tag = git("describe", "--tags", "--abbrev=0").stdout.strip()
    if tag:
        ahead = git("rev-list", "--count", f"{tag}..HEAD").stdout.strip()
        return ahead not in ("", "0")
    return False


def bump(cur: str, spec: str) -> str:
    """Same keyword bump semantics as mms-release.sh (used only for the PLAN
    preview; mms-release does the authoritative rewrite)."""
    if spec in ("major", "minor", "patch"):
        core = re.match(r"[0-9.]*", cur).group(0)
        parts = (core.split(".") + ["0", "0", "0"])[:3]
        M, m, p = (int(x) if x.isdigit() else 0 for x in parts)
        if spec == "major":
            M, m, p = M + 1, 0, 0
        elif spec == "minor":
            m, p = m + 1, 0
        else:
            p = p + 1
        return f"{M}.{m}.{p}"
    return spec  # explicit X.Y.Z


# ── plan one repo ─────────────────────────────────────────────────────────────
def plan_repo(manifest, name, prodmap, named, bump_specs, default_bump):
    rd = R.repo_dir(manifest, name)
    meta = manifest["repos"][name]
    pe = R.pack_entry(manifest, name)
    src = R.norm(R.gradle_prop(rd, "mod_version"))
    mid = repo_mod_id(rd) if rd.is_dir() else None
    prod_file, prod_ver = prodmap.get(mid, (None, None))
    prod_ver = R.norm(prod_ver)
    rel = R.norm(R.latest_release(manifest, name))
    pack_tag = R.norm(pe["tag"]) if pe else None
    disabled = bool(pe and pe["disabled"])

    row = {"name": name, "role": meta.get("role", "mod"), "src": src,
           "prod": prod_ver, "release": rel, "action": None, "target": None,
           "bump": None, "note": ""}

    if not rd.is_dir():
        row["action"], row["note"] = "SKIP", "not checked out"
        return row
    if not (rd / ".git").exists():
        # A dir that exists but has no .git is a repo mid-scaffold (added to the
        # manifest, tree stubbed out, but never git-init'd / released). mms-release
        # would fail on it; skip cleanly so a half-set-up repo can't break the suite.
        row["action"], row["note"] = "SKIP", "no .git — repo not initialized yet"
        return row
    if src is None:
        row["action"], row["note"] = "SKIP", "no mod_version"
        return row
    if disabled and name not in named:
        row["action"], row["note"] = "SKIP", "disabled in pack (name it to ship)"
        return row

    work = has_local_work(rd, rel)
    src_ahead = ((prod_ver and R._vgt(src, prod_ver)) or
                 (rel and R._vgt(src, rel)) or
                 (rel is None and prod_ver is None))

    # An explicit `repo:LEVEL` argument is a deliberate "cut this bump" and wins
    # over the in-sync check — otherwise BUMP fires only when there is
    # unreflected local work and the source number has not already been moved
    # ahead (if you already bumped, we respect that).
    explicit_bump = name in bump_specs
    if explicit_bump or (work and not src_ahead):
        lvl = bump_specs.get(name, default_bump)
        row["bump"] = lvl
        row["target"] = bump(src, lvl)
        row["action"] = "BUMP"
        return row

    # No bump needed. Decide whether a release must be cut, merely adopted, or
    # nothing at all.
    target = src
    row["target"] = target
    need_release = rel is None or R._vgt(target, rel)
    need_pack = pack_tag is None or R._vgt(target, pack_tag)
    need_prod = prod_ver is None or R._vgt(target, prod_ver)

    if need_release:
        row["action"] = "RELEASE"
    elif need_pack or need_prod:
        # Release exists; only the pack pin / server is behind. Left for the
        # deploy's own `packwiz update` + server sync — mms-ship doesn't adopt.
        row["action"] = "ADOPT"
        row["note"] = "release exists; deploy will pick it up"
    else:
        row["action"] = "IN SYNC"
    return row


_PRINT = threading.Lock()


def release_one(row, dry, locks):
    """Run mms-release.sh for one BUMP/RELEASE row. Returns True on success.

    Always non-interactive (-y): the plan was confirmed before any task started,
    and several tasks cannot share one prompt. Output is captured and printed as
    a single block, so parallel releases do not interleave line by line."""
    cmd = ["bash", str(RELEASE_SH), "--defer-pack"]
    cmd.append("-n" if dry else "-y")
    if row["action"] == "BUMP":
        cmd += ["-b", row["bump"]]
    cmd.append(row["name"])
    held = sorted(row["locks"])
    for name in held:          # one global order, so two tasks cannot deadlock
        locks[name].acquire()
    try:
        with _PRINT:
            print(f"▶ {row['name']}: started", flush=True)
        t0 = time.monotonic()
        proc = subprocess.run(cmd, stdin=subprocess.DEVNULL, text=True,
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        took = time.monotonic() - t0
    finally:
        for name in reversed(held):
            locks[name].release()
    ok = proc.returncode == 0
    with _PRINT:
        print(f"\n──────── {row['name']} ({row['action']}"
              f"{' ' + row['bump'] if row['bump'] else ''}) — "
              f"{'ok' if ok else 'FAILED'} in {took:.0f}s ────────")
        print(proc.stdout.rstrip(), flush=True)
    return ok


def run_releases(todo, dry):
    """Release every row in `todo`, in parallel within each sibling-depth wave.
    Returns the names that succeeded."""
    locks = {n: threading.Lock() for r in todo for n in r["locks"]}
    done: list[str] = []
    for depth in sorted({r["depth"] for r in todo}):
        wave = [r for r in todo if r["depth"] == depth]
        print(f"\n── release wave {depth}: {', '.join(r['name'] for r in wave)} ──",
              flush=True)
        with ThreadPoolExecutor(max_workers=len(wave)) as pool:
            results = list(pool.map(lambda r: release_one(r, dry, locks), wave))
        for r, ok in zip(wave, results):
            if ok:
                done.append(r["name"])
            else:
                print(f"!! {r['name']} failed — the rest carry on.",
                      file=sys.stderr, flush=True)
    return done


def pin_releases(manifest, todo, released) -> bool:
    """Point the pack at each release in `released`, one at a time. Returns False
    if any metafile is still behind afterwards."""
    ok = True
    for r in todo:
        if r["name"] not in released:
            continue
        pe = R.pack_entry(manifest, r["name"])
        if pe is None or pe["disabled"]:
            continue            # released only; nothing enabled in the pack pins it
        toml = PACK_DIR / "mods" / pe["file"]
        slug = pe["file"][:-len(".pw.toml")]
        want = f'tag = "v{r["target"]}"'
        # The releases API is eventually consistent: a release cut seconds ago
        # can be missing from the list, so retry until the metafile moves.
        for attempt in range(5):
            subprocess.run(["packwiz", "-y", "update", slug], cwd=PACK_DIR,
                           stdin=subprocess.DEVNULL, capture_output=True)
            if want in toml.read_text():
                break
            print(f"   ({r['name']}: release not visible yet, retrying in 5s...)",
                  flush=True)
            time.sleep(5)
        if want in toml.read_text():
            print(f"pack: {slug} -> v{r['target']}", flush=True)
        else:
            ok = False
            print(f"!! {r['name']}: pack still behind v{r['target']} — re-run "
                  f"once the release is visible.", file=sys.stderr, flush=True)
    return ok


def load_plan(path):
    with open(path) as fh:
        return json.load(fh)


def save_plan(path, plan):
    with open(path, "w") as fh:
        json.dump(plan, fh)


def parse_targets(argv_repos):
    """['mms-jobs:minor', 'mms-metro'] -> (['mms-jobs','mms-metro'], {'mms-jobs':'minor'})."""
    named, specs = [], {}
    for tok in argv_repos:
        if ":" in tok:
            n, lvl = tok.split(":", 1)
            named.append(n)
            specs[n] = lvl
        else:
            named.append(tok)
    return named, specs


# ── mirror bundled resource packs from their source repos into this pack ──────
def sync_resourcepacks(manifest, dry: bool) -> list[str]:
    """Copy any resourcepacks/<pack>/ a mod repo carries into this pack's own
    resourcepacks/, so the mod repo stays the single source of its pack and the
    deploy's later `packwiz refresh` always indexes the current files.

    A mod's pack is authored in that mod's repo (mms-vanity owns lowlands-vanity),
    but packwiz refreshes from PACK_DIR, so the two drift by hand unless something
    copies. Discovery, not a hardcoded list, so a future port that adds its own
    resourcepacks/<pack>/ is picked up with no change here.

    The whole subtree is mirrored, including files git-ignored in both repos (the
    All-Rights-Reserved Lowlands textures): those are exactly what has to reach the
    client, and are in neither repo's history to sync any other way. Returns the
    pack names synced."""
    dest_root = PACK_DIR / "resourcepacks"
    synced: list[str] = []
    for name in manifest["repos"]:
        rd = R.repo_dir(manifest, name)
        src_root = rd / "resourcepacks"
        if not src_root.is_dir():
            continue
        for src in sorted(p for p in src_root.iterdir() if p.is_dir()):
            dst = dest_root / src.name
            if dst.resolve() == src.resolve():
                continue
            synced.append(src.name)
            if dry:
                continue
            if dst.exists():
                shutil.rmtree(dst)
            shutil.copytree(src, dst)
    return synced


def main(argv=None):
    ap = argparse.ArgumentParser(prog="mms-ship", description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("repos", nargs="*", help="repo[:bump] to ship; empty = auto-select")
    ap.add_argument("--server", default=str(DEFAULT_SERVER),
                    help="server mods folder to diff against (default: Server Prod/mods)")
    ap.add_argument("--bump", default="patch", choices=["patch", "minor", "major"],
                    help="default bump for repos that need one (default: patch)")
    ap.add_argument("-n", "--dry-run", action="store_true")
    ap.add_argument("-y", "--yes", action="store_true")
    ap.add_argument("--plan-out", metavar="FILE",
                    help="plan and confirm only; write the plan to FILE")
    ap.add_argument("--run", metavar="FILE",
                    help="release the plan in FILE, in parallel; no pack writes")
    ap.add_argument("--pin", metavar="FILE",
                    help="point the pack at the releases --run recorded in FILE")
    args = ap.parse_args(argv)

    manifest = R.load_manifest()

    if args.run:
        plan = load_plan(args.run)
        todo = plan["todo"]
        if not todo:
            return 0
        plan["released"] = run_releases(todo, plan["dry"])
        save_plan(args.run, plan)
        if plan["dry"]:
            print("\nDry run complete — nothing was released.", flush=True)
        return 0 if len(plan["released"]) == len(todo) else 1

    if args.pin:
        plan = load_plan(args.pin)
        if plan["dry"] or not plan.get("released"):
            return 0
        return 0 if pin_releases(manifest, plan["todo"], plan["released"]) else 1

    named, bump_specs = parse_targets(args.repos)
    unknown = [n for n in named if n not in manifest["repos"]]
    if unknown:
        print(f"ERROR: unknown repo(s): {', '.join(unknown)}", file=sys.stderr)
        print(f"       known: {', '.join(manifest['repos'])}", file=sys.stderr)
        return 2

    server = Path(os.path.expanduser(args.server))
    if not server.is_dir():
        print(f"?? server mods folder not mounted at {server} — diffing against "
              f"releases only (prod column blank).", file=sys.stderr)
    prodmap = server_versions(server)

    # Bottom-up build order so a library releases before its dependents.
    order = sorted(manifest["repos"],
                   key=lambda n: (R.sibling_depth(manifest, n), n))
    if named:
        order = [n for n in order if n in named]

    R.prefetch_releases(manifest, order)
    rows = [plan_repo(manifest, n, prodmap, named, bump_specs, args.bump)
            for n in order]

    # ── the diff table ──
    print(f"Diffing against: {server}"
          f"{'  (not mounted)' if not server.is_dir() else ''}\n")
    hdr = f'{"repo":<38}{"prod":<10}{"source":<10}{"release":<10}{"decision"}'
    print(hdr)
    print("-" * len(hdr))
    for r in rows:
        dec = r["action"]
        if r["action"] == "BUMP":
            dec = f'BUMP {r["bump"]} → {r["target"]}'
        elif r["action"] == "RELEASE":
            dec = f'RELEASE {r["target"]}'
        if r["note"]:
            dec = f'{dec}  ({r["note"]})'
        print(f'{r["name"]:<38}{str(r["prod"] or "—"):<10}'
              f'{str(r["src"] or "—"):<10}{str(r["release"] or "—"):<10}{dec}')

    synced = sync_resourcepacks(manifest, args.dry_run)
    if synced:
        verb = "would sync" if args.dry_run else "synced"
        print(f"\nResource packs {verb} into the pack: {', '.join(sorted(set(synced)))}")

    todo = [r for r in rows if r["action"] in ("BUMP", "RELEASE")]
    for r in todo:
        r["depth"] = R.sibling_depth(manifest, r["name"])
        r["locks"] = [r["name"], *R.transitive_siblings(manifest, r["name"])]
    plan = {"dry": args.dry_run, "todo": todo, "released": []}
    if not todo:
        print("\nNothing to release — every named/enabled mod is in sync or "
              "only needs adoption at deploy time.")
        if args.plan_out:
            save_plan(args.plan_out, plan)
        return 0

    print(f"\n{len(todo)} repo(s) to release: "
          f"{', '.join(r['name'] for r in todo)}")
    if args.dry_run:
        print("\nDry run — mms-release -n runs for each (nothing is cut).")
    elif not args.yes:
        try:
            reply = input("\nProceed with these releases? [y/N] ")
        except EOFError:
            reply = ""
        if not reply.lower().startswith("y"):
            print("Aborted.")
            return 1

    if args.plan_out:
        save_plan(args.plan_out, plan)
        return 0

    released = run_releases(todo, args.dry_run)
    if args.dry_run:
        print("\nDry run complete — nothing was released.")
        return 0
    rc = 0 if len(released) == len(todo) else 1
    if released:
        print("\n── pinning the pack ──", flush=True)
        if not pin_releases(manifest, todo, released):
            rc = 1
        subprocess.run(["packwiz", "refresh"], cwd=PACK_DIR)
        subprocess.run([str(PACK_DIR / "update-title.sh")], cwd=PACK_DIR)
        print("Pack updated (uncommitted — commit when you're ready).")
    return rc


if __name__ == "__main__":
    sys.exit(main())
