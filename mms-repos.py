#!/usr/bin/env python3
"""mms-repos — the manifest-driven view of the MMS repo set.

This is the single place the deploy tooling learns "what repos exist and how do
they relate." It reads the thin mms-repos.toml list and DISCOVERS everything
else from the actual repo trees, so nothing here has to be kept in sync by hand.

Commands
  list            One row per repo: role, local version, deps, needs-libs, pack.
  graph           Dependency graph + the bottom-up build order CI uses.
  drift           Every place a version disagrees with itself: local vs pack
                  metafile vs latest GitHub release, and in-pack repos with no
                  metafile. This is the "design now, reconcile later" report —
                  it reports, it never changes anything.
  check-callers   Verify each repo's .github/workflows/release.yml still equals
                  the caller template, so the reusable engine can't be bypassed
                  by a drifted per-repo copy.

Flags
  --online / --no-online   Query GitHub for latest releases (default: online for
                           `drift`, off elsewhere). Degrades gracefully if gh is
                           missing or offline.
  --json                   Machine-readable output.

Exit status: `drift` and `check-callers` exit non-zero when they find problems,
so they double as CI/pre-release guards.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import tomllib
from functools import lru_cache
from pathlib import Path

PACK_DIR = Path(__file__).resolve().parent
MANIFEST = PACK_DIR / "mms-repos.toml"
CALLER_TEMPLATE = PACK_DIR / ".github/workflows/_caller-template.yml"

# ── manifest ──────────────────────────────────────────────────────────────────


def load_manifest() -> dict:
    with MANIFEST.open("rb") as fh:
        m = tomllib.load(fh)
    m.setdefault("owner", "mudbourn")
    root = os.path.expanduser(os.path.expandvars(m.get("checkout_root", "..")))
    m["checkout_root"] = Path(root)
    return m


def repo_dir(manifest: dict, name: str) -> Path:
    return manifest["checkout_root"] / name


# ── tree discovery (the source of truth is the repo, never the manifest) ───────


def gradle_prop(repo: Path, key: str) -> str | None:
    gp = repo / "gradle.properties"
    if not gp.is_file():
        return None
    for line in gp.read_text().splitlines():
        if line.startswith(f"{key}="):
            return line.split("=", 1)[1].strip()
    return None


_INCLUDE_BUILD = re.compile(r'includeBuild[^"\']*["\']([^"\']*)["\']')


def direct_siblings(repo: Path) -> list[str]:
    """Sibling repo names this repo wires in via includeBuild (one hop).

    Matched per line, skipping Groovy comments — the word "includeBuild" also
    appears in the surrounding documentation, and a whole-file regex would
    otherwise capture a quoted string from a later, unrelated line.
    """
    sg = repo / "settings.gradle"
    if not sg.is_file():
        return []
    out = []
    for raw in sg.read_text().splitlines():
        line = raw.strip()
        if line.startswith(("//", "*", "/*")):
            continue
        m = _INCLUDE_BUILD.search(line)
        if m:
            # keep only the trailing path segment: '../mms-x' and "$root/mms-x" -> mms-x
            out.append(m.group(1).rstrip("/").split("/")[-1])
    return sorted(set(out))


def transitive_siblings(manifest: dict, name: str) -> list[str]:
    seen: set[str] = set()
    stack = list(direct_siblings(repo_dir(manifest, name)))
    while stack:
        s = stack.pop()
        if s in seen:
            continue
        seen.add(s)
        stack.extend(direct_siblings(repo_dir(manifest, s)))
    return sorted(seen)


def sibling_depth(manifest: dict, name: str, _stack: tuple = ()) -> int:
    """0 = no sibling deps; N = one past its deepest dependency (build order)."""
    if name in _stack:  # cycle guard
        return 0
    deps = direct_siblings(repo_dir(manifest, name))
    if not deps:
        return 0
    return 1 + max(sibling_depth(manifest, d, _stack + (name,)) for d in deps)


def needs_libs(repo: Path) -> bool:
    bg = repo / "build.gradle"
    return bg.is_file() and bool(re.search(r'files\("libs/[^"]+\.jar"\)', bg.read_text()))


# ── pack membership (lives in mms-pack, so discovered here, not in the repo) ────


@lru_cache(maxsize=1)
def _metafiles() -> list[tuple[Path, bool]]:
    files = []
    for sub, disabled in (("mods", False), ("disabled-mods", True)):
        d = PACK_DIR / sub
        if d.is_dir():
            files += [(p, disabled) for p in d.glob("*.pw.toml")]
    return files


def pack_entry(manifest: dict, name: str) -> dict | None:
    """The pack metafile tracking this repo, if any."""
    slug = f'{manifest["owner"]}/{name}'
    for path, disabled in _metafiles():
        text = path.read_text()
        if re.search(rf'^slug = "{re.escape(slug)}"', text, re.MULTILINE):
            tag = None
            tm = re.search(r'^tag = "([^"]*)"', text, re.MULTILINE)
            if tm:
                tag = tm.group(1)
            branch = None
            bm = re.search(r'^branch = "([^"]*)"', text, re.MULTILINE)
            if bm:
                branch = bm.group(1)
            return {"file": path.name, "tag": tag, "disabled": disabled,
                    "branch": branch}
    return None


# ── GitHub ─────────────────────────────────────────────────────────────────────


def latest_release(manifest: dict, name: str) -> str | None:
    try:
        out = subprocess.run(
            ["gh", "release", "view", "--repo", f'{manifest["owner"]}/{name}',
             "--json", "tagName", "-q", ".tagName"],
            capture_output=True, text=True, timeout=20,
        )
        tag = out.stdout.strip()
        return tag or None
    except (FileNotFoundError, subprocess.SubprocessError):
        return None


# ── row assembly ───────────────────────────────────────────────────────────────


def collect(manifest: dict, online: bool) -> list[dict]:
    rows = []
    for name, meta in manifest["repos"].items():
        rd = repo_dir(manifest, name)
        pe = pack_entry(manifest, name)
        rows.append({
            "name": name,
            "role": meta.get("role", "mod"),
            "present": rd.is_dir(),
            "version": gradle_prop(rd, "mod_version"),
            "siblings": transitive_siblings(manifest, name),
            "needs_libs": needs_libs(rd) if rd.is_dir() else None,
            "pack_file": pe["file"] if pe else None,
            "pack_tag": pe["tag"] if pe else None,
            "pack_disabled": pe["disabled"] if pe else None,
            "pack_branch": pe["branch"] if pe else None,
            "latest_release": latest_release(manifest, name) if online else None,
        })
    return rows


# ── commands ───────────────────────────────────────────────────────────────────


def norm(tag: str | None) -> str | None:
    return tag[1:] if tag and tag.startswith("v") else tag


def cmd_list(manifest, args):
    rows = collect(manifest, args.online)
    if args.json:
        print(json.dumps(rows, indent=2))
        return 0
    hdr = f'{"repo":<38} {"role":<8} {"version":<14} {"libs":<5} {"pack":<28} siblings'
    print(hdr)
    print("-" * len(hdr))
    for r in rows:
        pack = "—"
        if r["pack_file"]:
            pack = f'{r["pack_tag"] or "?"}{" (disabled)" if r["pack_disabled"] else ""}'
        libs = "yes" if r["needs_libs"] else ("no" if r["needs_libs"] is not None else "?")
        miss = "" if r["present"] else "  [not checked out]"
        print(f'{r["name"]:<38} {r["role"]:<8} {str(r["version"] or "?"):<14} '
              f'{libs:<5} {pack:<28} {",".join(r["siblings"]) or "—"}{miss}')
    return 0


def cmd_graph(manifest, args):
    rows = {r["name"]: r for r in collect(manifest, online=False)}
    order = sorted(rows, key=lambda n: (sibling_depth(manifest, n), n))
    print("Dependency edges (repo → sibling it includeBuilds):")
    any_edge = False
    for n in order:
        for d in direct_siblings(repo_dir(manifest, n)):
            print(f"  {n} → {d}")
            any_edge = True
    if not any_edge:
        print("  (none)")
    print("\nBottom-up build order (what CI builds before the target):")
    for n in order:
        print(f"  [{sibling_depth(manifest, n)}] {n}")
    return 0


def cmd_drift(manifest, args):
    rows = collect(manifest, online=args.online)
    problems = []
    for r in rows:
        name, ver = r["name"], norm(r["version"])
        # 1. mod with no pack metafile at all (library repos legitimately may
        #    still be pinned; a mod that ships should be tracked somewhere).
        if r["pack_file"] is None and r["role"] == "mod":
            problems.append((name, "no pack metafile — mod is built but the pack "
                                   "tracks no version of it"))
        # 0. metafile pinned to a commit SHA instead of a branch. packwiz's
        #    GitHub updater matches a release only when its target_commitish
        #    equals `branch`; a SHA there never matches a release cut on main, so
        #    the pin silently stops advancing (packwiz says "already up to date"
        #    while a newer release exists). This one bites at release time, not
        #    now, so surface it early.
        if r["pack_branch"] and re.fullmatch(r"[0-9a-f]{40}", r["pack_branch"]):
            problems.append((name, f"{r['pack_file']} pins branch to a commit SHA "
                                   f"({r['pack_branch'][:10]}…) — packwiz will never "
                                   f"see new releases; set branch = \"main\""))
        # 2. pack tag vs local source version.
        pack = norm(r["pack_tag"])
        if pack and ver and pack != ver:
            direction = "ahead of" if _vgt(pack, ver) else "behind"
            note = " (disabled in pack)" if r["pack_disabled"] else ""
            problems.append((name, f"pack pins {r['pack_tag']} but source is "
                                   f"{r['version']} — pack is {direction} source{note}"))
        # 3. latest GitHub release vs pack tag (online only).
        rel = norm(r["latest_release"])
        if rel and pack and rel != pack:
            problems.append((name, f"latest release v{rel} but pack still pins "
                                   f"{r['pack_tag']} — release the pack hasn't picked up"))
        # 4. latest GitHub release vs local source (unreleased local bump).
        if rel and ver and _vgt(ver, rel):
            problems.append((name, f"source at {r['version']} is newer than latest "
                                   f"release v{rel} — unreleased local bump"))
        if not r["present"]:
            problems.append((name, "not checked out locally — cannot verify source"))
    if args.json:
        print(json.dumps([{"repo": p[0], "issue": p[1]} for p in problems], indent=2))
    else:
        if not problems:
            print("No drift. Every repo's source, pack pin, and release agree.")
        else:
            print(f"{len(problems)} drift issue(s):\n")
            for name, msg in problems:
                print(f"  ⚠ {name}: {msg}")
            print("\nThis is a report only. Reconcile deliberately with mms-release "
                  "(per repo) once you've decided the intended version.")
    return 1 if problems else 0


def cmd_releasable(manifest, args):
    """Repos whose local source version is ahead of the tag the pack pins — the
    ones `mms-release` would actually advance. Bare names, one per line, so
    `mms-release --all` can loop them. Offline by design."""
    names = []
    for r in collect(manifest, online=False):
        ver, pack = norm(r["version"]), norm(r["pack_tag"])
        if not r["present"] or not ver:
            continue
        # No pin yet, or source strictly ahead of the pin.
        if pack is None or _vgt(ver, pack):
            names.append(r["name"])
    if args.json:
        print(json.dumps(names))
    else:
        for n in names:
            print(n)
    return 0


def _vgt(a: str, b: str) -> bool:
    """True if version a > b, using a lenient numeric tuple compare."""
    def key(v):
        return [int(x) if x.isdigit() else x
                for x in re.split(r"[.\+\-]", v)]
    try:
        return key(a) > key(b)
    except TypeError:
        return str(a) > str(b)


def cmd_check_callers(manifest, args):
    if not CALLER_TEMPLATE.is_file():
        print(f"ERROR: template missing at {CALLER_TEMPLATE}", file=sys.stderr)
        return 2
    # Compare only the meaningful body (the caller stub the template documents),
    # stripping the leading comment block so template prose can change freely.
    want = _caller_body(CALLER_TEMPLATE.read_text())
    bad = []
    for name in manifest["repos"]:
        rel = repo_dir(manifest, name) / ".github/workflows/release.yml"
        if not rel.is_file():
            bad.append((name, "no .github/workflows/release.yml"))
            continue
        if _caller_body(rel.read_text()) != want:
            bad.append((name, "release.yml differs from caller template"))
    if args.json:
        print(json.dumps([{"repo": b[0], "issue": b[1]} for b in bad], indent=2))
    else:
        if not bad:
            print("All release.yml callers match the template.")
        else:
            print(f"{len(bad)} caller issue(s):\n")
            for name, msg in bad:
                print(f"  ⚠ {name}: {msg}")
            print(f"\nFix by copying {CALLER_TEMPLATE.name} to the repo's "
                  ".github/workflows/release.yml.")
    return 1 if bad else 0


def _caller_body(text: str) -> str:
    """Normalize a workflow file to its non-comment, non-blank lines."""
    lines = []
    for ln in text.splitlines():
        s = ln.rstrip()
        if not s or s.lstrip().startswith("#"):
            continue
        lines.append(s)
    return "\n".join(lines)


# ── entry ──────────────────────────────────────────────────────────────────────


def main(argv=None):
    # Shared options live on a parent parser attached to BOTH the top level and
    # every subcommand, so `--no-online drift` and `drift --no-online` both work.
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--json", action="store_true", help="machine-readable output")
    online = common.add_mutually_exclusive_group()
    online.add_argument("--online", dest="online", action="store_true", default=None,
                        help="query GitHub for latest releases")
    online.add_argument("--no-online", dest="online", action="store_false",
                        help="skip GitHub queries")

    # Note: `common` is attached to the SUBcommands only, not here — argparse
    # would otherwise let the subparser's defaults clobber a top-level value.
    # So shared flags go after the subcommand: `drift --no-online`, `list --json`.
    p = argparse.ArgumentParser(prog="mms-repos", description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    for name in ("list", "graph", "drift", "check-callers", "releasable"):
        sub.add_parser(name, parents=[common])
    args = p.parse_args(argv)

    # drift is only meaningful online; everything else defaults offline.
    if args.online is None:
        args.online = args.cmd == "drift"

    manifest = load_manifest()
    return {
        "list": cmd_list,
        "graph": cmd_graph,
        "drift": cmd_drift,
        "check-callers": cmd_check_callers,
        "releasable": cmd_releasable,
    }[args.cmd](manifest, args)


if __name__ == "__main__":
    sys.exit(main())
