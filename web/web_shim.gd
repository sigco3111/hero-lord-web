extends Node
# Autoloaded only in the web build (see web/override.cfg). Runtime fixes for
# what the Android build took for granted; keep this list short and explained.

# Keyboard hints drawn on the touch HUD. Keys come from game.gd _install_actions();
# "auto" has no action in the game, so the shim adds hero_auto = R below.
const HINTS := {
	"menu_button": "ESC", "map_button": "M", "auto_button": "R",
	"talk_button": "SPACE", "strong_button": "X", "item_button": "Q", "cycle_button": "E",
}
const SKILL_HINTS := ["1", "3"]

var game: Node


func _init() -> void:
	# The UI is touch-first and project.binary stores emulate_mouse_from_touch=false.
	# A mouse-only browser would never produce InputEventScreenTouch otherwise.
	Input.set_emulate_touch_from_mouse(true)
	print("WebShim: emulate_touch_from_mouse=", Input.is_emulating_touch_from_mouse())
	_apply_art_choice()
	if not InputMap.has_action("hero_auto"):
		InputMap.add_action("hero_auto")
		var key := InputEventKey.new()
		key.physical_keycode = KEY_R
		InputMap.action_add_event("hero_auto", key)


# The landing page passes `art=original` or `art=remaster` after `--`. The game reads
# user://options.json in _load_options() (new_art, default true), so write the choice
# there before the main scene exists; every other key keeps its saved or default value.
func _apply_art_choice() -> void:
	var want := ""
	for arg in OS.get_cmdline_user_args():
		if arg == "art=original":
			want = "false"
		elif arg == "art=remaster":
			want = "true"
	var path := "user://options.json"
	var first_run := not FileAccess.file_exists(path)
	if want == "" and not first_run:
		return
	var saved: Variant = JSON.parse_string(FileAccess.get_file_as_string(path)) if not first_run else null
	var options: Dictionary = saved if saved is Dictionary else {}
	if want != "":
		options["new_art"] = want == "true"
	if first_run:
		options["sound"] = DEFAULT_VOLUME  # the game's own default is 10/10; too loud for a browser tab
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(options, "\t") + "\n")
		file.close()
	print("WebShim: options first_run=", first_run, " new_art=", options.get("new_art"), " sound=", options.get("sound"))


const DEFAULT_VOLUME := 5


# 환경설정 (title) gets two rows for the save bundle. The game rebuilds that page on every
# change, so this re-adds the rows whenever they are missing, just above the back key.
# Export downloads straight from GDScript; import opens the page's file picker (the page
# then calls heroLordImportSaves and reloads).
func _inject_option_rows() -> void:
	if game == null or game.get("menu_page") != "options" or not OS.has_feature("web"):
		return
	var box: Node = game.get("menu_box")
	if box == null or box.has_node("WebSaveExport"):
		return
	var export_row: Button = game.call("_paper_item", "세이브 내보내기 (파일 저장)", _export_saves.bind([]))
	export_row.name = "WebSaveExport"
	var import_row: Button = game.call("_paper_item", "세이브 가져오기 (파일 선택)", _open_import_picker)
	import_row.name = "WebSaveImport"
	for i in box.get_child_count():
		if str(box.get_child(i).get_meta("kind", "")) == "back":
			box.move_child(export_row, i)
			box.move_child(import_row, i + 1)
			break
	game.call("_layout")


func _open_import_picker() -> void:
	JavaScriptBridge.eval("document.getElementById('save-file').click()")


func _ready() -> void:
	var timer := Timer.new()
	timer.wait_time = 0.3
	timer.timeout.connect(_attach_hints)
	timer.timeout.connect(_guard_guardians)
	timer.timeout.connect(_push_art_state)
	timer.timeout.connect(_inject_option_rows)
	timer.timeout.connect(_assist_mark_update)
	add_child(timer)
	timer.start()
	if OS.has_feature("web"):
		# window.heroLordSetArt('original'|'remaster') from the page's toggle
		_js_set_art = JavaScriptBridge.create_callback(_set_art_from_page)
		_js_export = JavaScriptBridge.create_callback(_export_saves)
		_js_import = JavaScriptBridge.create_callback(_import_saves)
		var window := JavaScriptBridge.get_interface("window")
		window.heroLordSetArt = _js_set_art
		window.heroLordExportSaves = _js_export
		window.heroLordImportSaves = _js_import
		_js_assist = JavaScriptBridge.create_callback(_set_assist_from_page)
		window.heroLordSetAssist = _js_assist


