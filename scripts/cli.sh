#!/system/bin/sh
# 无头 Godot CLI（shell 侧实体）
G=/data/local/tmp/dshgodot
H=$G/home
export HOME="$H" XDG_DATA_HOME="$H/.local/share" XDG_CONFIG_HOME="$H/.config" XDG_CACHE_HOME="$H/.cache"
export FONTCONFIG_FILE=/sdcard/DeepSeekHarness/godot/fonts.conf
export PATH=$G/fakebin:$PATH
exec "$G/glibclib/ld-linux-aarch64.so.1" --library-path "$G/glibclib:$G/lib" "$G/godot" "$@"
