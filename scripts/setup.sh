#!/system/bin/sh
# godot-setup —— 从暂存区重建执行层（/data/local/tmp 被清空后的一键恢复）
#
# 恢复流程（两步）：
#   1) 【应用侧】由 DSH 执行暂存（把 godot/glibc/JDK 从应用私有目录拷到暂存区）
#   2) 【shell 侧】sh setup.sh
#
# 用法: sh setup.sh [--check]

set -e
G=/data/local/tmp/dshgodot
DATA=/sdcard/DeepSeekHarness/godot
STAGE=$DATA/_stage

echo "════ Godot 执行层重建 ════"
echo ""

if [ "$1" = "--check" ]; then
	echo "暂存区: $STAGE"
	ls -1 "$STAGE" 2>/dev/null | sed 's/^/  /' || echo "  (空)"
	echo ""
	echo "执行层: $G"
	[ -d "$G" ] && du -sh "$G" || echo "  (不存在)"
	exit 0
fi

if [ ! -d "$STAGE" ]; then
	echo "❌ 暂存区不存在: $STAGE"
	echo "   请先让 DSH 执行应用侧暂存"
	exit 1
fi

echo "=== 1) 建目录 ==="
mkdir -p $G/home/.local/share/godot $G/home/.config/godot $G/home/.cache/godot $G/tmp $G/fakebin
mkdir -p $G/sdk/build-tools/36.1.0 $G/sdk/platforms/android-36 $G/sdk/platform-tools

echo "=== 2) 部署 godot 二进制 ==="
[ -f "$STAGE/godot" ] && cp -f "$STAGE/godot" $G/godot && chmod 755 $G/godot && echo "  ✓ godot"

echo "=== 3) 部署 glibc 运行时 ==="
if [ -d "$STAGE/glibclib" ]; then
	rm -rf $G/glibclib
	cp -a "$STAGE/glibclib" $G/glibclib
	chmod -R 755 $G/glibclib
	echo "  ✓ glibc ($(du -sh $G/glibclib | cut -f1))"
fi

echo "=== 4) 部署依赖库 ==="
if [ -d "$STAGE/lib" ]; then
	rm -rf $G/lib; mkdir -p $G/lib
	cp -f "$STAGE/lib"/* $G/lib/ 2>/dev/null || true
	chmod -R 755 $G/lib
	# 重建 SONAME 符号链接（/sdcard 中转会丢链接）
	cd $G/lib
	for f in *.so.*; do
		[ -e "$f" ] || continue
		b=$(echo "$f" | sed 's/\(\.so\.[0-9][0-9]*\).*/\1/')
		[ "$b" != "$f" ] && ln -sf "$f" "$b"
		p=$(echo "$f" | sed 's/\(\.so\).*/\1/')
		[ "$p" != "$f" ] && [ ! -e "$p" ] && ln -sf "$f" "$p"
	done
	cd - >/dev/null
	echo "  ✓ lib ($(ls $G/lib | wc -l) 个文件)"
fi

echo "=== 5) 部署 JDK ==="
if [ -d "$STAGE/jvm" ]; then
	rm -rf $G/jvm
	cp -a "$STAGE/jvm" $G/jvm
	chmod -R 755 $G/jvm
	[ -f "$G/jvm/bin/java" ] && chmod 755 $G/jvm/bin/java
	echo "  ✓ JDK ($(du -sh $G/jvm | cut -f1))"
fi

echo "=== 6) apksigner + adb 桩 ==="
[ -f "$STAGE/apksigner.jar" ] && cp -f "$STAGE/apksigner.jar" $G/sdk/build-tools/36.1.0/
cat > $G/sdk/build-tools/36.1.0/apksigner <<'WRAP'
#!/system/bin/sh
G=/data/local/tmp/dshgodot
export LD_LIBRARY_PATH=$G/lib:$G/jvm/lib
exec "$G/jvm/bin/java" -Djava.io.tmpdir=$G/tmp -jar $G/sdk/build-tools/36.1.0/apksigner.jar "$@"
WRAP
chmod 755 $G/sdk/build-tools/36.1.0/apksigner
# Godot 只对 adb 做存在性校验；本机装机走 pm install，不需要真 adb
printf '#!/system/bin/sh\necho "adb stub — 本机装机走 pm install"\nexit 0\n' > $G/sdk/platform-tools/adb
chmod 755 $G/sdk/platform-tools/adb
echo "  ✓ apksigner + adb 桩"

echo "=== 7) popen 用的 shell ==="
cat > $G/fakebin/sh <<'SH'
#!/system/bin/sh
exec /system/bin/sh "$@"
SH
chmod 755 $G/fakebin/sh
echo "  ✓ fakebin/sh"

echo "=== 8) 数据层符号链接 ==="
ln -sfn $DATA/templates $G/home/.local/share/godot/export_templates
ln -sfn $DATA/keystore  $G/home/.android
ln -sfn $DATA/projects  $G/projects
ln -sfn $DATA/out       $G/out
ln -sfn $DATA/platform/android.jar $G/sdk/platforms/android-36/android.jar
echo "  ✓ 5 个链接"

echo "=== 9) 编辑器设置 ==="
cat > $G/home/.config/godot/editor_settings-4.7.tres <<EOF
[gd_resource type="EditorSettings" format=3]

[resource]
export/android/android_sdk_path = "$G/sdk"
export/android/debug_keystore = "$DATA/keystore/debug.keystore"
export/android/debug_keystore_user = "androiddebugkey"
export/android/debug_keystore_pass = "android"
export/android/java_sdk_path = "$G/jvm"
export/android/shutdown_adb_on_exit = false
EOF
echo "  ✓ editor_settings"

echo "=== 10) 重建调试密钥库（若缺失）==="
if [ ! -f "$DATA/keystore/debug.keystore" ]; then
	LD_LIBRARY_PATH=$G/lib:$G/jvm/lib $G/jvm/bin/keytool -genkeypair \
		-keystore "$DATA/keystore/debug.keystore" -storetype PKCS12 \
		-alias androiddebugkey -keyalg RSA -keysize 2048 -validity 10000 \
		-storepass android -keypass android \
		-dname "CN=Android Debug,O=Android,C=US" 2>&1 | tail -2
	echo "  ✓ 已生成"
else
	echo "  ✓ 已存在"
fi

chmod -R 777 $G 2>/dev/null || true
echo ""
echo "════ 重建完成 ════"
du -sh $G
echo "自检: sh $DATA/scripts/doctor.sh"