var _js_set_art: JavaScriptObject
var _js_export: JavaScriptObject
var _js_import: JavaScriptObject
var _js_assist: JavaScriptObject
var _art_pushed := ""

# Save transfer between browsers. The game keeps plain JSON under user://
# (saves/*.json plus the files below); a bundle is just those texts in one JSON.
# JavaScriptBridge callbacks cannot return values, so results go to window.*.
const USER_FILES := ["options.json", "progress.json", "cutscenes-seen.json"]


func _export_saves(_args: Array) -> void:
	var files := {}
	for name in USER_FILES:
		if FileAccess.file_exists("user://" + name):
			files[name] = FileAccess.get_file_as_string("user://" + name)
	var dir := DirAccess.open("user://saves")
	if dir != null:
		for f in dir.get_files():
			if f.ends_with(".json"):
				files["saves/" + f] = FileAccess.get_file_as_string("user://saves/" + f)
	var bundle := {"game": "HeroLordRemaster", "exported": Time.get_datetime_string_from_system(), "files": files}
	var text := JSON.stringify(bundle, "\t")
	JavaScriptBridge.get_interface("window").heroLordSaveBundle = text
	JavaScriptBridge.download_buffer(text.to_utf8_buffer(), "herolord-saves-%s.json" % Time.get_date_string_from_system(), "application/json")


func _import_saves(args: Array) -> void:
	var window := JavaScriptBridge.get_interface("window")
	window.heroLordImportResult = -1
	var parsed: Variant = JSON.parse_string(str(args[0])) if not args.is_empty() else null
	if not (parsed is Dictionary) or not (parsed.get("files") is Dictionary):
		return
	DirAccess.make_dir_recursive_absolute("user://saves")
	var count := 0
	for name in parsed.files:
		var n := str(name)
		var ok := n in USER_FILES or (n.begins_with("saves/") and n.ends_with(".json") and not "/" in n.trim_prefix("saves/"))
		if not ok:
			continue  # only the files the game itself writes, never arbitrary paths
		var file := FileAccess.open("user://" + n, FileAccess.WRITE)
		if file != null:
			file.store_string(str(parsed.files[name]))
			file.close()
			count += 1
	window.heroLordImportResult = count


# Same steps as the game's own toggles (_title_art / _story_menu_art), minus the
# screen-specific refresh, so it works from any screen.
func _set_art_from_page(args: Array) -> void:
	if game == null or args.is_empty():
		return
	var want: bool = str(args[0]) == "remaster"
	var world: Node = game.get("world")
	if world == null or bool(world.get("modern_art_enabled")) == want:
		return
	world.call("set_modern_art_enabled", want)
	var options: Dictionary = game.get("options")
	options["new_art"] = want
	game.call("_save_options")
	game.call("_apply_art_choice")
	game.call("_layout")
	if game.get("menu_page") == "options":
		game.call("_show_options")


# Keep the page's toggle in sync when the art is changed inside the game.
func _push_art_state() -> void:
	if game == null or not OS.has_feature("web"):
		return
	var world: Node = game.get("world")
	if world == null:
		return
	var state := "remaster" if bool(world.get("modern_art_enabled")) else "original"
	if state != _art_pushed:
		_art_pushed = state
		JavaScriptBridge.eval("window.dispatchEvent(new CustomEvent('herolord-art', {detail: '%s'}))" % state)


# New game -> "함께할 가디언": the game toggles guardian_picks without a cap, so a third
# card can be picked (header shows 3 / 2 and 모험 시작 greys out). Disable the unpicked
# cards once two are chosen; the game's own touch router skips disabled buttons.
func _guard_guardians() -> void:
	if game == null or game.get("menu_page") != "guardians":
		return
	for card in game.get("guardian_buttons"):
		if is_instance_valid(card) and not card.pressed.is_connected(_limit_guardians):
			card.pressed.connect(_limit_guardians)  # runs after the game's _toggle_guardian
	_limit_guardians()


func _limit_guardians() -> void:
	var picks: Array = game.get("guardian_picks")
	var cards: Array = game.get("guardian_buttons")
	var full: bool = picks.count(true) >= 2
	for i in mini(picks.size(), cards.size()):
		if is_instance_valid(cards[i]):
			cards[i].disabled = full and not picks[i]


