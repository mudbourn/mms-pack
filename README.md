# MMS Live — Minecraft Modpack

**Minecraft 1.21.11 · Fabric loader 0.19.3 · Java 21 · pack version 2.4.0**

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

### 2. Create the instance
- Click **Add Instance**.
- Name it `MMS Live`.
- Choose **Minecraft 1.21.11**.
- Click **Fabric** and select loader version **0.19.3** (or newest 1.21.11-compatible).
- Create the instance. **Don't add any mods by hand** — the pack installs them for you.

### 3. Drop in the packwiz installer
- Download **`packwiz-installer-bootstrap.jar`** from
  https://github.com/packwiz/packwiz-installer-bootstrap/releases (grab the latest `.jar`).
- Right-click the instance → **Folder** → open the **`.minecraft`** subfolder
  (same place as `options.txt`).
- Put `packwiz-installer-bootstrap.jar` in there.

### 4. Turn on auto-update
- Right-click the instance → **Edit** → **Settings** → **Custom commands**.
- Tick **Custom Commands**.
- In the **Pre-launch command** box, paste **exactly**:

  ```
  "$INST_JAVA" -jar packwiz-installer-bootstrap.jar https://raw.githubusercontent.com/mudbourn/mms-pack/main/pack.toml
  ```

- Save.

### 5. Launch
Hit **Play**. On every launch the installer checks this repo and downloads/updates only what changed,
then the game starts. First launch pulls the whole pack (a few minutes); after that updates are tiny.

> **Server address:** ask an admin for the current connect address. Waypoints and land claims are
> server-side (Xaero + OpenPAC) — they sync automatically in-game, nothing to install.

---

## Troubleshooting

| Problem | Fix |
|---|---|
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
