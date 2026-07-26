# mms-ddd-no-natural-gen

Stops Deadly Deadly Dungeon from placing any of its structures during worldgen,
so the server's dungeon can be sited by hand and treated as the one official
dungeon rather than one of many.

## How it works

Every DDD structure gates its placement on a biome tag:

| structure | biome tag |
|---|---|
| `minor_dungeon_plains`, `major_dungeon_plains` | `ddd:has_new_dungeon/dungeon_plains` |
| `minor_dungeon_desert`, `major_dungeon_desert` | `ddd:has_new_dungeon/dungeon_desert` |
| `minor_dungeon_frozen`, `major_dungeon_frozen` | `ddd:has_new_dungeon/dungeon_frozen` |
| `monolithic_tower`, `wizard_tower` | `ddd:has_new_dungeon/monolithic_tower` |
| `spider_lair` | `ddd:has_new_dungeon/spider_lair` |

This pack overrides all five with `"replace": true` and an empty `values` list.
No biome is a valid host, so nothing generates.

The structures themselves are left registered and untouched. That is the point
of using biome tags rather than emptying the two `structure_set` files or
removing the structures: `/place structure` passes a biome predicate that always
returns true, so it bypasses the tag entirely and still works. Manual placement
keeps functioning while natural placement is off.

The `major_dungeon_*` structures were already absent from both of DDD's
structure sets upstream, so they never generated naturally to begin with.

## Placing the official dungeon

```
/place structure ddd:major_dungeon_plains <x> <y> <z>
```

Swap in whichever of the nine structures suits the site. `/place` ignores biome
but not everything else — the jigsaw still resolves against terrain, so give it
open ground and expect the result to differ from a natural placement.

## Install

World datapacks load after mod-provided ones, which is what lets this override
DDD's own tags. Drop the folder in:

```
<world>/datapacks/mms-ddd-no-natural-gen/
```

Testing server's world is `new`; prod's is `world`. Requires a restart or
`/reload` followed by regenerating any chunks that already contain dungeons —
this only affects chunks generated after it is installed.

## Scope

Tied to DDD's tag layout as of `1.0.6+mod`. If a DDD update adds a structure
with a new biome tag, that structure will generate naturally until its tag is
added here.
