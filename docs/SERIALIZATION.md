# Map serialization contract

The canonical, versioned description of how Crusade maps are written to and read
from disk. `src/core/map_schema.gd` remains the single source of truth for field
names, versions, and limits; this document describes the **sequencing** the cores
must follow. Filed to close the scope note from Story #7 / #40.

## Cores

| Core | Responsibility |
|---|---|
| `MapSchema` | field names, `CURRENT_SCHEMA`, `REQUIRED_ROOT_KEYS`, layer kinds |
| `MapSerializer` | live `TileMapLayer`s → schema Dictionary → JSON text (no file IO) |
| `MapFileIO` | durable, atomic text read/write (no JSON/schema knowledge) |
| `MapMigrator` | migrate any older doc **up** to `CURRENT_SCHEMA` |
| `MapValidator` | structural sanitize against the live `TileSet` (drop + diagnose) |
| `MapLoader` | orchestrates parse → migrate → validate → paint |

## Save contract (atomic, crash-safe)

`MapFileIO.save_text(path, text)` must never leave a corrupt live map, even on a
crash mid-write. The sequence:

1. Ensure the parent directory exists.
2. Write the full text to a sibling **`path.tmp`**.
3. If `path` already exists, snapshot it to **`path.bak`** (`copy_absolute`); a
   failed backup warns but is non-fatal (the atomic rename still protects the
   live file). *(#45)*
4. **Windows only:** remove the existing target first — Godot's rename can fail
   over an existing file on Windows; the `.bak` snapshot covers that non-atomic
   window. On POSIX (incl. the Linux CI runner) the rename replaces atomically.
   *(#45)*
5. **`rename_absolute(path.tmp, path)`** — the atomic commit. On failure, remove
   the stale `.tmp` and return `false`.

A reader therefore only ever sees the complete previous file or the complete new
one — never a partial write.

## Load order (must not reorder)

`MapLoader` runs, in order:

```
parse (JSON) → MapMigrator.migrate → [reject future schema] → MapValidator.validate_document → clear targets → paint
```

- **parse** — JSON syntax + non-object-root are hard failures.
- **migrate** — lifts an older doc up to `CURRENT_SCHEMA`. A **future** version
  (`> CURRENT_SCHEMA`) is returned untouched (version preserved); the loader then
  **refuses** it with an explanatory error rather than mis-parsing a newer shape.
  *(#39)*
- **validate** — enforces `REQUIRED_ROOT_KEYS` (`schema_version` + `layers`)
  *(#41)*, then per-cell sanitizes against the live `TileSet`: source exists,
  atlas coord exists, and any nonzero `alt` names a real alternative tile *(#44)*.
  Invalid cells/layers are dropped and diagnosed; the rest still loads.
- **clear → paint** — every target layer is cleared first (so a layer absent from
  the doc is emptied), then cells are painted into the layer their **kind**
  resolves to.

## Layers

Each layer entry carries `name`, `elevation`, `kind`, and `cells`.

- **`kind: "terrain"`** (default) — routed by `elevation` into the elevation
  stack (`Elevation0..N`). This is the default so pre-`kind` documents still load.
- **`kind: "objects"`** — the single object overlay. Serialized at the
  `OBJECTS_ELEVATION` (`-1`) sentinel and routed by kind to `MapSystem.objects_layer`,
  never to an elevation slot. Object tiles now round-trip through save/reload
  alongside terrain. *(#43)*

## Versioning

Writers only ever emit `CURRENT_SCHEMA`. Additive **optional** fields (e.g. `alt`,
`kind`) do **not** bump the version — readers default them when absent. Bump
`CURRENT_SCHEMA` and add a `_vN_to_vN+1` migrator step only when the on-disk shape
changes incompatibly.