func _input(event: InputEvent) -> void:
	# One input path, like Android. Every left click already arrives a second time as an
	# emulated touch that the game's own router handles; if the real mouse event also reached
	# the GUI, a Button would fire twice (the dialogue "빨리 ▶▶" toggle cancelled itself and
	# "다음" advanced two lines per click). Scene nodes' _input (virtual joystick, title) have
	# already seen this event by the time an autoload gets it, so only the GUI stage is cut.
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT \
			and event.device != InputEvent.DEVICE_ID_EMULATION:
		get_viewport().set_input_as_handled()


func _unhandled_key_input(event: InputEvent) -> void:
	if event.is_action_pressed("hero_auto") and not event.is_echo() and game != null:
		var button: Button = game.get("auto_button")
		if button != null and button.is_visible_in_tree() and not button.disabled:
			button.pressed.emit()


func _attach_hints() -> void:
	var scene := get_tree().current_scene
	if scene == null or not scene.has_method("_layout_nodes"):
		return
	game = scene
	for prop in HINTS:
		_hint(game.get(prop), HINTS[prop])
	var skills: Array = game.get("skill_buttons")
	for i in mini(skills.size(), SKILL_HINTS.size()):
		_hint(skills[i], SKILL_HINTS[i])
	_hint(game.get("joystick"), "WASD")


func _hint(target: Control, text: String) -> void:
	if target == null or target.has_node("KeyHint"):
		return
	var label := Label.new()
	label.name = "KeyHint"
	label.text = text
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.z_index = 1
	var scale: float = maxf(1.0, float(game.get("ui_scale")))
	label.add_theme_font_size_override("font_size", roundi(11 * scale))
	label.add_theme_color_override("font_color", Color(0.97, 0.97, 0.97, 0.9))
	var pill := StyleBoxFlat.new()
	pill.bg_color = Color(0.25, 0.25, 0.27, 0.6)
	pill.set_corner_radius_all(roundi(4 * scale))
	pill.content_margin_left = 5 * scale
	pill.content_margin_right = 5 * scale
	pill.content_margin_top = 1 * scale
	pill.content_margin_bottom = 1 * scale
	label.add_theme_stylebox_override("normal", pill)
	target.add_child(label)
	# Centered on the top edge, half outside the button, so it never covers the icon.
	var half := label.get_minimum_size() / 2.0
	label.anchor_left = 0.5
	label.anchor_right = 0.5
	label.anchor_top = 0.0
	label.anchor_bottom = 0.0
	label.offset_left = -half.x
	label.offset_right = half.x
	label.offset_top = -half.y
	label.offset_bottom = half.y


# ---- Web-only auto-battle assist -------------------------------------------------
# The game's own 자동 button walks the quest route and *stops walking* ("대기") whenever a
# foe is near, leaving the fight to the player. While 자동 is on and it is holding for a
# foe, this presses the game's own attack/skill/potion handlers on a short timer.
# It never runs outside the field: no dialogue, cutscene, menu, minimap or story event.
# The game itself still stops auto at low HP (30%) and before bosses.
const ASSIST_TICK := 0.12
const ASSIST_COMBO := [false, false, true]   # normal, normal, strong
const ASSIST_POTION_BELOW := 0.5
const ASSIST_CELL := 16.0

var assist_enabled := true
var _assist_t := 0.0
var _assist_combo := 0
var _skill_cd := 0.0
var _potion_cd := 0.0
var _assist_fight := false
var _assist_label: Label


func _set_assist_from_page(args: Array) -> void:
	assist_enabled = bool(args[0]) if args.size() > 0 else true
	if not assist_enabled and _assist_fight:
		_assist_fight = false
		_emit_assist("idle")


func _emit_assist(state: String) -> void:
	if OS.has_feature("web"):
		JavaScriptBridge.eval("window.dispatchEvent(new CustomEvent('herolord-assist',{detail:'%s'}))" % state)


func _process(delta: float) -> void:
	_assist_t += delta
	if _assist_t < ASSIST_TICK:
		return
	var dt := _assist_t
	_assist_t = 0.0
	_skill_cd -= dt
	_potion_cd -= dt
	var fighting := _assist_step()
	if fighting != _assist_fight:
		_assist_fight = fighting
		_emit_assist("fight" if fighting else "idle")


