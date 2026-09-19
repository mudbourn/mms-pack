# MMS Live: Minecraft Modpack

**Minecraft 1.21.11 | Fabric loader 0.19.3 | Java 25 | pack version 2.5.2**

This repo *is* the modpack. It's a [packwiz](https://packwiz.infra.link/) pack, which means once
your launcher is pointed at it, **you get every update automatically just by launching the game**.
No re-downloading, no re-importing, no reinstalling for a single config change.

To make that work you need a **packwiz-aware launcher**. We use **[Prism Launcher](https://prismlauncher.org/)**
(free, open-source). ATLauncher and the CurseForge/Modrinth apps do **not** auto-update packwiz packs.
Please switch to Prism.

---

## Players: one-time setup (~5 minutes)

### 1. Install Prism Launcher
Download from **https://prismlauncher.org/download/** and sign in with your Microsoft/Minecraft account
(Prism -> *Accounts* -> *Add Microsoft account*).
![alt text](https://save.mudbourn.info/s/sAHdDkxDMdjM5re/download "Graph")

### 2. Create the instance
- Click **Add Instance**.
- Name it `MMS Live`.
- Choose **Minecraft 1.21.11**.
- Click **Fabric** and select loader version **0.19.3** (or newest 1.21.11-compatible).
- Create the instance. **Don't add any mods by hand yet**, the pack installs them for you.
![alt text](https://save.mudbourn.info/s/mgFTSBj6qxxxKJM/download "Graph")

- Set up **Java 25** (this pack requires it; Prism downloads it for you, no separate install):
  1. **Settings** -> **Java** -> **Installations**.
  2. Press **Download**, select the **25** option, press **Download**, then **OK**.
![alt text](https://save.mudbourn.info/s/dZxY8LDMdtczFMz/download "Graph")

### 3. Drop in the packwiz installer
- Download **`packwiz-installer-bootstrap.jar`** from
  https://github.com/packwiz/packwiz-installer-bootstrap/releases (grab the latest `.jar`).
![alt text](https://save.mudbourn.info/s/JLmZypmfEHSbACm/download "Graph")
- Click the instance -> **Folder** -> open the **`.minecraft`** subfolder.
- Put `packwiz-installer-bootstrap.jar` in there.
![alt text](https://save.mudbourn.info/s/pwG95t3jRXRR9ZZ/download "Graph")

### 4. Turn on auto-update
- Right-click the instance -> **Edit** -> **Settings** -> **Custom commands**.
- Tick **Ovweeide Global Settings**.
- In the **Pre-launch command** box, paste **exactly**:

  ```
  "$INST_JAVA" -jar packwiz-installer-bootstrap.jar https://raw.githubusercontent.com/mudbourn/mms-pack/main/pack.toml
  ```

- Close.
![alt text](https://save.mudbourn.info/s/YDNAdrSyDrALRiz/download "Graph")

### 5. Launch
Hit **Launch**. On every launch the installer checks this repo and downloads/updates only what changed,
then the game starts. First launch pulls the whole pack (a few minutes); after that updates are tiny.
![alt text](https://save.mudbourn.info/s/HZqGk7BFcwn58pK/download "Graph")


> **Server address:** ( mc.mudbourn.info ). Waypoints and land claims are
> server-side (Xaero + OpenPAC). They sync automatically in-game, nothing to install.

---

## Troubleshooting

| Problem | Fix |
|---|---|
| Crash: "requires version 25 or later of 'OpenJDK'" (C2ME / natives-math) | Instance is on Java 21. Set Java 25 in instance Settings -> Java (see step 2). |
| "Cannot find packwiz-installer-bootstrap.jar" | The jar must be inside `.minecraft/`, not the instance root. Re-check step 3. |
| Prelaunch window closes instantly / mods missing | Confirm the pre-launch box is the **exact** line above, quotes included. |
| Want to see what it's doing | Remove nothing. The installer prints progress in a small window each launch. |
| A mod update broke something | Tell an admin the mod + symptom; the pack is rolled forward centrally, then just relaunch. |

---

## Admins: publishing an update

You no longer drive `packwiz` by hand. Wrapper scripts edit the pack, and **one command
ships it**: `mms-deploy`, where the **branch you're on picks the lane** (`main` -> prod,
`testing` -> staging). Clients pick everything up on their next Prism launch.

```bash
export PATH="$HOME/go/bin:$PATH"
cd ~/Documents/GitHub/mms-pack

# --- edit the pack -------------------------------------------------------
./mms-add.sh <modrinth-slug-or-url>     # add a CDN mod
./mms-add.sh /path/to/mod.jar           # bundle a local/unhosted jar (served from this repo)
./mms-add.sh -u /path/to/mod.jar        # update a previously bundled local jar
./mms-remove.sh <slug-or-name-or-jar>   # remove a mod + its config leftovers (-n dry run)

# --- ship it -------------------------------------------------------------
./mms-deploy.sh --d                     # DRY RUN: rehearse whichever lane the branch selects
./mms-deploy.sh                         # deploy the current branch's lane
```

`mms-deploy` is the single entry point. In one pass it: sweeps orphaned client jars,
reconciles/cuts releases for our own mods, runs `packwiz update -a` + `refresh`, commits
and pushes, then syncs `side=both`/`server` mods into the live server's mods folder. You
rarely need raw `packwiz`; reach for it only when debugging.

**Deploy flags** (case matters; read carefully):
- `mms-deploy --m`: switch to **main** and deploy it, which **touches the LIVE server**.
- `mms-deploy --t`: switch to **testing** and deploy the staging lane.
- `mms-deploy --M`: **merge** testing into main (strips quarantine), then **stop** (ships nothing).
- `mms-deploy --d`: dry run.

> WARNING: `--m` (deploy prod) and `--M` (merge only) differ **only in case** and are opposites in
> blast radius. When in doubt use the long forms `--main` / `--merge`, or run `--d` first.

That's the whole update loop. No client action required beyond launching.

### Notes for maintainers
- **6 bundled jars** are hosted from this repo's `mods/*.jar` at `raw.githubusercontent.com/.../mods/<jar>`:
  `ks-support`, `mms-mod-compat-support`, `camera-glue` (ours), `modmetro` (patched fork),
  `disablemod` (CurseForge-only), `towerinator` (not on any platform). Update one with
  `./mms-add.sh -u /path/to/<new>.jar` (it rewrites `filename`/`url`/`hash` and refreshes for you).
- Everything else (**236 mods**) is a weightless Modrinth/CurseForge CDN reference.
- `fabric-api`, `sodium`, and `voxy` are provided by the base instance and intentionally **not** re-added here.
- **Client-only mods must be `side = "client"` in their `mods/*.pw.toml`.** A cosmetic/render
  mod left at `side = "both"` gets installed on the server, where its client mixins target
  client-only classes (e.g. `class_759` ItemInHandRenderer) and crash the server during mixin
  PREPARE. If you see a startup crash ending in a `*.mixins.json:client.*` `InvalidMixinException`,
  find that mod and set it to `client`, then `packwiz refresh`. (Inspect Animations was the
  culprit here.) **packwiz won't delete a jar it already dropped on the server**; after the fix,
  manually `rm mods/<mod>-*.jar` in the server's mods folder or the crash repeats on next boot.
- The `.mrpack` is a build artifact (git-ignored). Regenerate a seed/backup with
  `packwiz modrinth export`; attach it to a GitHub Release rather than committing it.
</content>

## Testing lane (staging -> prod)

A `testing` branch of this pack + a `MMSTesting01` server + a second (offline)
client instance let you validate fixes with two players before they reach prod.
Unreleased builds ride a filesystem **overlay** (they have no packwiz download
URL); everything already released flows through the branch normally.

```
main -----o-------------o   prod:  MMSLive01 + prod clients  (mms-deploy.sh)
          \           /
testing    o--o--o--o       test:  MMSTesting01 + "MMS Live II"  (mms-deploy-test.sh)
           drop dev jars, test w/ 2 offline clients, then promote
```

**Iterate on a fix**
1. Add the mod's repo slug to `overlay.list` (e.g. `mms-mod-compat-support`).
2. Build the jar, then on the `testing` branch run `./mms-deploy-test.sh`
   pushes the branch (test client pulls it), syncs released mods to
   MMSTesting01, and overlays the dev jar on both server and test client.
3. Launch two clients (see below) and test.

**Promote to prod** `./mms-promote.sh` (warns about active overlays, merges
`testing -> main`, then runs `mms-deploy.sh` which cuts the GitHub release and
syncs MMSLive01). Afterwards clear the slug from `overlay.list`.

**Scripts** (all live at the repo root; `mms-deploy` orchestrates most of them)

*Edit the pack*
- `mms-add.sh` add a mod (Modrinth slug/url, or bundle a local jar; `-u` updates a bundled jar).
- `mms-remove.sh` remove a mod + its config leftovers (`-n` dry run, `-y` no prompt).

*Ship*
- `mms-deploy.sh` the single ship entry point; branch picks the lane (see flags above).
- `mms-deploy-prod.sh` / `mms-deploy-test.sh` the prod and staging lanes (called by `mms-deploy`).
- `mms-promote.sh` merge validated `testing` -> `main` (strips quarantine), then prod deploy.
- `mms-ship.py` the "release half"; brings every MMS mod's GitHub release up to date, in build order.
- `mms-release.sh` cut one mod's release and repoint the pack (`--all` for every releasable repo).
- `mms-server-sync.py` sync `side=both`/`server` mods into a server's mods folder (prod + test).

*Guards / housekeeping*
- `mms-client-sweep.py` remove orphaned duplicate-mod-id jars from a client instance.
- `mms-config-reconcile.py` pull `config/` changes from a client instance back into the repo.
- `mms-netdrift-check.py` flag network-path mods that overlap or sit on only one side.
- `mms-entity-sweep.py` find orphaned marker entities in saved world data.
- `mms-repos.py` / `mms-repos.toml` the repo manifest and its lens (`list`/`graph`/`drift`/...).

*Dev / hotswap client*
- `mms-dev-setup.sh` one-time setup for the "MMS Dev" hotswap client.
- `mms-dev-serve.sh` serve the local `testing` checkout to the MMS Dev client.
- `mms-hotswap-watch.sh` recompile a mod on save and push classes into the running game.
- `mms-overlay-apply.sh <mods_dir>` drop locally-built dev jars from `overlay.list` into a folder.

**Two offline clients on one machine**
- Server: `MMSTesting01/server.properties` has `online-mode=false` (test box only).
- Prism -> Settings -> Minecraft -> enable "Allow running multiple instances".
- Prism -> Accounts -> Add Offline (e.g. `Tester2`).
- The test client instance ("MMS Live II") points packwiz-installer at the
  `testing` branch and runs `mms-overlay-apply.sh` after, via its PreLaunchCommand.

---

## Our own mods: the release engine

We build ~10 first-party Fabric mods (mms-animation, mms-vanity, mms-origins,
mms-jobs, mms-metro, mms-mod-compat-support, mms-render-common, camera-glue,
ks-support). They all ship through **one
centralised, tree-driven release path** instead of a per-repo copy that drifts.

**One reusable CI engine.** `.github/workflows/mod-release.yml` in *this* repo is
a `workflow_call` engine every mod repo invokes. Each mod repo carries only a
~20-line caller stub (`.github/workflows/release.yml`, identical to
[`_caller-template.yml`](.github/workflows/_caller-template.yml)). The engine
**derives everything from the calling repo's own tree**, so a new repo needs no
change to the engine:
- needs the private `mms-libs` jars? -> it greps `build.gradle` for `files("libs/...")`
- which sibling composite builds? -> it reads `settings.gradle` `includeBuild`
  lines, transitively, and builds them bottom-up
- what version? -> `gradle.properties` `mod_version` (the requested version is
  authoritative and is stamped into the jar; releases never walk backwards)

Sibling wiring is standardised: every repo with an `includeBuild` uses
`providers.gradleProperty('mmsSiblingRoot').getOrElse('..')` with a **quoted**
path ending in the repo name, so both the engine and `mms-repos.py` can discover
the graph by reading exactly that line.

**One manifest.** [`mms-repos.toml`](mms-repos.toml) is the authoritative *list*
of repos and each one's role (`library` vs `mod`), and nothing else, because
everything else is discovered. [`mms-repos.py`](mms-repos.py) is the lens over it:

```bash
./mms-repos.py list            # role, version, libs, pack pin, siblings
./mms-repos.py graph           # dependency edges + bottom-up build order
./mms-repos.py drift           # every place source / pack pin / release disagree
./mms-repos.py releasable      # repos whose source is ahead of the pack pin
./mms-repos.py check-callers   # every repo's release.yml still matches the template
```

`drift` and `check-callers` exit non-zero on problems, so they double as guards.

**Releasing.** `mms-release <repo>` cuts a tagged GitHub release for one mod and
repoints the pack at it (see the script header). `mms-release --all` fans out
over `mms-repos.py releasable` in build order. `mms-deploy` prints a
(non-blocking) drift heads-up before it ships, so you notice a local bump you
never released, or a release the pack hasn't picked up.

**Adding a mod:** create the repo with the standard tree, drop in the caller stub
(`cp .github/workflows/_caller-template.yml <repo>/.github/workflows/release.yml`),
add one line to `mms-repos.toml`. That's it.
