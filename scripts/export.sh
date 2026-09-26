#!/system/bin/sh
# godot-export —— 导出 Godot 项目为 APK（本机全自动）
#
# 用法:
#   sh export.sh <项目名> [release|debug] [包名]
#
# 例:
#   sh export.sh mygame              # 导出 release
#   sh export.sh mygame debug        # 导出 debug
#   sh export.sh mygame release com.me.mygame
#
# 产出: /sdcard/DeepSeekHarness/godot/out/<项目名>.apk

# 必须以 shell 身份运行（Shizuku）；否则自动提权重跑
if [ "$(id -u)" != "2000" ]; then
	PRIV=/data/user/0/com.deepseek.harness/files/payload/bin/priv
	if [ -x "$PRIV" ]; then
		exec "$PRIV" "sh $0 $*"
	else
		echo "❌ 需要 shell 身份（Shizuku 未启动？），且找不到 priv 工具"
		exit 1
	fi
fi

G=/data/local/tmp/dshgodot
DATA=/sdcard/DeepSeekHarness/godot
LOADER=$G/glibclib/ld-linux-aarch64.so.1
LIBS=$G/glibclib:$G/lib

NAME="$1"
MODE="${2:-release}"
PKG="$3"

if [ -z "$NAME" ]; then
	echo "用法: sh export.sh <项目名> [release|debug] [包名]"
	echo "已有项目:"
	ls "$DATA/projects" 2>/dev/null | sed 's/^/  /'
	exit 1
fi

PROJ="$DATA/projects/$NAME"
if [ ! -d "$PROJ" ]; then
	echo "❌ 项目不存在: $PROJ"
	echo "   用 new.sh 创建，或把项目放到 $DATA/projects/$NAME"
	exit 1
fi

# 环境
export HOME=$G/home
export XDG_DATA_HOME=$G/home/.local/share
export XDG_CONFIG_HOME=$G/home/.config
export XDG_CACHE_HOME=$G/home/.cache
export LD_LIBRARY_PATH=$G/lib:$G/jvm/lib
export PATH=$G/fakebin:$PATH
mkdir -p "$XDG_DATA_HOME" "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME" "$G/tmp"

# 没有预设就自动生成
if [ ! -f "$PROJ/export_presets.cfg" ]; then
	echo "→ 未找到导出预设，自动生成"
	[ -z "$PKG" ] && PKG="com.dsh.$NAME"
	sed "s|@PKG@|$PKG|; s|@NAME@|$NAME|" "$DATA/scripts/preset.template" > "$PROJ/export_presets.cfg"
fi

# 首次导入
if [ ! -d "$PROJ/.godot" ]; then
	echo "→ 首次导入资源…"
	"$LOADER" --library-path "$LIBS" "$G/godot" --headless --path "$PROJ" --import 2>&1 \
		| grep -viE "get_system_font_path|Fontconfig|^ADDING" | tail -3
fi

OUT="$DATA/out/$NAME.apk"
mkdir -p "$DATA/out"
rm -f "$OUT"

echo "→ 导出 $MODE → $OUT"
"$LOADER" --library-path "$LIBS" "$G/godot" --headless --path "$PROJ" \
	--export-$MODE "Android" "$OUT" 2>&1 \
	| grep -viE "get_system_font_path|Fontconfig|^ADDING" | tail -8

if [ -f "$OUT" ]; then
	SZ=$(ls -l "$OUT" | awk '{print $5}')
	echo ""
	echo "✅ 导出成功: $OUT  ($((SZ/1024/1024)) MB)"
	echo "   装机: sh $DATA/scripts/run.sh $NAME"
else
	echo ""
	echo "❌ 导出失败"
	exit 1
fi