func _assist_foe() -> Variant:
	# Nearest foe in reach, same filter as the game's own foe_near().
	var aq = game.get("auto_quest")
	var story = game.get("story")
	var model = game.get("model")
	var reach: float = float(aq.get("foe_reach")) * ASSIST_CELL
	var best: Variant = null
	var best_d := INF
	for enemy in story.arena.enemies:
		if int(enemy.get("mode", 0)) == 6 or bool(enemy.get("ghost", false)) or bool(enemy.get("boss", false)):
			continue
		var at: Vector2 = (enemy.pixel as Vector2) + Vector2(ASSIST_CELL * int(enemy.get("width", 1)), ASSIST_CELL) * 0.5
		var d: float = at.distance_to(model.position)
		if d < reach and d < best_d:
			best_d = d
			best = at
	return best


func _assist_step() -> bool:
	if not assist_enabled or game == null or not is_instance_valid(game):
		return false
	var aq = game.get("auto_quest")
	if aq == null or not bool(aq.get("active")) or not bool(aq.get("holding")):
		return false
	if str(game.get("mode")) != "play" or bool(game.call("_story_busy")):
		return false
	var model = game.get("model")
	var story = game.get("story")
	if model == null or story == null or not bool(game.get("story_mode")):
		return false
	if not model.dialogue.is_empty():
		return false
	for ui_key in ["menu_panel", "story_menu", "minimap"]:
		var ui = game.get(ui_key)
		if ui != null and is_instance_valid(ui) and ui.visible:
			return false
	var strong: Button = game.get("strong_button")
	if strong == null or strong.disabled:
		return false   # hero is down
	var foe: Variant = _assist_foe()
	if foe == null:
		return false
	var hero = story.arena.hero
	if not hero.busy():
		var gap: Vector2 = (foe as Vector2) - (model.position as Vector2)
		model.facing = ("right" if gap.x > 0 else "left") if absf(gap.x) > absf(gap.y) else ("down" if gap.y > 0 else "up")
	var state = story.state
	var item: Button = game.get("item_button")
	if _potion_cd <= 0.0 and int(state.quick_kind) == 0 and item != null and not item.disabled \
			and float(state.hp) < float(state.max_hp()) * ASSIST_POTION_BELOW:
		game.call("_story_item")
		_potion_cd = 4.0
		return true
	if _skill_cd <= 0.0:
		var skills: Array = game.get("skill_buttons")
		for i in skills.size():
			var b: Button = skills[i]
			if b.visible and not b.disabled:
				game.call("_story_skill", i == 0)
				_skill_cd = 1.2
				return true
	game.call("_story_attack", ASSIST_COMBO[_assist_combo])
	_assist_combo = (_assist_combo + 1) % ASSIST_COMBO.size()
	return true


func _assist_mark_update() -> void:
	# Small tag under the 자동 button: shows the assist is armed (gold) or fighting (red).
	if game == null or not is_instance_valid(game):
		return
	var button: Button = game.get("auto_button")
	if button == null or not is_instance_valid(button):
		return
	if _assist_label == null or not is_instance_valid(_assist_label):
		_assist_label = Label.new()
		_assist_label.name = "AssistMark"
		_assist_label.text = "전투보조"
		_assist_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_assist_label.z_index = 1
		var pill := StyleBoxFlat.new()
		pill.bg_color = Color(0.2, 0.2, 0.25, 0.75)
		pill.set_corner_radius_all(4)
		pill.content_margin_left = 5
		pill.content_margin_right = 5
		_assist_label.add_theme_stylebox_override("normal", pill)
		button.add_child(_assist_label)
	var aq = game.get("auto_quest")
	var armed: bool = assist_enabled and aq != null and bool(aq.get("active"))
	_assist_label.visible = armed and button.visible
	var scale: float = maxf(1.0, float(game.get("ui_scale")))
	_assist_label.add_theme_font_size_override("font_size", roundi(10 * scale))
	_assist_label.add_theme_color_override("font_color", Color(1.0, 0.45, 0.4) if _assist_fight else Color(1.0, 0.84, 0.42))
	_assist_label.position = Vector2((button.size.x - _assist_label.size.x) / 2.0, button.size.y + 2.0)
