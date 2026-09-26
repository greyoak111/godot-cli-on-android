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

PROJECT="${1:?用法: build-apk.sh <项目目录> [输出APK] [debug|release]}"
OUT_APK="${2:-$(pwd)/build/$(basename "$PROJECT").apk}"
BUILD_TYPE="${3:-release}"
GODOT_VERSION="${GODOT_VERSION:-4.7.2}"

GODOT_DIR="$HOME/godot"
TPL_DIR="$HOME/.local/share/godot/export_templates/${GODOT_VERSION}.stable"

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

# ---------------------------------------------------------------- 1. Godot
log "准备 Godot ${GODOT_VERSION}"
mkdir -p "$GODOT_DIR"
if [ ! -x "$GODOT_DIR/godot" ]; then
  ZIP="$GODOT_DIR/godot.zip"
  curl -fsSL --retry 3 -o "$ZIP" \
    "https://github.com/godotengine/godot/releases/download/${GODOT_VERSION}-stable/Godot_v${GODOT_VERSION}-stable_linux.x86_64.zip"
  unzip -oq "$ZIP" -d "$GODOT_DIR"
  mv "$GODOT_DIR"/Godot_v"${GODOT_VERSION}"-stable_linux.x86_64 "$GODOT_DIR/godot"
  chmod +x "$GODOT_DIR/godot"
  rm -f "$ZIP"
fi
"$GODOT_DIR/godot" --headless --version

# ------------------------------------------------- 2. 导出模板（只取需要的）
log "准备 Android 导出模板"
mkdir -p "$TPL_DIR"
if [ ! -f "$TPL_DIR/android_release.apk" ]; then
  # 完整 .tpz 有 1.2GB，但我们只要里面两个安卓模板。
  # 用仓库自带的 tpzfetch 做远程 ZIP 局部下载，省掉约 0.78GB 流量。
  node "$(dirname "$0")/../tools/tpzfetch.mjs" \
    "https://github.com/godotengine/godot/releases/download/${GODOT_VERSION}-stable/Godot_v${GODOT_VERSION}-stable_export_templates.tpz" \
    "$TPL_DIR" 'android_(debug|release)[.]apk$'
  printf '%s' "${GODOT_VERSION}.stable" > "$TPL_DIR/version.txt"
fi
ls -la "$TPL_DIR"

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

# --------------------------------------------------------- 4. 定位 SDK / JDK
log "定位 Android SDK 与 JDK"
SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-/usr/local/lib/android/sdk}}"
JAVA="${JAVA_HOME:-$(dirname "$(dirname "$(readlink -f "$(command -v javac)")")")}"
[ -d "$SDK" ] || { echo "找不到 Android SDK: $SDK"; exit 1; }
echo "SDK  = $SDK"
echo "JDK  = $JAVA"
ls "$SDK/build-tools" 2>/dev/null | tail -3

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

# ------------------------------------------------------------- 6. 导出预设
log "准备导出预设"
PRESET="$PROJECT/export_presets.cfg"
if [ ! -f "$PRESET" ]; then
  echo "项目无预设，从模板生成"
  sed "s|@PKG@|com.example.$(basename "$PROJECT" | tr '[:upper:]' '[:lower:]')|; \
       s|@NAME@|$(basename "$PROJECT")|" \
    "$(dirname "$0")/../scripts/preset.template" > "$PRESET"
fi
# 把签名相关指向 CI 的密钥库（覆盖模板里的本地路径）
sed -i \
  -e "s|^keystore/debug=.*|keystore/debug=\"$KEYSTORE\"|" \
  -e "s|^keystore/release=.*|keystore/release=\"$KEYSTORE\"|" \
  -e "s|^keystore/debug_user=.*|keystore/debug_user=\"$KEYSTORE_ALIAS\"|" \
  -e "s|^keystore/release_user=.*|keystore/release_user=\"$KEYSTORE_ALIAS\"|" \
  -e "s|^keystore/debug_password=.*|keystore/debug_password=\"$KEYSTORE_PASS\"|" \
  -e "s|^keystore/release_password=.*|keystore/release_password=\"$KEYSTORE_PASS\"|" \
  "$PRESET"
grep -E '^keystore/' "$PRESET" | sed 's/password=.*/password="***"/'

# ---------------------------------------------------------------- 7. 导入
log "导入项目资源"
"$GODOT_DIR/godot" --headless --path "$PROJECT" --import 2>&1 | tail -20

# ---------------------------------------------------------------- 8. 导出
log "导出 $BUILD_TYPE APK"
mkdir -p "$(dirname "$OUT_APK")"
rm -f "$OUT_APK"
"$GODOT_DIR/godot" --headless --path "$PROJECT" \
  --export-"$BUILD_TYPE" "Android" "$OUT_APK" 2>&1 | tail -30

[ -f "$OUT_APK" ] || { echo "❌ 导出失败，APK 未生成"; exit 1; }

# ---------------------------------------------------------------- 9. 校验
log "校验签名"
APKSIGNER="$(ls -d "$SDK"/build-tools/*/apksigner 2>/dev/null | sort -V | tail -1)"
if [ -n "$APKSIGNER" ]; then
  "$APKSIGNER" verify --verbose "$OUT_APK" | head -10
fi

SIZE=$(stat -c%s "$OUT_APK")
printf '\n\033[1;32m✅ 构建成功\033[0m\n  文件: %s\n  大小: %s MB\n' \
  "$OUT_APK" "$((SIZE / 1024 / 1024))"
