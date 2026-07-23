extends CanvasLayer
## In-game pause / dev overlay. Escape toggles it; while open it drives
## `SceneTree.paused`, the overlay's visibility, the MapEditor's paint gate, and a
## live tileset switcher. The pure decision state lives in `ModeController`; the
## tileset registry/swap logic lives in `TilesetCatalog`. This node only wires
## engine input, tree state and the visual tree to those cores.
##
## This is a RUNTIME node (not `@tool`), so none of this executes during a
## headless `--import` in CI.

# Node paths within the overlay's Root Control (single source of truth).
const P_TITLE := "CenterContainer/CenterPanel/PanelMargin/MenuVBox/TitleLabel"
const P_MODE_LABEL := "CenterContainer/CenterPanel/PanelMargin/MenuVBox/ModeRow/ModeLabel"
const P_MODE_EDITOR := "CenterContainer/CenterPanel/PanelMargin/MenuVBox/ModeRow/ModeEditorBtn"
const P_MODE_PLAY := "CenterContainer/CenterPanel/PanelMargin/MenuVBox/ModeRow/ModePlayBtn"
const P_RESUME := "CenterContainer/CenterPanel/PanelMargin/MenuVBox/ActionCol/ResumeBtn"
const P_QUIT := "CenterContainer/CenterPanel/PanelMargin/MenuVBox/ActionCol/QuitBtn"
const P_SIDEBAR_TITLE := "Sidebar/SidebarMargin/SidebarVBox/SidebarTitle"
const P_TILESET_LIST := "Sidebar/SidebarMargin/SidebarVBox/TilesetList"
const P_ORPHAN := "Sidebar/SidebarMargin/SidebarVBox/OrphanReadout"

## Path to the MapSystem node whose elevation layers the switcher swaps.
@export var map_system_path: NodePath

## Pure mode/pause/visibility state machine (EDITOR/PLAY, menu open/closed).
var _mode := ModeController.new()
## Named-tileset registry + swap logic used by the sidebar switcher.
var _catalog := TilesetCatalog.new()
## The resolved MapSystem node. Typed via class_name (#105): its
## `get_node_or_null()` / `elevation_layers` API resolves on the MapSystem type.
var _map_system: MapSystem
## The resolved MapEditor child of the MapSystem. Typed via class_name (#105):
## `editing_enabled` / `rebind_tileset()` resolve on the MapEditor type.
var _map_editor: MapEditor
## Catalog entry names, index-aligned with the TilesetList rows.
var _tileset_names: Array[String] = []


func _ready() -> void:
	# Always process, even while the tree is paused: the overlay itself pauses the
	# tree, so a WHEN_PAUSED/INHERIT mode would stop receiving input the instant we
	# opened and Escape could never re-close (nor re-open) the menu.
	process_mode = Node.PROCESS_MODE_ALWAYS
	# Defer binding by one step: the sibling/target MapSystem fills its @onready
	# `elevation_layers` (and the MapEditor builds its TileSet) only when their
	# `_ready` runs. A deferred call runs after the whole tree has finished
	# readying, so those are populated by the time we query them.
	_setup.call_deferred()


func _setup() -> void:
	_map_system = get_node_or_null(map_system_path) as MapSystem
	if _map_system == null:
		push_warning("dev_menu: map_system_path unresolved; overlay is inert.")
		return
	_map_editor = _map_system.get_node_or_null("MapEditor") as MapEditor

	# Assign the theme in code (not the .tscn) to avoid a fragile theme resource.
	var root := $Root as Control
	root.theme = DevTheme.build()

	# Apply theme type variations to the labels that want the accent/secondary look.
	(root.get_node(P_TITLE) as Label).theme_type_variation = "TitleLabel"
	(root.get_node(P_MODE_LABEL) as Label).theme_type_variation = "SecondaryLabel"
	(root.get_node(P_SIDEBAR_TITLE) as Label).theme_type_variation = "SecondaryLabel"
	(root.get_node(P_ORPHAN) as Label).theme_type_variation = "SecondaryLabel"

	# The two mode buttons are mutually exclusive: one shared ButtonGroup.
	var group := ButtonGroup.new()
	(root.get_node(P_MODE_EDITOR) as Button).button_group = group
	(root.get_node(P_MODE_PLAY) as Button).button_group = group

	_register_tilesets()
	_populate_tileset_list()

	# Wire up the interactive controls.
	(root.get_node(P_RESUME) as Button).pressed.connect(_on_resume)
	(root.get_node(P_QUIT) as Button).pressed.connect(_on_quit)
	(root.get_node(P_MODE_EDITOR) as Button).pressed.connect(_on_editor)
	(root.get_node(P_MODE_PLAY) as Button).pressed.connect(_on_play)
	(root.get_node(P_TILESET_LIST) as ItemList).item_activated.connect(_on_tileset_activated)

	# Establish the initial (closed, unpaused) state.
	_apply()


