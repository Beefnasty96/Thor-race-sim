class_name PhotoBrowser
extends PanelContainer
## In-app photo browser: thumbnails of the newest images in the phone's
## camera, Pictures and Download folders. Works around Android's system picker,
## which can't hand back photos chosen through the Gallery app.
## Needs READ_MEDIA_IMAGES (Android 13+) / READ_EXTERNAL_STORAGE (older).

signal picked(path: String)
signal closed

const EXTS := ["jpg", "jpeg", "png", "webp"]
const MAX_FILES := 240
const THUMB := 220

var folders: Array = []              # override for tests; default = phone media folders
var grid: GridContainer
var status: Label
var _files: Array = []               # [{path, mtime}]
var _buttons := {}                   # path -> TextureButton
var _queue: Array = []               # paths waiting for a thumbnail
var _done: Array = []                # [path, Image] decoded off-thread
var _mutex := Mutex.new()
var _busy := 0

func _ready() -> void:
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.02, 0.035, 0.065, 1.0)
	sb.content_margin_left = 32; sb.content_margin_right = 32
	sb.content_margin_top = 24; sb.content_margin_bottom = 24
	add_theme_stylebox_override("panel", sb)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 14)
	add_child(v)
	var top := HBoxContainer.new()
	v.add_child(top)
	var t := UIKit.label("CHOOSE A PHOTO", 34, Color.WHITE)
	t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(t)
	top.add_child(PorterUI.button("Other files…", func(): picked.emit("__system_picker__"), 260))
	top.add_child(PorterUI.button("Cancel", func(): _close(), 200))
	status = UIKit.label("", 24, UIKit.DIM)
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(status)
	var sc := ScrollContainer.new()
	sc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	v.add_child(sc)
	grid = GridContainer.new()
	grid.columns = 7
	grid.add_theme_constant_override("h_separation", 12)
	grid.add_theme_constant_override("v_separation", 12)
	sc.add_child(grid)
	resized.connect(func(): grid.columns = maxi(3, int((size.x - 64) / (THUMB + 12))))
	_start()

func _close() -> void:
	closed.emit()
	queue_free()

# ---------------------------------------------------------------- permission

func _start() -> void:
	if OS.get_name() == "Android" and folders.is_empty():
		var perm := "android.permission.READ_MEDIA_IMAGES"
		if _android_sdk() < 33:
			perm = "android.permission.READ_EXTERNAL_STORAGE"
		if not OS.request_permission(perm):
			status.text = "Car Porter needs permission to see your photos. Tap Allow on the Android prompt."
			if not get_tree().on_request_permissions_result.is_connected(_on_permission):
				get_tree().on_request_permissions_result.connect(_on_permission)
			return
	_scan()

func _android_sdk() -> int:
	# OS.get_version() on Android is the release ("14"); API 33 = Android 13
	var major := OS.get_version().get_slice(".", 0).to_int()
	return 33 if major >= 13 else 30

func _on_permission(permission: String, granted: bool) -> void:
	if not (permission.ends_with("READ_MEDIA_IMAGES") or permission.ends_with("READ_EXTERNAL_STORAGE")):
		return
	if granted:
		_scan()
	else:
		status.text = "Photo access was denied. You can allow it in Android Settings → Apps → Car Porter → Permissions, or use “Other files…”."

# ---------------------------------------------------------------- scanning

func _media_folders() -> Array:
	if not folders.is_empty():
		return folders
	var out := []
	for d in [OS.SYSTEM_DIR_DCIM, OS.SYSTEM_DIR_PICTURES, OS.SYSTEM_DIR_DOWNLOADS]:
		var p := OS.get_system_dir(d)
		if p != "" and not out.has(p):
			out.append(p)
	return out

func _scan() -> void:
	_files.clear()
	for f in _media_folders():
		_scan_dir(f, 0)
	_files.sort_custom(func(a, b): return a["mtime"] > b["mtime"])
	if _files.size() > MAX_FILES:
		_files.resize(MAX_FILES)
	for c in grid.get_children():
		c.queue_free()
	_buttons.clear()
	if _files.is_empty():
		status.text = "No photos found in your Camera, Pictures or Download folders. Try “Other files…”."
		return
	status.text = "Newest first. Tap a photo to use it. A straight-on shot from a distance works best."
	for f in _files:
		var b := TextureButton.new()
		b.custom_minimum_size = Vector2(THUMB, THUMB)
		b.ignore_texture_size = true
		b.stretch_mode = TextureButton.STRETCH_KEEP_ASPECT_CENTERED
		b.focus_mode = Control.FOCUS_NONE
		var path: String = f["path"]
		b.pressed.connect(func(): picked.emit(path); queue_free())
		var bg := ColorRect.new()
		bg.color = Color(0.08, 0.11, 0.17)
		bg.set_anchors_preset(Control.PRESET_FULL_RECT)
		bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
		bg.show_behind_parent = true
		b.add_child(bg)
		grid.add_child(b)
		_buttons[path] = b
		_queue.append(path)

func _scan_dir(path: String, depth: int) -> void:
	var da := DirAccess.open(path)
	if da == null:
		return
	da.include_hidden = false
	for f in da.get_files():
		if f.get_extension().to_lower() in EXTS:
			var full := path.path_join(f)
			_files.append({"path": full, "mtime": FileAccess.get_modified_time(full)})
	if depth < 2:
		for sub in da.get_directories():
			if not sub.begins_with(".") and sub != "thumbnails" and sub != ".thumbnails":
				_scan_dir(path.path_join(sub), depth + 1)

# ---------------------------------------------------------------- thumbnails (decoded off the main thread)

func _process(_dt: float) -> void:
	while _busy < 3 and not _queue.is_empty():
		var p: String = _queue.pop_front()
		_busy += 1
		WorkerThreadPool.add_task(_decode.bind(p))
	_mutex.lock()
	var ready := _done.duplicate()
	_done.clear()
	_mutex.unlock()
	for item in ready:
		_busy -= 1
		var b: TextureButton = _buttons.get(item[0])
		if b and is_instance_valid(b) and item[1] != null:
			b.texture_normal = ImageTexture.create_from_image(item[1])

func _decode(path: String) -> void:
	var img := PorterProject.decode_image(FileAccess.get_file_as_bytes(path))
	if img:
		var k := float(THUMB) / maxi(img.get_width(), img.get_height())
		img.resize(maxi(1, int(img.get_width() * k)), maxi(1, int(img.get_height() * k)), Image.INTERPOLATE_BILINEAR)
	_mutex.lock()
	_done.append([path, img])
	_mutex.unlock()
