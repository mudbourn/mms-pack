# mms-alexscaves-embargo

Keeps **Alex's Caves** (and its delight add-on, `accdelight`) out of the world
while the mod is embargoed. The mod stays installed; nothing it adds is placed,
looted, traded or craftable from vanilla. `/give`, `/summon` and `/place` still
work for testing.

Alex's Caves has no dimension of its own, so the embargo has three parts. This
datapack is only one of them; the other two are config files in the pack.

## 1. Biomes — `config/alexscaves_biome_generation/*.json`

The six cave biomes are not placed through biome tags or TerraBlender. AC
swaps them in from a `MultiNoiseBiomeSource` mixin, gated per biome by these
config files. Each file sets `"disabled_completely": true`, which makes the
biome's noise test fail before anything else is checked.

Every other field is AC's own default. The files must stay complete: AC
rewrites a file it reads as the old format (no `dimensions` and not disabled).

Every AC structure except the Underground Cabin is restricted to one of its
own biomes, so turning the biomes off also stops all of them.

## 2. Loot, trades and mobs — `config/alexscaves-general.toml`

`[vanilla-changes]`:

| key | was | now | what it injects |
|---|---|---|---|
| `*_tablet_loot_chance` (5) and `candy_cavity_loot_chance` | 0.15–0.9 | 0.0 | Cave Tablets in bastions, temples, mansions, ruins, archaeology |
| `cabin_map_loot_chance` | 0.15 | 0.0 | Cabin maps in mineshaft chests |
| `cartographers_sell_cabin_maps` | true | false | Cartographer trade |
| `wandering_traders_sell_cabin_maps` | true | false | Wandering Trader trade |
| `loot_chest_in_witch_huts` | true | false | Extra AC chest placed in swamp huts |

`[mob-spawning] drowned_diving_gear_spawn_chance` goes to 0.0, so Drowned no
longer spawn wearing AC diving suits. Every other key keeps its default.

AC's tablet loot also returns 0 by itself for any biome that is disabled, so
the tablet chances are covered twice.

## 3. This datapack

- `alexscaves:has_underground_cabins` is replaced with an empty list. Upstream
  it is `#minecraft:stronghold_biased_to`, which is most overworld biomes.
  This is the only AC structure that uses vanilla biomes.
- **8 recipes** can be crafted from vanilla ingredients alone. Each is
  replaced with the house embargo stub (`#mms_embargo:never`, an empty tag):

| recipe | result |
|---|---|
| `bone_nodule` | Bone Nodule |
| `cinder_brick` | Cinder Brick |
| `cookie_block` | Cookie Block |
| `fern_thatch` | Fern Thatch |
| `furnace/smooth_bone_smelting` | Smooth Bone |
| `hollow_bone` | Hollow Bone |
| `metal_barrel_from_iron` | Metal Barrel |
| `thin_bone` | Thin Bone |

Every other AC recipe, and all of `accdelight`'s, needs an AC item that only
comes from the biomes, loot or trades switched off above.

## Install

- Datapack: `<world>/datapacks/mms-alexscaves-embargo/` (Testing's world is
  `new`, prod's is `world`). Applies on `/reload`.
- Configs: copy `alexscaves-general.toml` and the
  `alexscaves_biome_generation/` folder into the server's `config/`. Clients
  get them through packwiz. Both need a restart.

`mms-deploy.sh` does not sync `server-datapacks/` or server configs; place by hand.

## Scope

- Only chunks generated after install are clean. Cave biomes, cabins and
  witch-hut chests already generated stay.
- Pinned to `alexscaves-1.1.3-fabric+1.21.11` and
  `accdelight-1.0.0-fabric+1.21.11`. Re-run the recipe audit after an update.
- To lift the embargo, delete the datapack and set the configs back.