## Registers the switchable tilesets. Two entries are enough to demonstrate a live
## swap that both re-tiles the map and can orphan cells that the new set lacks.
## More entries arrive with the real art (#33).
func _register_tilesets() -> void:
	_catalog.register("Terrain (HD)", func() -> TileSet:
		return TileSetBuilder.build_default_terrain_tileset())
	_catalog.register("Debug (grid)", _build_debug_tileset)


## Builds a minimal single-tile isometric TileSet backed by an in-memory texture,
## so the switcher works with zero art dependencies (and demonstrably orphans the
## HD atlas coords the terrain set used).
func _build_debug_tileset() -> TileSet:
	var ts := TileSet.new()
	ts.tile_shape = TileSet.TILE_SHAPE_ISOMETRIC
	ts.tile_layout = TileSet.TILE_LAYOUT_DIAMOND_DOWN
	ts.tile_size = MapConstants.TILE_SIZE

	var img := Image.create(128, 64, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.22, 0.882, 1.0, 1.0))
	var tex := ImageTexture.create_from_image(img)

	var src := TileSetAtlasSource.new()
	src.texture = tex
	src.texture_region_size = MapConstants.TILE_SIZE
	ts.add_source(src)
	src.create_tile(Vector2i(0, 0))
	return ts


## Fills the sidebar ItemList from the catalog, caching the index->name mapping.
func _populate_tileset_list() -> void:
	var list := $Root.get_node(P_TILESET_LIST) as ItemList
	list.clear()
	_tileset_names.clear()
	for entry_name in _catalog.names():
		_tileset_names.append(entry_name)
		list.add_item(entry_name)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		_mode.toggle_menu()
		_apply()
		if _mode.is_menu_visible():
			_grab_default_focus()
		get_viewport().set_input_as_handled()


## Pushes the current ModeController state onto the engine: pause, overlay
## visibility, the editor paint gate, and the mode toggle buttons.
func _apply() -> void:
	get_tree().paused = _mode.is_paused()
	($Root as Control).visible = _mode.is_menu_visible()
	if _map_editor != null:
		_map_editor.editing_enabled = _mode.is_editor_enabled()
	# Reflect the active mode on the toggle buttons without re-emitting `pressed`.
	var editor_btn := $Root.get_node(P_MODE_EDITOR) as Button
	var play_btn := $Root.get_node(P_MODE_PLAY) as Button
	editor_btn.set_pressed_no_signal(_mode.mode == ModeController.Mode.EDITOR)
	play_btn.set_pressed_no_signal(_mode.mode == ModeController.Mode.PLAY)


## Moves keyboard focus to Resume when the menu opens (accessible default).
func _grab_default_focus() -> void:
	($Root.get_node(P_RESUME) as Button).grab_focus()


func _on_resume() -> void:
	_mode.toggle_menu()
	_apply()


func _on_quit() -> void:
	get_tree().quit()


func _on_editor() -> void:
	_mode.set_mode(ModeController.Mode.EDITOR)
	_apply()


func _on_play() -> void:
	_mode.set_mode(ModeController.Mode.PLAY)
	_apply()


## Builds the chosen tileset, swaps it into the live elevation layers (dropping
## cells the new set lacks), rebinds the editor, and reports orphaned cells.
func _on_tileset_activated(index: int) -> void:
	if index < 0 or index >= _tileset_names.size():
		return
	var entry_name := _tileset_names[index]
	var ts := _catalog.build(entry_name)
	if ts == null:
		return
	var layers: Array[TileMapLayer] = _map_system.elevation_layers
	var res := TilesetCatalog.swap_into(layers, ts)
	if _map_editor != null:
		_map_editor.rebind_tileset(ts)
	# A tileset swap re-tiles (and can orphan cells across) the whole stack, so
	# announce a whole-map change through the MapSystem hub (#95).
	_map_system.emit_map_changed_all()

	var orphaned: int = res["orphaned"]
	var readout := $Root.get_node(P_ORPHAN) as Label
	readout.text = "Swapped: %d cells dropped" % orphaned
	# Amber warns when cells were lost; secondary (neutral) when clean.
	# Colours mirror the DevTheme tokens so the overlay reads as one system.
	readout.add_theme_color_override("font_color", DevTheme.WARN if orphaned > 0 else DevTheme.TEXT_SECONDARY)
