# MMS Live — Minecraft Modpack

**Minecraft 1.21.11 · Fabric loader 0.19.3 · Java 25 · pack version 2.5.2**

> ⚠️ **Java 25 required.** Prism defaults new 1.21.11 instances to Java 21, which crashes on launch
> (C2ME's `opts-natives-math` needs Java 25). Set it per the instructions in step 2 below.

This repo *is* the modpack. It's a [packwiz](https://packwiz.infra.link/) pack, which means once
your launcher is pointed at it, **you get every update automatically just by launching the game** —
no re-downloading, no re-importing, no reinstalling for a single config change.

To make that work you need a **packwiz-aware launcher**. We use **[Prism Launcher](https://prismlauncher.org/)**
(free, open-source). ATLauncher and the CurseForge/Modrinth apps do **not** auto-update packwiz packs —
please switch to Prism.

---

## Players: one-time setup (~5 minutes)

### 1. Install Prism Launcher
Download from **https://prismlauncher.org/download/** and sign in with your Microsoft/Minecraft account
(Prism → *Accounts* → *Add Microsoft account*).
![alt text](https://save.mudbourn.info/s/sAHdDkxDMdjM5re/download "Graph")

### 2. Create the instance
- Click **Add Instance**.
- Name it `MMS Live`.
- Choose **Minecraft 1.21.11**.
- Click **Fabric** and select loader version **0.19.3** (or newest 1.21.11-compatible).
- Create the instance. **Don't add any mods by hand yet** — the pack installs them for you.
![alt text](https://save.mudbourn.info/s/mgFTSBj6qxxxKJM/download "Graph")

- Set up Java 25 (Prism downloads it for you — no separate install needed):
  1. **Settings** → **Java** → **Installations**.
  2. Press **Download**, select the **25** option from **Mojang**, press **Download**, then **OK**.
![alt text](https://save.mudbourn.info/s/dZxY8LDMdtczFMz/download "Graph")

  Prism's default is Java 21, which **might not launch this pack**.

### 3. Drop in the packwiz installer
- Download **`packwiz-installer-bootstrap.jar`** from
  https://github.com/packwiz/packwiz-installer-bootstrap/releases (grab the latest `.jar`).
![alt text](https://save.mudbourn.info/s/JLmZypmfEHSbACm/download "Graph")
- Click the instance → **Folder** → open the **`.minecraft`** subfolder.
- Put `packwiz-installer-bootstrap.jar` in there.
![alt text](https://save.mudbourn.info/s/pwG95t3jRXRR9ZZ/download "Graph")

### 4. Turn on auto-update
- Right-click the instance → **Edit** → **Settings** → **Custom commands**.
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
> server-side (Xaero + OpenPAC) — they sync automatically in-game, nothing to install.

---

## Troubleshooting

| Problem | Fix |
|---|---|
| Crash: "requires version 25 or later of 'OpenJDK'" (C2ME / natives-math) | Instance is on Java 21. Set Java 25 in instance Settings → Java (see step 2). |
| "Cannot find packwiz-installer-bootstrap.jar" | The jar must be inside `.minecraft/`, not the instance root. Re-check step 3. |
| Prelaunch window closes instantly / mods missing | Confirm the pre-launch box is the **exact** line above, quotes included. |
| Want to see what it's doing | Remove nothing — the installer prints progress in a small window each launch. |
| A mod update broke something | Tell an admin the mod + symptom; the pack is rolled forward centrally, then just relaunch. |

---

## Admins: publishing an update

The pack is edited with the `packwiz` CLI, then pushed here. Clients pick it up on their next launch.

```bash
export PATH="$HOME/go/bin:$PATH"
cd path/to/mms-pack        # your local clone of this repo

# add / change mods
packwiz modrinth add <slug-or-version-url>     # CDN mod (preferred)
packwiz update --all                           # bump everything to latest compatible
# bundled (unhosted) jars live in mods/*.jar and are served from this repo's raw URLs

# bump the pack version in pack.toml (version = "2.4.1", etc.), then:
packwiz refresh
git add -A && git commit -m "pack: <what changed>" && git push
```

That's the whole update loop — no client action required beyond launching.

### Notes for maintainers
- **6 bundled jars** are hosted from this repo's `mods/*.jar` at `raw.githubusercontent.com/.../mods/<jar>`:
  `ks-support`, `mms-mod-compat-support`, `camera-glue` (ours), `modmetro` (patched fork),
  `disablemod` (CurseForge-only), `towerinator` (not on any platform). Update these by replacing the jar
  **and** its `mods/<name>.pw.toml` (`filename`, `url`, `hash`), then `packwiz refresh`.
- Everything else (**236 mods**) is a weightless Modrinth/CurseForge CDN reference.
- `fabric-api`, `sodium`, and `voxy` are provided by the base instance and intentionally **not** re-added here.
- The `.mrpack` is a build artifact (git-ignored). Regenerate a seed/backup with
  `packwiz modrinth export`; attach it to a GitHub Release rather than committing it.
</content>

## Testing lane (staging → prod)

A `testing` branch of this pack + a `MMSTesting01` server + a second (offline)
client instance let you validate fixes with two players before they reach prod.
Unreleased builds ride a filesystem **overlay** (they have no packwiz download
URL); everything already released flows through the branch normally.

```
main ──●─────────────●   prod:  MMSLive01 + prod clients  (mms-deploy.sh)
        \           /
testing  ●──●──●──●      test:  MMSTesting01 + "MMS Live II"  (mms-deploy-test.sh)
         drop dev jars, test w/ 2 offline clients, then promote
```

**Iterate on a fix**
1. Add the mod's repo slug to `overlay.list` (e.g. `mms-mod-compat-support`).
2. Build the jar, then on the `testing` branch run `./mms-deploy-test.sh` —
   pushes the branch (test client pulls it), syncs released mods to
   MMSTesting01, and overlays the dev jar on both server and test client.
3. Launch two clients (see below) and test.

**Promote to prod** — `./mms-promote.sh` (warns about active overlays, merges
`testing → main`, then runs `mms-deploy.sh` which cuts the GitHub release and
syncs MMSLive01). Afterwards clear the slug from `overlay.list`.

**Scripts**
- `mms-server-sync.py` — shared server-mod sync (prod + test both use it).
- `mms-overlay-apply.sh <mods_dir>` — apply `overlay.list` dev jars to a folder.
- `mms-deploy-test.sh` — staging deploy (testing branch → test server + client).
- `mms-promote.sh` — merge up + prod deploy.

**Two offline clients on one machine**
- Server: `MMSTesting01/server.properties` has `online-mode=false` (test box only).
- Prism → Settings → Minecraft → enable "Allow running multiple instances".
- Prism → Accounts → Add Offline (e.g. `Tester2`).
- The test client instance ("MMS Live II") points packwiz-installer at the
  `testing` branch and runs `mms-overlay-apply.sh` after, via its PreLaunchCommand.
