#!/system/bin/sh
# godot-stage —— 应用侧暂存：从零构建执行层所需的全部文件
#
# 这一步在「能跑 node 的身份」下执行（普通应用即可）。
# 它会：
#   1. 下载 Godot 官方 linux.arm64 构建
#   2. 用仓库自带的 tpkg 从 Termux 仓库抽取 glibc / OpenJDK17 / 依赖库
#   3. 给 libc.so.6 打路径补丁（popen 修复）
#   4. 拉取 Android 导出模板
#   5. 把上述一切整理进 /sdcard 暂存区
#
# 之后由 shell 侧执行 scripts/setup.sh 完成部署
# （导出必须以 shell 身份运行，原因见 README 的「关键技术说明」）。
#
# 用法:
#   sh stage.sh                    # 全量
#   sh stage.sh --skip-templates   # 跳过模板（已拉过时）
#
# 依赖: node、网络、约 3GB 空闲磁盘

set -e

REPO="$(cd "$(dirname "$0")/.." && pwd)"
DATA="${GODOT_DATA:-/sdcard/DeepSeekHarness/godot}"
STAGE="$DATA/_stage"
WORK="${GODOT_WORK:-$REPO/.bootstrap}"
GODOT_VERSION="${GODOT_VERSION:-4.7.2}"

mkdir -p "$DATA/templates" "$DATA/keystore" "$DATA/platform" "$DATA/projects" "$DATA/out"
mkdir -p "$WORK"

echo "════ Godot 环境：应用侧暂存 ════"
echo "  仓库     : $REPO"
echo "  持久层   : $DATA"
echo "  工作目录 : $WORK"
echo "  Godot    : $GODOT_VERSION"
echo ""

# ---------------------------------------------------------------- 1. Godot
echo "=== 1/6 下载 Godot linux.arm64 ==="
if [ ! -f "$STAGE/godot" ]; then
  mkdir -p "$STAGE"
  ZIP="$WORK/godot.zip"
  curl -fsSL --retry 3 -o "$ZIP" \
    "https://github.com/godotengine/godot/releases/download/${GODOT_VERSION}-stable/Godot_v${GODOT_VERSION}-stable_linux.arm64.zip"
  unzip -oq "$ZIP" -d "$WORK"
  mv "$WORK/Godot_v${GODOT_VERSION}-stable_linux.arm64" "$STAGE/godot"
  chmod 755 "$STAGE/godot"
  rm -f "$ZIP"
fi
ls -l "$STAGE/godot" | awk '{printf "  %.0f MB\n", $5/1048576}'

# ------------------------------------------------- 2. Termux 包（glibc/JDK/库）
echo "=== 2/6 抽取 Termux 包（glibc + OpenJDK17 + 依赖）==="
echo "  （约 600MB 下载，解包后约 1GB，请耐心）"
TPKG_PREFIX="$WORK/prefix" TPKG_CACHE="$WORK/debs" TPKG_STAGE="$WORK/tpkgs" \
  node "$REPO/tools/tpkg.mjs" install \
    glibc openjdk-17 fontconfig libandroid-shmem libandroid-support 2>&1 | tail -6

P="$WORK/prefix"
[ -d "$P/glibc/lib" ] || { echo "❌ glibc 未就位"; exit 1; }
[ -d "$P/lib/jvm/java-17-openjdk" ] || { echo "❌ JDK 未就位"; exit 1; }

# ------------------------------------------------------------ 3. glibc + 补丁
echo "=== 3/6 暂存 glibc 并打补丁 ==="
rm -rf "$STAGE/glibclib"
cp -RL "$P/glibc/lib" "$STAGE/glibclib"
# /sdcard 不支持符号链接，故用 -L 解引用；SONAME 链接由 setup.sh 在目标位置重建
node "$REPO/tools/patchlibc.mjs" "$STAGE/glibclib/libc.so.6" "$STAGE/glibclib/libc.so.6" | tail -3
echo "  补丁后校验:"
node -e '
const fs=require("fs");const b=fs.readFileSync(process.argv[1]);
console.log("    含 dshgodot 路径:", b.indexOf("/data/local/tmp/dshgodot/")>=0?"✅":"❌");
console.log("    残留 Termux 路径:", b.indexOf("/data/data/com.termux/files/usr/glibc/bin/sh")>=0?"⚠️ 有":"✅ 无");
' "$STAGE/glibclib/libc.so.6"

# ---------------------------------------------------------------- 4. 依赖库
echo "=== 4/6 暂存依赖库 ==="
rm -rf "$STAGE/lib"; mkdir -p "$STAGE/lib"
for f in "$P/lib"/*.so*; do cp -L "$f" "$STAGE/lib/" 2>/dev/null || true; done
echo "  $(ls "$STAGE/lib" | wc -l) 个库文件"

# ---------------------------------------------------------------- 5. JDK
echo "=== 5/6 暂存 JDK17 ==="
rm -rf "$STAGE/jvm"
cp -RL "$P/lib/jvm/java-17-openjdk" "$STAGE/jvm"
if [ -f "$P/share/java/apksigner.jar" ]; then
  cp "$P/share/java/apksigner.jar" "$STAGE/apksigner.jar"
else
  JAR="$(find "$P" -name apksigner.jar 2>/dev/null | head -1)"
  [ -n "$JAR" ] && cp "$JAR" "$STAGE/apksigner.jar" || echo "  ⚠️  未找到 apksigner.jar"
fi
echo "  JDK $(du -sm "$STAGE/jvm" 2>/dev/null | cut -f1) MB"

# ------------------------------------------------------------ 6. 导出模板
if [ "$1" != "--skip-templates" ]; then
  echo "=== 6/6 拉取 Android 导出模板 ==="
  TPL="$DATA/templates/${GODOT_VERSION}.stable"
  mkdir -p "$TPL"
  if [ ! -f "$TPL/android_release.apk" ]; then
    # 完整 .tpz 有 1.2GB，只取里面两个安卓模板（约 221MB）
    node "$REPO/tools/tpzfetch.mjs" \
      "https://github.com/godotengine/godot/releases/download/${GODOT_VERSION}-stable/Godot_v${GODOT_VERSION}-stable_export_templates.tpz" \
      "$TPL" 'android_(debug|release)[.]apk$'
    printf '%s' "${GODOT_VERSION}.stable" > "$TPL/version.txt"
  fi
  ls -l "$TPL" | tail -3
else
  echo "=== 6/6 跳过模板 ==="
fi

echo ""
echo "════ 暂存完成 ════"
du -sm "$STAGE" 2>/dev/null | awk '{printf "  暂存区: %s MB\n", $1}'
echo ""
echo "下一步（必须以 shell 身份，例如通过 Shizuku）："
echo "  sh $REPO/scripts/setup.sh"
echo ""
echo "提示：暂存完成后可删掉工作目录释放空间："
echo "  rm -rf $WORK"
