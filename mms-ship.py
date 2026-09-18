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
     a release backwards, cuts the tagged GitHub release, and repoints the pack
     metafile. mms-ship never re-implements any of that; it only decides the set
     and the bump level.

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
import zipfile
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
def has_local_work(repo: Path) -> bool:
    """True if the tree is dirty or has commits not yet on its upstream — i.e.
    there is local work that a release would not currently capture. Falls back to
    'commits since the latest tag' when there is no tracked upstream."""
    def git(*a):
        return subprocess.run(["git", "-C", str(repo), *a],
                              capture_output=True, text=True)
    if git("status", "--porcelain").stdout.strip():
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

    work = has_local_work(rd)
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


def run_release(row, dry, yes):
    """Invoke mms-release.sh for a BUMP/RELEASE row. Returns True on success."""
    cmd = ["bash", str(RELEASE_SH)]
    if dry:
        cmd.append("-n")
    if yes:
        cmd.append("-y")
    if row["action"] == "BUMP":
        cmd += ["-b", row["bump"]]
    cmd.append(row["name"])
    print(f"\n──────── {row['name']} ({row['action']}"
          f"{' ' + row['bump'] if row['bump'] else ''}) ────────")
    sys.stdout.flush()  # mms-release writes to the tty directly; flush our
                        # buffered output first so it doesn't print underneath.
    return subprocess.run(cmd).returncode == 0


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
    args = ap.parse_args(argv)

    manifest = R.load_manifest()
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
    if not todo:
        print("\nNothing to release — every named/enabled mod is in sync or "
              "only needs adoption at deploy time.")
        return 0

    print(f"\n{len(todo)} repo(s) to release: "
          f"{', '.join(r['name'] for r in todo)}")
    if args.dry_run:
        print("\nDry run — walking mms-release -n for each (nothing is cut):")
    elif not args.yes:
        try:
            reply = input("\nProceed with these releases? [y/N] ")
        except EOFError:
            reply = ""
        if not reply.lower().startswith("y"):
            print("Aborted.")
            return 1

    rc = 0
    for r in todo:
        if not run_release(r, args.dry_run, args.yes):
            rc = 1
            print(f"!! {r['name']} failed — continuing with the rest.",
                  file=sys.stderr)
    if args.dry_run:
        print("\nDry run complete — nothing was released.")
    return rc


if __name__ == "__main__":
    sys.exit(main())
