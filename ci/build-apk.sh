#!/usr/bin/env bash
# 在 CI（x86_64 Linux）上把 Godot 项目导出成已签名的 Android APK
#
# 用法: build-apk.sh <项目目录> [输出APK路径] [debug|release]
#
# 依赖环境变量（GitHub Actions 上大多已预装）:
#   ANDROID_HOME / ANDROID_SDK_ROOT   Android SDK 路径
#   JAVA_HOME                         JDK 路径
#   GODOT_VERSION                     默认 4.7.2
#   KEYSTORE_BASE64                   可选：密钥库（base64），不提供则现场生成
#   KEYSTORE_PASS / KEYSTORE_ALIAS    可选：默认 android / androiddebugkey
#
# 注：CI 上不需要本地那套 glibc 补丁 / shell 身份 / /dev/input 处理——
#     那些是「Termux 抽取的运行时 + 安卓沙箱」特有的问题，官方
#     linux.x86_64 构建在标准 Linux 上直接可用。

set -euo pipefail

# ---- 留痕：失败时把日志尾部写进 Step Summary（匿名 API 可读，便于远程排查）----
LOG="$(mktemp)"
exec > >(tee "$LOG") 2>&1

on_err() {
  local rc=$? line=$1
  {
    printf '### ❌ 构建失败\n\n'
    printf '第 **%s** 行，退出码 **%s**\n\n' "$line" "$rc"
    printf '```text\n'
    tail -80 "$LOG" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g'
    printf '\n```\n'
  } >> "${GITHUB_STEP_SUMMARY:-/dev/null}" 2>/dev/null || true
  exit "$rc"
}
trap 'on_err $LINENO' ERR

PROJECT="${1:?用法: build-apk.sh <项目目录> [输出APK] [debug|release]}"
OUT_APK="${2:-$(pwd)/build/$(basename "$PROJECT").apk}"
BUILD_TYPE="${3:-release}"
GODOT_VERSION="${GODOT_VERSION:-4.7.2}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

GODOT_DIR="$HOME/godot"
TPL_DIR="$HOME/.local/share/godot/export_templates/${GODOT_VERSION}.stable"

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

# ------------------------------------------------------------ 0. 环境自检
log "环境自检"
echo "  工作目录 : $(pwd)"
echo "  仓库根   : $REPO_ROOT"
echo "  项目     : $PROJECT"
echo "  构建类型 : $BUILD_TYPE"
echo "  Godot    : $GODOT_VERSION"
echo "  HOME     : $HOME"
echo "  ANDROID_HOME        = ${ANDROID_HOME:-<未设置>}"
echo "  ANDROID_SDK_ROOT    = ${ANDROID_SDK_ROOT:-<未设置>}"
echo "  JAVA_HOME           = ${JAVA_HOME:-<未设置>}"
echo "  node                = $(command -v node || echo 缺失)  $(node -v 2>/dev/null)"
echo "  curl/unzip/keytool  = $(command -v curl || echo 缺) / $(command -v unzip || echo 缺) / $(command -v keytool || echo 缺)"
[ -d "$PROJECT" ] || { echo "❌ 项目目录不存在: $PROJECT"; ls -la; exit 1; }

# ---------------------------------------------------------------- 1. Godot
log "准备 Godot ${GODOT_VERSION}"
mkdir -p "$GODOT_DIR"
if [ ! -x "$GODOT_DIR/godot" ]; then
  ZIP="$GODOT_DIR/godot.zip"
  URL="https://github.com/godotengine/godot/releases/download/${GODOT_VERSION}-stable/Godot_v${GODOT_VERSION}-stable_linux.x86_64.zip"
  echo "  下载 $URL"
  curl -fsSL --retry 3 -o "$ZIP" "$URL"
  ls -l "$ZIP"
  unzip -oq "$ZIP" -d "$GODOT_DIR"
  rm -f "$ZIP"
  SRC="$GODOT_DIR/Godot_v${GODOT_VERSION}-stable_linux.x86_64"
  [ -f "$SRC" ] || { echo "❌ 解压后找不到 $SRC"; ls -la "$GODOT_DIR"; exit 1; }
  mv "$SRC" "$GODOT_DIR/godot"
  chmod +x "$GODOT_DIR/godot"
