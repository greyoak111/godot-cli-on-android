#!/system/bin/sh
# godot-stage —— 应用侧暂存：把执行层源码从应用私有目录拷到 /sdcard 暂存区
#
# 这一步由 DSH 应用（本 app）执行，因为源码在应用私有目录里，shell 读不到。
# 之后由 shell 侧执行 scripts/setup.sh 完成部署。
#
# 用法（应用身份）: sh stage.sh

set -e
P=/data/user/0/com.deepseek.harness/files/dshtc/prefix
GD=/data/user/0/com.deepseek.harness/files/dshgd
PATCHER=/data/user/0/com.deepseek.harness/files/dshgd/patchlibc.mjs
STAGE=/sdcard/DeepSeekHarness/godot/_stage

echo "════ 应用侧暂存 ════"
rm -rf "$STAGE"
mkdir -p "$STAGE/glibclib" "$STAGE/lib" "$STAGE/jvm"

echo "=== 1) 暂存 godot 二进制 ==="
cp "$GD/Godot_v4.7.2-stable_linux.arm64" "$STAGE/godot"
ls -l "$STAGE/godot" | awk '{printf "  %.0f MB\n", $5/1048576}'

echo "=== 2) 暂存 glibc 运行时（并打补丁）==="
cp -RL "$P/glibc/lib/." "$STAGE/glibclib/" 2>/dev/null || true
node "$PATCHER" "$STAGE/glibclib/libc.so.6" "$STAGE/glibclib/libc.so.6" | sed 's/^/  /'

echo "=== 3) 暂存依赖库 ==="
for f in "$P/lib"/*.so*; do cp -L "$f" "$STAGE/lib/" 2>/dev/null || true; done
echo "  $(ls "$STAGE/lib" | wc -l) 个库文件"

echo "=== 4) 暂存 JDK17 ==="
cp -RL "$P/lib/jvm/java-17-openjdk/." "$STAGE/jvm/" 2>/dev/null || true
echo "  JDK $(du -sh "$STAGE/jvm" | cut -f1)"

echo "=== 5) apksigner.jar ==="
cp "$P/share/java/apksigner.jar" "$STAGE/apksigner.jar"

echo ""
echo "════ 暂存完成 ════"
du -sh "$STAGE"
echo "下一步（shell 身份）: sh /sdcard/DeepSeekHarness/godot/scripts/setup.sh"
