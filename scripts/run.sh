#!/system/bin/sh
# godot-run —— 装机 + 启动 + 抓日志/截图
#
# 用法:
#   sh run.sh <项目名>           # 装 out/<项目名>.apk 并启动
#   sh run.sh <项目名> --log     # 只抓日志
#   sh run.sh <项目名> --shot    # 启动后截图
#
# 注: 包名默认 com.dsh.<项目名>

if [ "$(id -u)" != "2000" ]; then
	PRIV=/data/user/0/com.deepseek.harness/files/payload/bin/priv
	if [ -x "$PRIV" ]; then
		exec "$PRIV" "sh $0 $*"
	else
		echo "❌ 需要 shell 身份（Shizuku 未启动？）"
		exit 1
	fi
fi

DATA=/sdcard/DeepSeekHarness/godot
NAME="$1"
ACT="${2:-}"

if [ -z "$NAME" ]; then
	echo "用法: sh run.sh <项目名> [--log|--shot]"
	ls "$DATA/out" 2>/dev/null | sed 's/^/  已导出: /'
	exit 1
fi

APK="$DATA/out/$NAME.apk"
PKG="com.dsh.$NAME"
ACTIVITY="$PKG/com.godot.game.GodotAppLauncher"

if [ "$ACT" = "--log" ]; then
	logcat -d 2>/dev/null | grep -E "godot|AndroidRuntime|FATAL" | tail -30
	exit 0
fi

if [ ! -f "$APK" ]; then
	echo "❌ APK 不存在: $APK"
	echo "   先导出: sh $DATA/scripts/export.sh $NAME"
	exit 1
fi

echo "→ 装机 $APK"
cp -f "$APK" /data/local/tmp/_install.apk
pm install -r /data/local/tmp/_install.apk 2>&1 | tail -2
rm -f /data/local/tmp/_install.apk

echo "→ 启动 $ACTIVITY"
logcat -c 2>/dev/null
am start -n "$ACTIVITY" >/dev/null 2>&1
sleep 8

echo ""
echo "=== 前台窗口 ==="
dumpsys window 2>/dev/null | grep -m1 mCurrentFocus | sed 's/^/  /'

echo "=== Godot 输出 ==="
logcat -d 2>/dev/null | grep -E "[IWEDV] godot *:" | tail -10 | sed 's/^/  /'

echo "=== 异常（若有）==="
logcat -d 2>/dev/null | grep -E "FATAL|AndroidRuntime|SIGSEGV|SIGABRT" | tail -6 | sed 's/^/  /'

if [ "$ACT" = "--shot" ] || [ -z "$ACT" ]; then
	OUT="$DATA/out/$NAME-screenshot.png"
	screencap -p /data/local/tmp/_shot.png 2>/dev/null && cp -f /data/local/tmp/_shot.png "$OUT" 2>/dev/null
	rm -f /data/local/tmp/_shot.png
	[ -f "$OUT" ] && echo "" && echo "📸 截图: $OUT"
fi
