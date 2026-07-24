# Credits

Third-party assets bundled in this repository, with their licenses. Crusade only
vendors assets whose licenses permit redistribution — **CC0 / public domain**
(preferred) or **CC-BY** (attribution required, recorded here).

## Art

### Terrain tiles — "1000+ Isometric Floor Tiles"
- **Author:** Screaming Brain Studios — https://opengameart.org/users/screaming-brain-studios
- **Source:** https://opengameart.org/content/1000-isometric-floor-tiles
- **License:** CC0 1.0 (Public Domain) — https://creativecommons.org/publicdomain/zero/1.0/
- **Used in:** `assets/tilesets/terrain_atlas.png`, composited from the vendored
  source sheets in `assets/tilesets/sources/` by `tools/pack_terrain_atlas.py`.
- **Note:** CC0 requires no attribution; this entry is a courtesy acknowledgement.

### Doodad decor, campfire & light cookies — procedurally generated (project-owned)
- **Author:** Crusade project (generated, not third-party).
- **Source:** `assets/doodads/doodads.png` (rocks, bushes, grass tufts, flowers,
  pebbles) and `assets/doodads/campfire.png` (fire-pit + logs + flame), drawn
  deterministically by `tools/gen_doodads.py`; `assets/lights/point_light.png`
  is a generated soft radial cookie used for cliff cast-shadows and showcase glow;
  `assets/cliffs/cliffs.png` (rocky cliff faces, `tools/gen_cliffs.py`) and
  `assets/doodads/trees.png` (canopy trees, `tools/gen_trees.py`) are likewise generated.
- **License:** covered by the repository's own MIT license — no third-party terms.
- **Note:** listed here only to make provenance explicit; there is no external
  pack or attribution obligation.
