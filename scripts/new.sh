#!/system/bin/sh
# godot-new —— 创建一个新的 Godot 项目骨架
#
# 用法: sh new.sh <项目名> [包名]
# 产出: /sdcard/DeepSeekHarness/godot/projects/<项目名>/

DATA=/sdcard/DeepSeekHarness/godot
NAME="$1"
PKG="${2:-com.dsh.$NAME}"

if [ -z "$NAME" ]; then
	echo "用法: sh new.sh <项目名> [包名]"
	exit 1
fi

P="$DATA/projects/$NAME"
if [ -d "$P" ]; then
	echo "❌ 项目已存在: $P"
	exit 1
fi
mkdir -p "$P"

cat > "$P/project.godot" <<EOF
config_version=5

[application]
config/name="$NAME"
run/main_scene="res://main.tscn"
config/features=PackedStringArray("4.7", "GL Compatibility")

[rendering]
renderer/rendering_method="gl_compatibility"
renderer/rendering_method.mobile="gl_compatibility"
textures/vram_compression/import_etc2_astc=true
EOF

cat > "$P/main.gd" <<'EOF'
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
EOF

cat > "$P/main.tscn" <<'EOF'
[gd_scene load_steps=2 format=3 uid="uid://bmainscene0001"]

[ext_resource type="Script" path="res://main.gd" id="1_main"]

[node name="Main" type="Node2D"]
script = ExtResource("1_main")
EOF

sed "s|@PKG@|$PKG|; s|@NAME@|$NAME|" "$DATA/scripts/preset.template" > "$P/export_presets.cfg"

echo "✅ 项目已创建: $P"
echo "   包名: $PKG"
echo ""
echo "   导出:  sh $DATA/scripts/export.sh $NAME"
echo "   运行:  sh $DATA/scripts/run.sh $NAME"
