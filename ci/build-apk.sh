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

# ---- 留痕：全程写日志文件。直接重定向而非 tee —— 进程替换在异常退出时
#      可能丢缓冲，会把最关键的失败现场吞掉（已踩过）。失败时再回吐到 stdout。----
exec 3>&1
LOG="${RUNNER_TEMP:-/tmp}/build.log"
exec > "$LOG" 2>&1

on_err() {
  local rc=$? line=$1
  exec 1>&3 2>&3
  printf '\n\033[1;31m❌ 构建失败（第 %s 行，退出码 %s）\033[0m\n' "$line" "$rc"
  printf -- '---- 日志尾部 ----\n'
  tail -80 "$LOG" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g'
  {
    printf '### ❌ 构建失败\n\n第 **%s** 行，退出码 **%s**\n\n' "$line" "$rc"
    printf '```text\n'
    tail -100 "$LOG" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g'
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

# Godot 的输入设备扫描在 /dev/input 不可读时会走进一条有堆损坏 bug 的
# 错误路径（本地已在 4.7.2/4.5.1 上定位到：free(): invalid size）。
# CI runner 上该目录可能压根不存在，先诊断，必要时建一个空目录 ——
# 空目录能正常扫描（0 个设备），从而绕开那条错误路径。
if [ -d /dev/input ]; then
  echo "  /dev/input          = 存在，$(ls /dev/input 2>/dev/null | wc -l) 个条目，可读=$([ -r /dev/input ] && echo 是 || echo 否)"
else
  echo "  /dev/input          = 不存在"
  if sudo -n mkdir -p /dev/input 2>/dev/null; then
    echo "                        → 已创建空目录以绕开 Godot 的输入扫描错误路径"
  else
    echo "                        → 无法创建（无 sudo），继续尝试"
  fi
fi

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

gen_temp_keystore() {
  keytool -genkeypair -v \
    -keystore "$KEYSTORE" -storetype PKCS12 \
    -alias "$KEYSTORE_ALIAS" -keyalg RSA -keysize 2048 -validity 10000 \
    -storepass "$KEYSTORE_PASS" -keypass "$KEYSTORE_PASS" \
    -dname "CN=CI Build,O=GitHub Actions,C=US" >/dev/null 2>&1
}

USE_SECRET=0
if [ -n "${KEYSTORE_BASE64:-}" ]; then
  # Secret 常被复制成多行/带空格（编辑器换行、缩进），这里先清掉所有空白字符。
  # 之前踩过：直接 base64 -d 会报 "base64: invalid input" 并让整个构建挂掉。
  CLEAN="$(printf '%s' "$KEYSTORE_BASE64" | tr -d '[:space:]')"
  if printf '%s' "$CLEAN" | base64 -d > "$KEYSTORE" 2>/dev/null && [ -s "$KEYSTORE" ]; then
    # 再验证它确实是个能被 keytool 读出来的密钥库
    if keytool -list -keystore "$KEYSTORE" -storepass "$KEYSTORE_PASS" \
         -alias "$KEYSTORE_ALIAS" >/dev/null 2>&1; then
      USE_SECRET=1
      echo "✅ 使用仓库配置的密钥库（KEYSTORE_BASE64）"
      keytool -list -v -keystore "$KEYSTORE" -storepass "$KEYSTORE_PASS" -alias "$KEYSTORE_ALIAS" 2>/dev/null \
        | grep -E "SHA256:|Owner:" | sed 's/^/    /'
    else
      echo "⚠️  KEYSTORE_BASE64 解出来不是有效密钥库（密码/别名不对？），改用临时密钥"
      echo "    提示：默认密码 android、别名 androiddebugkey"
    fi
  else
    echo "⚠️  KEYSTORE_BASE64 不是合法 base64（长度 ${#CLEAN}），改用临时密钥"
  fi
fi

if [ "$USE_SECRET" != "1" ]; then
  gen_temp_keystore
  echo "⚠️  已生成临时调试密钥库 —— APK 可正常安装，"
  echo "    但无法覆盖由其它密钥签名的旧版本（INSTALL_FAILED_UPDATE_INCOMPATIBLE）"
fi
ls -l "$KEYSTORE"

# --------------------------------------------------------- 4. 定位 SDK / JDK
log "定位 Android SDK 与 JDK"
SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-/usr/local/lib/android/sdk}}"
[ -d "$SDK" ] || SDK="$(ls -d /usr/lib/android-sdk /opt/android-sdk 2>/dev/null | head -1 || true)"
[ -n "${SDK:-}" ] && [ -d "$SDK" ] || { echo "❌ 找不到 Android SDK"; ls -la /usr/local/lib/ 2>/dev/null; exit 1; }

# ★ Godot 会逐个校验 SDK 里存在这些**确切**目录（见 editor/export/android_sdk_manager.cpp）:
#     build-tools/36.1.0    platforms/android-36
#   runner 预装的版本往往不是这两个；缺了就补装，否则导出会以
#   "Unable to find Android SDK package '...'" 中止。
NEED_BT="36.1.0"
NEED_PLATFORM="android-36"
if [ ! -d "$SDK/build-tools/$NEED_BT" ] || [ ! -d "$SDK/platforms/$NEED_PLATFORM" ]; then
  echo "  缺少 build-tools/$NEED_BT 或 platforms/$NEED_PLATFORM，尝试用 sdkmanager 补装"
  SDKMANAGER="$(ls "$SDK"/cmdline-tools/*/bin/sdkmanager 2>/dev/null | sort -V | tail -1 || true)"
  [ -n "$SDKMANAGER" ] || SDKMANAGER="$(command -v sdkmanager || true)"
  if [ -n "$SDKMANAGER" ]; then
    yes | "$SDKMANAGER" --sdk_root="$SDK" \
      "build-tools;$NEED_BT" "platforms;$NEED_PLATFORM" "platform-tools" 2>&1 | tail -15 || true
  else
    echo "  ⚠️  找不到 sdkmanager，无法补装"
  fi
fi

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
echo "  platform-tools/adb: $([ -f "$SDK/platform-tools/adb" ] && echo 有 || echo 缺)"
echo "  apksigner: $(ls -d "$SDK"/build-tools/*/apksigner 2>/dev/null | sort -V | tail -1 || echo 缺)"

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

# Godot 的 should_import_etc2_astc() 在项目未显式开启时会回退去看
# **宿主 OS** 的首选纹理格式：Android 宿主天然满足，Linux 宿主则不满足。
# 因此同一项目在本机(Android)能导出、在 CI(Linux)会以
# "ETC2/ASTC texture compression is required" 中止。
# 这里做一次保险：项目没开就自动补上，使项目可移植。
if ! grep -q "import_etc2_astc" "$PROJECT/project.godot" 2>/dev/null; then
  echo "  项目未开启 ETC2/ASTC，自动补上（否则 Linux 宿主上无法导出安卓）"
  if grep -q "^\[rendering\]" "$PROJECT/project.godot"; then
    printf "textures/vram_compression/import_etc2_astc=true\n" >> "$PROJECT/project.godot"
  else
    printf "\n[rendering]\ntextures/vram_compression/import_etc2_astc=true\n" >> "$PROJECT/project.godot"
  fi
fi

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
