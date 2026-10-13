#!/system/bin/sh
# 无头 Godot CLI（shell 侧实体）
G=/data/local/tmp/dshgodot
DATA="${GODOT_DATA:-/sdcard/DeepSeekHarness/godot}"
H=$G/home
export HOME="$H" XDG_DATA_HOME="$H/.local/share" XDG_CONFIG_HOME="$H/.config" XDG_CACHE_HOME="$H/.cache"
export FONTCONFIG_FILE="$DATA/fonts.conf"
export PATH=$G/fakebin:$PATH
# Godot 的临时目录被 tools/patchgodot.mjs 改成了相对路径（安卓没有可写的 /tmp），
# 所以必须 cd 到可写目录，否则导出会因为建不了临时文件而中止。
# 副作用：命令行里的相对路径（如 --path）是相对这里解析的，请用绝对路径。
cd "$G/tmp" 2>/dev/null || cd /data/local/tmp
exec "$G/glibclib/ld-linux-aarch64.so.1" --library-path "$G/glibclib:$G/lib" "$G/godot" "$@"
