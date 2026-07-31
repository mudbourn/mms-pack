# mms-unstable-vanilla-embargo

Keeps the unstable mods from creating or adding anything in the **overworld,
nether, or end**. Their own dimensions are untouched — this is a dimension
boundary, not a content embargo. Nothing here blocks items, recipes, or
creative access; those are the item-embargo layers and are separate.

Covers three of the four unstable mods. Deadly Deadly Dungeon is handled by its
own pack, `mms-ddd-no-natural-gen`, which already does exactly this job for DDD
and should ship alongside this one.

## Aerial Hell

Of the thirteen `has_structure` biome tags in `aerialhell-0.7.7.7_fabric1.21.11`,
exactly one names vanilla biomes:

| tag | biomes |
|---|---|
| `overworld_abandonned_portal` | 11 vanilla tags, including `#minecraft:is_nether` |

Every other AH structure is scoped to `#aerialhell:is_*` — its own biomes, its
own dimension. This pack overrides that one tag with `"replace": true` and an
empty `values` list, so no vanilla biome hosts it.

**The stellar portal frame ore is not a concern on Fabric.** It is placed only
by `data/aerialhell/forge/biome_modifier/overworld_stellar_portal_frame_ore.json`,
which is a Forge/NeoForge biome modifier — Fabric never reads that directory,
and no class in the jar touches Fabric's `BiomeModifications`. The ore does not
generate in the overworld to begin with. Do not add a placed-feature override
for it; there is nothing to override.

With the structure tag emptied, AH has **no** remaining natural footprint in the
vanilla dimensions. Portal access becomes hand-placement only, which is what the
one-portal dungeon design wants.

## Mutant Monsters and Useless Reptile

Both add their mob spawns through Fabric's `BiomeModifications` in code, and
both gate that code on a **blacklist** biome tag — a biome listed in the tag
does not get the spawn. That makes the tag the intended lever, and it means
these entries append rather than replace.

| mod | tags | upstream contents |
|---|---|---|
| Mutant Monsters | `without_mutant_{creeper,enderman,skeleton,zombie}_spawns` | empty, except enderman = `minecraft:the_end` |
| Useless Reptile | `{lightning_chaser,magmamuncher,moleclaw,river_pikehorn,wyvern}_spawn_blacklist` | `#c:no_default_monsters` |

Each is overridden with `"replace": false` plus `#minecraft:is_overworld`,
`#minecraft:is_nether`, and `#minecraft:is_end`. Upstream values survive, so
Mutant Monsters keeps its own end exclusion and Useless Reptile keeps honouring
`#c:no_default_monsters`.

Neither mod adds a dimension, so in practice this stops their natural spawns
everywhere. Both remain fully summonable and usable — this is spawn placement
only.

## What this deliberately does not do

- **No structure or entity is unregistered.** As with the DDD pack, natural
  placement is off but `/place structure` and `/summon` still work, because
  `/place` passes a biome predicate that always returns true and bypasses the
  tag. Hand-placement stays available for testing and for sited content.
- **No mob already spawned is removed.** This gates placement, not existing
  entities.
- **Only chunks generated after install are affected**, for the AH structure.
  The spawn blacklists apply immediately on reload.

## Known gap

The three `#minecraft:is_*` tags cover biomes that declare themselves part of a
vanilla dimension. A modded overworld biome from some other pack mod that never
joins `#minecraft:is_overworld` would not be blacklisted, and mutant/reptile
spawns could still occur there. Worth re-checking if a biome mod is ever added.

## Install

World datapacks load after mod-provided ones, which is what lets this override
the mods' own tags. Drop the folder in:

```
<world>/datapacks/mms-unstable-vanilla-embargo/
```

Testing server's world is `new`; prod's is `world`. Requires a restart or
`/reload`. `mms-deploy.sh` does not currently sync `server-datapacks/` — these
are placed by hand.

## Scope

Pinned to `aerialhell-0.7.7.7_fabric1.21.11`, `MutantMonsters-v21.11.2-mc1.21.11-Fabric`,
and `useless-reptile-0.12.3-1.21.11`. If any of them adds a structure or a mob
with a new tag, that addition generates until its tag is added here. Re-audit on
mod update.
