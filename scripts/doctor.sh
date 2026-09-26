#!/system/bin/sh
# godot-doctor —— 环境体检
# 用法: sh doctor.sh

G=/data/local/tmp/dshgodot
DATA=/sdcard/DeepSeekHarness/godot
OK=0; BAD=0
chk() { # chk <描述> <命令...>
	desc="$1"; shift
	if "$@" >/dev/null 2>&1; then
		printf "  ✅ %s\n" "$desc"; OK=$((OK+1))
	else
		printf "  ❌ %s\n" "$desc"; BAD=$((BAD+1))
	fi
}

echo "════ Godot 环境体检 ════"
echo ""
echo "【权限】"
printf "  当前 uid: %s %s\n" "$(id -u)" "$([ "$(id -u)" = 2000 ] && echo '(shell ✓)' || echo '(非 shell)')"

echo ""
echo "【执行层 $G】"
chk "godot 二进制"        test -x $G/godot
chk "glibc loader"        test -f $G/glibclib/ld-linux-aarch64.so.1
chk "glibc libc.so.6"     test -f $G/glibclib/libc.so.6
chk "libc 已打补丁"       grep -q "dshgodot" $G/glibclib/libc.so.6 2>/dev/null
chk "popen shell"         test -x $G/fakebin/sh
chk "tmp 目录"            test -d $G/tmp
chk "JDK17"               test -x $G/jvm/bin/java
chk "apksigner 包装器"    test -x $G/sdk/build-tools/36.1.0/apksigner
chk "apksigner.jar"       test -f $G/sdk/build-tools/36.1.0/apksigner.jar

echo ""
echo "【持久层 $DATA】"
chk "导出模板 debug"      test -f $DATA/templates/4.7.2.stable/android_debug.apk
chk "导出模板 release"    test -f $DATA/templates/4.7.2.stable/android_release.apk
chk "签名密钥库"          test -f $DATA/keystore/debug.keystore
chk "android.jar"         test -f $DATA/platform/android.jar

echo ""
echo "【符号链接】"
for L in home/.local/share/godot/export_templates home/.android projects out sdk/platforms/android-36/android.jar; do
	if [ -L "$G/$L" ] && [ -e "$G/$L" ]; then
		printf "  ✅ %s → %s\n" "$L" "$(readlink $G/$L)"
		OK=$((OK+1))
	else
		printf "  ❌ %s （链接失效）\n" "$L"; BAD=$((BAD+1))
	fi
done

echo ""
echo "【功能自检】"
V=$(LD_LIBRARY_PATH=$G/lib:$G/jvm/lib $G/jvm/bin/java -version 2>&1 | head -1)
[ -n "$V" ] && { echo "  ✅ java: $V"; OK=$((OK+1)); } || { echo "  ❌ java 不可用"; BAD=$((BAD+1)); }
A=$(LD_LIBRARY_PATH=$G/lib:$G/jvm/lib $G/sdk/build-tools/36.1.0/apksigner --version 2>&1 | head -1)
[ -n "$A" ] && { echo "  ✅ apksigner: $A"; OK=$((OK+1)); } || { echo "  ❌ apksigner 不可用"; BAD=$((BAD+1)); }
if [ "$(id -u)" = 2000 ]; then
	GV=$(HOME=$G/home XDG_DATA_HOME=$G/home/.local/share XDG_CONFIG_HOME=$G/home/.config XDG_CACHE_HOME=$G/home/.cache \
	     $G/glibclib/ld-linux-aarch64.so.1 --library-path $G/glibclib:$G/lib $G/godot --headless --version 2>/dev/null | tail -1)
	[ -n "$GV" ] && { echo "  ✅ godot: $GV"; OK=$((OK+1)); } || { echo "  ❌ godot 不可用"; BAD=$((BAD+1)); }
	[ -r /dev/input/event0 ] && { echo "  ✅ /dev/input 可读（关键！）"; OK=$((OK+1)); } \
	                        || { echo "  ❌ /dev/input 不可读（会导致编辑器崩溃）"; BAD=$((BAD+1)); }
else
	echo "  ⚠️  非 shell 身份，跳过 godot/input 自检"
fi

echo ""
echo "【磁盘】"
printf "  执行层占用: %s\n" "$(du -sh $G 2>/dev/null | cut -f1)"
printf "  持久层占用: %s\n" "$(du -sh $DATA 2>/dev/null | cut -f1)"

echo ""
echo "════ 结果: $OK 项正常, $BAD 项异常 ════"
[ "$BAD" = 0 ] && echo "环境健康 ✓"
exit $BAD
