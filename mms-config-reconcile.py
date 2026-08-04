#!/usr/bin/env python3
"""Pull config/ changes from a client instance back into the pack repo.

    mms-config-reconcile.py [instance_minecraft_dir] [pack_dir]
    mms-config-reconcile.py --apply            write the changes
    mms-config-reconcile.py --apply --prune    also delete repo-only files

Defaults to the MMS Live instance, and to a dry run.

Why this exists
---------------
Prism holds the config that is actually in use; the repo's config/ is a
snapshot of it that goes stale the moment anything is tuned in-game. The drift
is one-way by nature — edits happen in the instance and need to reach the repo,
never the reverse — but there was no way to move them across except by hand,
so 477 indexed config files slowly diverged from the ones being played on.

Symlinking config/ at the instance was the obvious shortcut and it does not
work: git stores a directory symlink as a symlink blob and never traverses the
target, so every config file would vanish from the repo, from the raw-URL
distribution, and from the exported .mrpack. It has to be a real copy.

Do not compare mtimes
---------------------
packwiz-installer rewrites every tracked file on each client launch, so a
file's mtime in the instance says when the client last started, not when
anything changed. Everything here compares SHA-256 content hashes.

What is skipped
---------------
Live per-session state that lives under config/ but is not configuration: JEI's
per-server lookup history, imgui window geometry, spark's activity log, editor
backup copies, cached skins, OS cruft. Folding these into the index would make
clients re-download configs because a JEI search was typed. See SKIP below.

Findings
--------
NEW      in the instance, absent from the repo — will be copied
CHANGED  present in both, contents differ — repo copy will be overwritten
GONE     in the repo, absent from the instance

GONE is reported but never acted on without --prune: a file missing from one
instance may still be shipped deliberately, and deleting it silently would drop
it from the pack for everyone.

Exits non-zero when a dry run finds drift, so a release script can gate on it.
"""
import fnmatch
import hashlib
import os
import shutil
import sys

DEFAULT_INSTANCE = os.path.expanduser(
    '~/Library/Application Support/PrismLauncher/instances/MMS Live/minecraft'
)

# Matched against the config-relative path with '/' separators. A pattern
# ending in '/' matches that directory and everything under it.
SKIP = [
    '.DS_Store',
    '*/.DS_Store',
    'jei/world/',            # per-server lookup history and search state
    'axiom/imgui.ini',       # window geometry
    'axiom/.axiom.json.backup',
    'spark/activity.json',   # profiler session log
    '*_backup[0-9]',         # chloride and friends keep numbered copies
    '*.bak',
    'Easy Shop Mod/My Skin/*.png',        # cached skin, uuid-named
    'Easy Shop Mod/AllPlayerSkins/',      # skins cached per player seen in-game
]

_argv = [a for a in sys.argv[1:] if not a.startswith('--')]
apply_changes = '--apply' in sys.argv[1:]
prune = '--prune' in sys.argv[1:]

instance = _argv[0] if _argv else DEFAULT_INSTANCE
pack_dir = _argv[1] if len(_argv) > 1 else os.path.dirname(os.path.abspath(__file__))

src_root = os.path.join(instance, 'config')
dst_root = os.path.join(pack_dir, 'config')

if prune and not apply_changes:
    print('--prune has no effect without --apply', file=sys.stderr)
    sys.exit(2)
for root, label in ((src_root, 'instance'), (dst_root, 'pack')):
    if not os.path.isdir(root):
        print(f'ERROR: no {label} config directory at {root}', file=sys.stderr)
        sys.exit(2)
if os.path.islink(dst_root):
    print(f'ERROR: {dst_root} is a symlink. It must be a real directory — see '
          'the module docstring.', file=sys.stderr)
    sys.exit(2)


def skipped(rel):
    """True if a config-relative path is live state rather than configuration."""
    for pat in SKIP:
        if pat.endswith('/'):
            if rel == pat[:-1] or rel.startswith(pat):
                return True
        elif fnmatch.fnmatch(rel, pat) or fnmatch.fnmatch(os.path.basename(rel), pat):
            return True
    return False


def walk(root):
    """config-relative paths of every non-skipped regular file under root."""
    found = set()
    for dirpath, dirnames, filenames in os.walk(root):
        rel_dir = os.path.relpath(dirpath, root)
        rel_dir = '' if rel_dir == '.' else rel_dir
        # Prune skipped directories so we do not descend into them at all.
        dirnames[:] = [d for d in dirnames
                       if not skipped(os.path.join(rel_dir, d).replace(os.sep, '/'))]
        for name in filenames:
            rel = os.path.join(rel_dir, name).replace(os.sep, '/')
            if not skipped(rel):
                found.add(rel)
    return found


def digest(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 16), b''):
            h.update(chunk)
    return h.hexdigest()


src_files = walk(src_root)
dst_files = walk(dst_root)

new = sorted(src_files - dst_files)
gone = sorted(dst_files - src_files)
changed = sorted(
    rel for rel in (src_files & dst_files)
    if digest(os.path.join(src_root, rel)) != digest(os.path.join(dst_root, rel))
)

for label, paths in (('NEW', new), ('CHANGED', changed), ('GONE', gone)):
    for rel in paths:
        print(f'{label:<8} config/{rel}')

if not (new or changed or gone):
    print('config/ is in sync.')
    sys.exit(0)

if not apply_changes:
    print(f'\n{len(new)} new, {len(changed)} changed, {len(gone)} repo-only. '
          'Re-run with --apply to write.')
    sys.exit(1)

for rel in new + changed:
    dst = os.path.join(dst_root, rel)
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    shutil.copy2(os.path.join(src_root, rel), dst)
print(f'\nCopied {len(new) + len(changed)} file(s) into the pack.')

if gone:
    if prune:
        for rel in gone:
            os.remove(os.path.join(dst_root, rel))
        print(f'Pruned {len(gone)} repo-only file(s).')
    else:
        print(f'Left {len(gone)} repo-only file(s) alone; pass --prune to delete them.')

print("Run 'packwiz refresh' to pick the changes up into the index.")
