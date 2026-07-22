class_name DevTheme
extends RefCounted
## Programmatic Theme for the dev/pause overlay: an HD dark-chrome sci-fi command
## UI (translucent dark panels, cyan/amber accents) built entirely in code so it
## is headless-testable and carries no fragile `.tres` dependency. The token
## `const`s below are the single source of truth for every colour and font size;
## nothing downstream should hardcode a magic value.

# --- Colour tokens (hex -> Color(r,g,b,a) in 0..1) ---
const PANEL_BG := Color(0.055, 0.078, 0.11, 0.90)       ## #0E141C @ 0.90
const PANEL_BORDER := Color(0.165, 0.212, 0.267, 1.0)   ## #2A3644
const ACCENT := Color(0.22, 0.882, 1.0, 1.0)            ## #38E1FF (cyan)
const WARN := Color(1.0, 0.706, 0.329, 1.0)             ## #FFB454 (amber)
const TEXT_PRIMARY := Color(0.918, 0.949, 0.973, 1.0)   ## #EAF2F8
const TEXT_SECONDARY := Color(0.616, 0.69, 0.753, 1.0)  ## #9DB0C0
const TEXT_DISABLED := Color(0.306, 0.357, 0.408, 1.0)  ## #4E5B68
const BTN_BG := Color(0.086, 0.122, 0.165, 1.0)         ## #161F2A
const BTN_BG_HOVER := Color(0.118, 0.169, 0.227, 1.0)   ## #1E2B3A
const BTN_BG_PRESS := Color(0.071, 0.141, 0.192, 1.0)   ## #122431
const BTN_BG_ACTIVE := Color(0.055, 0.227, 0.275, 1.0)  ## #0E3A46
const BTN_BORDER := Color(0.2, 0.275, 0.353, 1.0)       ## #33465A
const DIVIDER := Color(0.133, 0.188, 0.235, 1.0)        ## #22303C
const BTN_BG_DISABLED := Color(0.063, 0.086, 0.118, 1.0)
const BTN_BORDER_DISABLED := Color(0.118, 0.157, 0.2, 1.0)

# --- Font size tokens ---
const FONT_TITLE := 28
const FONT_BUTTON := 18
const FONT_BODY := 16


## Constructs and returns a fully-configured Theme using the tokens above. Uses
## only documented Theme setters (`set_color`/`set_font_size`/`set_stylebox`/
## `set_constant`) so it stays robust across Godot 4.4 point releases.
static func build() -> Theme:
	var theme := Theme.new()
	theme.default_font_size = FONT_BODY

	# --- Label ---
	theme.set_color("font_color", "Label", TEXT_PRIMARY)
	theme.set_font_size("font_size", "Label", FONT_BODY)

	# --- Button (per-state StyleBoxFlat) ---
	theme.set_stylebox("normal", "Button", _button_box(BTN_BG, BTN_BORDER))
	theme.set_stylebox("hover", "Button", _button_box(BTN_BG_HOVER, ACCENT))
	theme.set_stylebox("pressed", "Button", _button_box(BTN_BG_PRESS, ACCENT))
	theme.set_stylebox("disabled", "Button", _button_box(BTN_BG_DISABLED, BTN_BORDER_DISABLED))
	theme.set_stylebox("focus", "Button", _focus_box())
	theme.set_color("font_color", "Button", TEXT_PRIMARY)
	theme.set_color("font_hover_color", "Button", TEXT_PRIMARY)
	theme.set_color("font_pressed_color", "Button", TEXT_PRIMARY)
	theme.set_color("font_disabled_color", "Button", TEXT_DISABLED)
	theme.set_font_size("font_size", "Button", FONT_BUTTON)

	# --- PanelContainer ---
	var panel := StyleBoxFlat.new()
	panel.bg_color = PANEL_BG
	panel.set_border_width_all(1)
	panel.border_color = PANEL_BORDER
	panel.set_corner_radius_all(6)
	theme.set_stylebox("panel", "PanelContainer", panel)

	# --- Label type variations (Control.theme_type_variation looks these up) ---
	theme.set_color("font_color", "TitleLabel", ACCENT)
	theme.set_font_size("font_size", "TitleLabel", FONT_TITLE)
	theme.set_color("font_color", "SecondaryLabel", TEXT_SECONDARY)
	theme.set_font_size("font_size", "SecondaryLabel", FONT_BODY)

	# --- ItemList ---
	theme.set_color("font_color", "ItemList", TEXT_PRIMARY)
	theme.set_font_size("font_size", "ItemList", FONT_BODY)

	# --- HSeparator (thin divider line) ---
	theme.set_constant("separation", "HSeparator", 1)
	var sep := StyleBoxLine.new()
	sep.color = DIVIDER
	sep.thickness = 1
	theme.set_stylebox("separator", "HSeparator", sep)

	return theme


## Builds a Button state StyleBoxFlat: 4px radius, 1px border, 16x8 content margin.
static func _button_box(bg: Color, border: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(4)
	sb.content_margin_left = 16
	sb.content_margin_right = 16
	sb.content_margin_top = 8
	sb.content_margin_bottom = 8
	return sb


## Builds the Button focus ring: hollow (no center fill), 2px accent border.
static func _focus_box() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.draw_center = false
	sb.set_border_width_all(2)
	sb.border_color = ACCENT
	sb.set_corner_radius_all(4)
	return sb
