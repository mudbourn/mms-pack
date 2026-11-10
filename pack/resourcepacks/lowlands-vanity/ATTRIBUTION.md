# Sources

This pack supplies textures for armour sets ported forward to 1.21.11 equipment
assets. The geometry that goes with them lives in the mms-vanity mod that ships
this pack (`info.mudbourn.mmsvanity.client.lowlands`); neither half renders
correctly without the other.

## Weavers Paradise - `assets/weaversparadise/`

Textures from [Weavers Paradise](https://modrinth.com/mod/weavers-paradise) by
Vortianski. Source: <https://github.com/Vortianski/Weavers-Paradise>.

Unmodified apart from being renamed to the equipment-asset ids and moved into the
`humanoid` layer directory. Each set ships one whole-body atlas, so there is no
`humanoid_leggings` entry - see `LowlandsArmorModel.TextureLayout.SINGLE`.

Sets used: Astolfo, Bridget, Felix, Gabriel, Giselle, Griffith, Mikkela, Niko.

**Licence:** the project declares `mod_license=MIT` in `gradle.properties`, and
Modrinth lists it as MIT. The repository ships **no `LICENSE` file** - the only
licence text in it is `TEMPLATE_LICENSE.txt`, which is NeoForged's MDK boilerplate
and covers the template files, not this mod's assets.

MIT requires the copyright notice to travel with redistributed copies, and there is
none upstream to copy. This pack supplies one at `assets/weaversparadise/LICENSE`:
the standard MIT terms with the copyright attributed to Vortianski (2025-2026, from
the upstream repository's own history), so a notice travels with these copies as
MIT requires.

## Armor of the Ages - `assets/armoroftheages/`

Textures, item models and names from
[Armor of the Ages](https://modrinth.com/mod/armor-of-the-ages) by Poulpinou and
TheGoldenWorld, declared MIT; notice at `assets/armoroftheages/LICENSE`. The
`geo/`, `animations/` and `geo_armor/` files are generated from the mod's Java
models by mms-render-common's `tools/java_model_to_geo.py`. Patreon-tier skins are
not included.

## Clothing of the Lowlands - `assets/lowlands_clothing/`

Textures from **Clothing of the Lowlands** by **Anton_Vaedak**. All rights
reserved by the original author; **not** covered by any licence on the surrounding
projects.

Use here is by the author's direct permission, granted 2026-08-16, under these
terms:

- Visible attribution to Anton_Vaedak and Clothing of the Lowlands is required,
  and players must be able to see that these assets are from his mod. In-game
  credit is provided via item tooltips (stamped by the vanity mod) and here.
- Non-commercial only. This pack, and the server and modpack it ships with, must
  not be monetized.
- No third-party redistribution. The author's condition: any use of the assets
  that can be tracked down to redistributed assets from the server "will not be
  tolerated." These assets travel only inside this project's own modpack: they are
  git-ignored (see the repo `.gitignore`), are not published to packwiz, Modrinth
  or any other index, and must not be repackaged or redistributed by third
  parties. Publishing them as a standalone download is a distribution form the
  grant does not cover.
