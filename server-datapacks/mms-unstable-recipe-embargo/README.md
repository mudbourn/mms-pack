# mms-unstable-recipe-embargo

Closes the **crafting** route into the unstable mods. Companion to
`mms-unstable-vanilla-embargo` (worldgen and mob spawns) and
`mms-ddd-no-natural-gen` (DDD structures). All three should ship together.

## Why this is needed

The other two packs stop the unstable mods appearing in the world. That is not
enough on its own: a recipe whose ingredients are all vanilla is reachable by
any player regardless of whether the mod generates anything, because the inputs
never had to come from the mod.

Auditing every recipe in the three jars that ship recipes:

| mod | recipes | reachable from vanilla ingredients alone |
|---|---|---|
| Aerial Hell | 706 | 11 |
| Useless Reptile | 24 | 11 |
| Mutant Monsters | 7 | **0** |
| Deadly Deadly Dungeon | 0 | — |

The other 706 need a modded ingredient somewhere up the chain, and those
ingredients only come from mobs and structures the other two packs have already
switched off. They are left alone deliberately — see *Scope* below.

## What is stubbed

**20 recipes**, being the 22 vanilla-reachable ones minus the two whose result
is a vanilla item (see below). Each is overridden with the house embargo stub
already used by `server_embargo` for jeg, rubies and modmetro:

```json
{
  "type": "minecraft:crafting_shapeless",
  "ingredients": ["#mms_embargo:never"],
  "result": { "id": "minecraft:stone", "count": 1 }
}
```

`#mms_embargo:never` is an empty item tag, so the recipe can never match. The
tag is redefined here with `"replace": false` so this pack is self-contained but
still merges cleanly with `server_embargo`'s copy.

Six of the twenty were **custom recipe types** — `aerialhell:freezing`,
`aerialhell:oscillating`, `uselessreptile:vortex_horn`. Overriding them with a
`minecraft:crafting_shapeless` stub means the original no longer exists in its
own registry, so the mechanic finds nothing and does nothing. The stub schema is
known-good, which a hand-written override of an undocumented custom type would
not be.

Note that a custom type also means the *mechanism* may not have been reachable
in the overworld to begin with — that was not verified, only the ingredients
were. Stubbing them costs nothing either way.

## Deliberately left alone

Two Aerial Hell `freezing` recipes produce **vanilla** results:

| recipe | result |
|---|---|
| `ice_from_iron_bucket_freezing` | `minecraft:ice` |
| `packed_ice_freezing` | `minecraft:packed_ice` |

These add a route to a vanilla item rather than inserting a mod item into the
game, so they fall outside the stated goal. Revisit if the freezing mechanic
turns out to be reachable and the extra ice route is unwanted.

## Loot tables are not a concern

None of the four mods injects into vanilla loot tables — not by data
(`data/minecraft/` in all four jars contains only block/item/entity_type and
damage_type tags) and not by code (zero `LootTableEvents` references in any of
them). There is nothing to override.

## Install

```
<world>/datapacks/mms-unstable-recipe-embargo/
```

Prod's world is `world`; Testing's is `new`. Requires a restart or `/reload`.
Unlike the worldgen packs this applies immediately and retroactively — a player
holding an already-crafted item keeps it, but cannot craft another.

## Scope

Pinned to `aerialhell-0.7.7.7_fabric1.21.11`,
`useless-reptile-0.12.3-1.21.11` and
`MutantMonsters-v21.11.2-mc1.21.11-Fabric`. The audit is a snapshot: a mod
update that adds a recipe with all-vanilla ingredients reopens the hole. Re-run
the audit on update rather than assuming this list still holds.

The 706 untouched recipes are only safe for as long as the other two packs hold.
If a quarantined mod is ever promoted, or its spawns/structures re-enabled, this
pack stops being sufficient on its own.
