# MMS Live: Minecraft Modpack

**Minecraft 1.21.11 | Fabric loader 0.20.1 | Java 21 | pack version 2.6.0**

This repo is a [packwiz](https://packwiz.infra.link/) pack, which means once
your launcher is pointed at it, **you get every update automatically just by launching the game**.
No re-downloading, no re-importing, no reinstalling for a single config change.

To make that work you need a **packwiz-aware launcher**. We use **[Prism Launcher](https://prismlauncher.org/)**
(free, open-source). ATLauncher and the CurseForge/Modrinth apps do **not** auto-update packwiz packs.
Please switch to Prism.

---

## One-time setup (~5 minutes)

### 1. Install Prism Launcher
Download from **https://prismlauncher.org/download/** and sign in with your Microsoft account
(Prism -> *Accounts* -> *Add Microsoft account*).
![alt text](https://save.mudbourn.info/s/sAHdDkxDMdjM5re/download "Graph")

### 2. Create the instance
- Click **Add Instance**.
- Name it `MMS Live`.
- Choose **Minecraft 1.21.11**.
- Click **Fabric** and select loader version **0.20.1**.
- Create the instance. **Don't add any mods by hand yet**, the pack installs them for you.
![alt text](https://save.mudbourn.info/s/mgFTSBj6qxxxKJM/download "Graph")

### 3. Drop in the packwiz installer
- Download **`packwiz-installer-bootstrap.jar`** from
  https://github.com/packwiz/packwiz-installer-bootstrap/releases (grab the latest `.jar`).
![alt text](https://save.mudbourn.info/s/JLmZypmfEHSbACm/download "Graph")
- Click the instance -> **Folder** -> open the **`minecraft`** subfolder.
- Put `packwiz-installer-bootstrap.jar` in there.
![alt text](https://save.mudbourn.info/s/pwG95t3jRXRR9ZZ/download "Graph")

### 4. Turn on auto-update
- Right-click the instance -> **Edit** -> **Settings** -> **Custom commands**.
- Tick **Ovweeide Global Settings**.
- In the **Pre-launch command** box, paste **exactly one** of these:

  **Standard** (most PCs, full visuals):
  ```
  "$INST_JAVA" -jar packwiz-installer-bootstrap.jar https://raw.githubusercontent.com/mudbourn/mms-pack/main/pack/pack.toml
  ```

  **Octane** (low-end PCs: no shaders, animation packs or ambient extras, lighter defaults):
  ```
  "$INST_JAVA" -jar packwiz-installer-bootstrap.jar https://raw.githubusercontent.com/mudbourn/mms-pack/octane/pack/pack.toml
  ```

  Both join the same server. To switch later, swap the command and relaunch.

- Close.
![alt text](https://save.mudbourn.info/s/YDNAdrSyDrALRiz/download "Graph")

## **ALL users:** 
> right-click the instance -> **Edit** -> **Settings** -> **Java**. Tick **Memory** and set
> **Minimum** and **Maximum** to a **comfortably low number**. 
> I've tested with a maximum of both **4096** and **2048** on separate occasions and both work well.
> Tick **Java Arguments** and paste:
> ```
> -XX:+UseG1GC -XX:+UnlockExperimentalVMOptions -XX:+ParallelRefProcEnabled -XX:MaxGCPauseMillis=37 -XX:G1NewSizePercent=23 -XX:G1MaxNewSizePercent=50 -XX:G1HeapRegionSize=16M -XX:G1ReservePercent=20 -XX:G1MixedGCCountTarget=3 -XX:InitiatingHeapOccupancyPercent=20 -XX:G1RSetUpdatingPauseTimePercent=0 -XX:SurvivorRatio=32 -XX:MaxTenuringThreshold=1 -XX:G1SATBBufferEnqueueingThresholdPercent=30 -XX:G1ConcMarkStepDurationMillis=5 -XX:+UseStringDeduplication -XX:+PerfDisableSharedMem -XX:+DisableExplicitGC -XX:+HeapDumpOnOutOfMemoryError -XX:HeapDumpPath=heapdumps
> ```
>
> **Adding shaders or Distant Horizons?** Neither ships with the pack, but both work with it.
> Distant Horizons needs more memory: set **Maximum** to about **6144**, and only if your PC has 16 GB of RAM or more.
> Shaders mostly use your GPU, not the Java memory above, so leave some RAM free for them.
> Keep the Java Arguments above. Distant Horizons may suggest switching away from G1, but ignore that: ZGC has crashed the game with this pack.
![alt text](https://save.mudbourn.info/s/FXq8yKqbQCJKJab/download "Graph")

### 5. Launch
Hit **Launch**. On every launch the installer checks this repo and downloads/updates only what changed,
then the game starts. First launch pulls the whole pack (a few minutes); after that updates are tiny.
![alt text](https://save.mudbourn.info/s/HZqGk7BFcwn58pK/download "Graph")


> **Server address:** ( mc.mudbourn.info ). Waypoints and land claims are
> server-side (Xaero + OpenPAC). They sync automatically in-game, nothing to install.

---

## Troubleshooting

| Problem |


"Cannot find packwiz-installer-bootstrap.jar"

Prelaunch window closes instantly / mods missing

A mod update broke something



| Fix |


The jar must be inside `minecraft/`, not the instance root. Re-check step 3.

Confirm the pre-launch box is the **exact** line above, quotes included.

Tell an admin the mod + symptom; the pack is rolled forward centrally, then just relaunch.
