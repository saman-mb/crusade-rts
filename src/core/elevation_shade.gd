class_name ElevationShade
extends RefCounted
## Pure elevation-aware shading model (Story L4, #85).
##
## The isometric map is a stack of flat TileMapLayers, one per elevation tier,
## each lifted `ELEVATION_STEP_PX` higher than the one below (MapConstants). The
## sun (L3) + normal atlas (L1) already give each diamond directional relief, and
## the day/night CanvasModulate (L2) tints the whole world — but every tier is
## lit identically, so a raised plateau reads as the same brightness as the flat
## ground it sits on. This model adds the missing height cue: a per-tier
## `modulate` ramp where HIGHER tiers catch progressively MORE light (brighter,
## with a warm sun-ward bias), so a terraced map reads with believable height.
##
## It is deliberately node-free and static so the whole ramp contract is
## headless-testable. `MapSystem` reads `shade_at(level)` once per layer into
## `TileMapLayer.modulate`; because that modulate MULTIPLIES with the day/night
## CanvasModulate, the tier contrast is preserved proportionally across the whole
## day/night cycle (a raised tier stays relatively brighter at dusk and at
## night), keeping the shading consistent with the L2/L3 lighting.
##
## Tier 0 is EXACTLY neutral white so existing single-tier maps render unchanged;
## only raised tiers are lifted. The lift is a modulate slightly above 1.0
## (Forward+ overbright), tuned to sculpt the step without blowing out mid-tones.

## Per-level brighten added to the modulate (fraction of the tint color added per
## tier). Tuned by rendered measurement (Story L4): ~+9% luminance per tier is a
## clearly readable step above the flat ground (7% was borderline-imperceptible)
## while the top tier stays well short of clipping the mid-tone grass to white.
const DEFAULT_STEP := 0.09

## Direction/color of the light added to higher tiers: warm, matching the L3 sun
## bias (`sun_color` ~ (1.0, 0.96, 0.88)), so raised ground catches "more sun"
## rather than a flat grey lift. Red >= blue keeps the lift warm.
const DEFAULT_TINT := Color(1.0, 0.95, 0.85)

## Safety ceiling on the accumulated lift so a deep stack cannot drive the
## modulate arbitrarily bright (keeps the top tiers from clipping to pure white).
const MAX_LIFT := 0.5


## Modulate color for elevation `level` (0 = ground). Level 0 (or below) is
## exactly neutral white so flat maps are unchanged; each higher tier adds
## `step` worth of the warm `tint` (clamped by MAX_LIFT), yielding a modulate
## slightly above 1.0 that brightens the tier and biases it warm.
static func shade_at(level: int, step: float = DEFAULT_STEP,
		tint: Color = DEFAULT_TINT) -> Color:
	if level <= 0:
		return Color(1.0, 1.0, 1.0, 1.0)
	var lift := minf(step * float(level), MAX_LIFT)
	return Color(1.0 + tint.r * lift, 1.0 + tint.g * lift, 1.0 + tint.b * lift, 1.0)