fi
ls -l "$GODOT_DIR/godot"
"$GODOT_DIR/godot" --headless --version

# ------------------------------------------------- 2. 导出模板（只取需要的）
log "准备 Android 导出模板"
mkdir -p "$TPL_DIR"
if [ ! -f "$TPL_DIR/android_release.apk" ]; then
  # 完整 .tpz 有 1.2GB，但我们只要里面两个安卓模板。
  # 用仓库自带的 tpzfetch 做远程 ZIP 局部下载，省掉约 0.78GB 流量。
  node "$REPO_ROOT/tools/tpzfetch.mjs" \
    "https://github.com/godotengine/godot/releases/download/${GODOT_VERSION}-stable/Godot_v${GODOT_VERSION}-stable_export_templates.tpz" \
    "$TPL_DIR" 'android_(debug|release)[.]apk$'
  printf '%s' "${GODOT_VERSION}.stable" > "$TPL_DIR/version.txt"
fi
ls -la "$TPL_DIR"
[ -f "$TPL_DIR/android_release.apk" ] || { echo "❌ 导出模板缺失"; exit 1; }

# ------------------------------------------------------------ 3. 签名密钥库
log "准备签名密钥库"
KEYSTORE="$RUNNER_TEMP/ci.keystore"
KEYSTORE_PASS="${KEYSTORE_PASS:-android}"
KEYSTORE_ALIAS="${KEYSTORE_ALIAS:-androiddebugkey}"

if [ -n "${KEYSTORE_BASE64:-}" ]; then
  printf '%s' "$KEYSTORE_BASE64" | base64 -d > "$KEYSTORE"
  echo "使用仓库配置的密钥库"
else
  keytool -genkeypair -v \
    -keystore "$KEYSTORE" -storetype PKCS12 \
    -alias "$KEYSTORE_ALIAS" -keyalg RSA -keysize 2048 -validity 10000 \
    -storepass "$KEYSTORE_PASS" -keypass "$KEYSTORE_PASS" \
    -dname "CN=CI Build,O=GitHub Actions,C=US" >/dev/null 2>&1
  echo "⚠️  未配置 KEYSTORE_BASE64，已生成临时调试密钥库"
  echo "    （APK 可正常安装，但无法覆盖由其它密钥签名的旧版本）"
fi
ls -l "$KEYSTORE"

# --------------------------------------------------------- 4. 定位 SDK / JDK
log "定位 Android SDK 与 JDK"
SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-/usr/local/lib/android/sdk}}"
[ -d "$SDK" ] || SDK="$(ls -d /usr/lib/android-sdk /opt/android-sdk 2>/dev/null | head -1 || true)"
[ -n "${SDK:-}" ] && [ -d "$SDK" ] || { echo "❌ 找不到 Android SDK"; ls -la /usr/local/lib/ 2>/dev/null; exit 1; }

JAVA="${JAVA_HOME:-}"
if [ -z "$JAVA" ]; then
  JC="$(command -v javac || true)"
  [ -n "$JC" ] && JAVA="$(dirname "$(dirname "$(readlink -f "$JC")")")"
fi
[ -n "${JAVA:-}" ] && [ -d "$JAVA" ] || { echo "❌ 找不到 JDK"; exit 1; }

echo "  SDK  = $SDK"
echo "  JDK  = $JAVA"
echo "  build-tools:"; ls "$SDK/build-tools" 2>/dev/null | sed 's/^/    /'
echo "  platforms:";   ls "$SDK/platforms"   2>/dev/null | sed 's/^/    /'
echo "  apksigner: $(ls -d "$SDK"/build-tools/*/apksigner 2>/dev/null | tail -1 || echo 缺)"

