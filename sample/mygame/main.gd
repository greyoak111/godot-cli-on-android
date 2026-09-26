extends Node2D

var t := 0.0

func _ready() -> void:
	print("=== ", ProjectSettings.get_setting("application/config/name"), " 启动 ===")
	print("渲染器: ", RenderingServer.get_video_adapter_name())
	print("窗口: ", DisplayServer.window_get_size())

func _process(delta: float) -> void:
	t += delta
	queue_redraw()

func _draw() -> void:
	var s := get_viewport_rect().size
	draw_rect(Rect2(Vector2.ZERO, s), Color(0.05, 0.06, 0.10))
	for i in range(10):
		var c := Color.from_hsv(fmod(float(i) / 10.0 + t * 0.1, 1.0), 0.8, 1.0)
		draw_circle(s * 0.5 + Vector2(cos(t + float(i)) * 300.0, sin(t * 1.3 + float(i)) * 200.0), 40.0, c)
	draw_string(ThemeDB.fallback_font, Vector2(60, 140), "Hello Godot", HORIZONTAL_ALIGNMENT_LEFT, -1, 56, Color.WHITE)