# --------------------------------------------------------- 5. 编辑器设置
log "写入 Godot 编辑器设置"
mkdir -p "$HOME/.config/godot"
cat > "$HOME/.config/godot/editor_settings-4.7.tres" <<EOF
[gd_resource type="EditorSettings" format=3]

[resource]
export/android/android_sdk_path = "$SDK"
export/android/java_sdk_path = "$JAVA"
export/android/debug_keystore = "$KEYSTORE"
export/android/debug_keystore_user = "$KEYSTORE_ALIAS"
export/android/debug_keystore_pass = "$KEYSTORE_PASS"
export/android/shutdown_adb_on_exit = false
EOF
cat "$HOME/.config/godot/editor_settings-4.7.tres"

# ------------------------------------------------------------- 6. 导出预设
log "准备导出预设"
PRESET="$PROJECT/export_presets.cfg"
if [ ! -f "$PRESET" ]; then
  echo "  项目无预设，从模板生成"
  sed "s|@PKG@|com.example.$(basename "$PROJECT" | tr '[:upper:]' '[:lower:]')|; \
       s|@NAME@|$(basename "$PROJECT")|" \
    "$REPO_ROOT/scripts/preset.template" > "$PRESET"
fi
sed -i \
  -e "s|^keystore/debug=.*|keystore/debug=\"$KEYSTORE\"|" \
  -e "s|^keystore/release=.*|keystore/release=\"$KEYSTORE\"|" \
  -e "s|^keystore/debug_user=.*|keystore/debug_user=\"$KEYSTORE_ALIAS\"|" \
  -e "s|^keystore/release_user=.*|keystore/release_user=\"$KEYSTORE_ALIAS\"|" \
  -e "s|^keystore/debug_password=.*|keystore/debug_password=\"$KEYSTORE_PASS\"|" \
  -e "s|^keystore/release_password=.*|keystore/release_password=\"$KEYSTORE_PASS\"|" \
  "$PRESET"
grep -E '^keystore/|^package/unique_name|^gradle_build/use_gradle' "$PRESET" | sed 's/password=.*/password="***"/'

# ---------------------------------------------------------------- 7. 导入
log "导入项目资源"
"$GODOT_DIR/godot" --headless --path "$PROJECT" --import || true
echo "(导入阶段返回码已忽略，下面进入正式导出)"

# ---------------------------------------------------------------- 8. 导出
log "导出 $BUILD_TYPE APK"
mkdir -p "$(dirname "$OUT_APK")"
rm -f "$OUT_APK"
set +e
"$GODOT_DIR/godot" --headless --path "$PROJECT" --export-"$BUILD_TYPE" "Android" "$OUT_APK"
EXPORT_RC=$?
set -e
echo "  导出退出码: $EXPORT_RC"
[ -f "$OUT_APK" ] || { echo "❌ 导出失败，APK 未生成"; ls -la "$(dirname "$OUT_APK")"; exit 1; }

# ---------------------------------------------------------------- 9. 校验
log "校验签名"
APKSIGNER="$(ls -d "$SDK"/build-tools/*/apksigner 2>/dev/null | sort -V | tail -1)"
if [ -n "$APKSIGNER" ]; then
  "$APKSIGNER" verify --verbose "$OUT_APK" | head -10
fi

SIZE=$(stat -c%s "$OUT_APK")
printf '\n\033[1;32m✅ 构建成功\033[0m\n  文件: %s\n  大小: %s MB\n' \
  "$OUT_APK" "$((SIZE / 1024 / 1024))"

{
  printf '### ✅ 构建成功\n\n'
  printf '| 项 | 值 |\n|---|---|\n'
  printf '| 项目 | `%s` |\n' "$PROJECT"
  printf '| 类型 | %s |\n' "$BUILD_TYPE"
  printf '| 大小 | %s MB |\n' "$((SIZE / 1024 / 1024))"
  printf '| Godot | %s |\n' "$GODOT_VERSION"
} >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
