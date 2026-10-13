// patchgodot.mjs —— 让 Godot 的临时目录不依赖 /tmp
//
// ## 为什么需要
//
// Godot 的 Unix 端把临时目录**写死在源码里**：
//
//     // drivers/unix/os_unix.cpp
//     String OS_Unix::get_temp_path() const {
//         return "/tmp";
//     }
//
// 没有环境变量、没有兜底。而**安卓根目录是只读挂载**，很多设备上根本没有 `/tmp`
// （实测 Nubia NX769J / Android 14：`mount` 显示 `on / type ext4 (ro,…)`，
// 连 Shizuku 的 shell 身份也建不出来）。
//
// 后果：导出流程走到 PCK 保存时用 FileAccess::create_temp()，
//      而它调上面的 get_temp_path()，于是：
//          Error while creating temporary file: could not create "/tmp/export-….tmp"
//          Save PCK: Could not create temporary file!
//      导出到此中止，**不产出 APK**。
//
// （编辑器的临时目录有另一条路径：EditorPaths 在「自足模式」下用 data_dir/temp，
//   那个靠二进制旁的 `._sc_` 标记文件就能解决，见 setup.sh。）
//
// ## 做法
//
// 把那个字符串字面量 `/tmp` 原地换成 `.`（NUL 补齐，长度不变、不破坏任何偏移）。
// `path_join(".")` 得到的是相对路径，于是临时文件落到**当前工作目录** ——
// 启动器里 cd 到可写目录即可（cli.sh / export.sh 已处理）。
//
// 该字面量在 38MB 的二进制里**只出现 1 次**，脚本会断言这一点，不满足就拒绝改。
//
// 用法: node tools/patchgodot.mjs <godot 二进制> [--check]

import fs from "node:fs";

// 用带结尾 NUL 的 5 字节定位（全二进制里唯一），只替换前 4 字节。
const NEEDLE = Buffer.from("/tmp\0");
// ⚠️ 不能补成 "." + 三个 NUL：Godot 构造这个 String 时用的是**编译期数组长度**
// （C 字面量 "/tmp" 的数组是 5 字节，取 N-1 = 4），根本不看 NUL。
// 结果会变成 "." + 3 个垃圾字节，路径仍然是坏的：
//     could not create ".???/export-….tmp"
// 所以必须填满 4 个**有效字符**。`.///` 作为路径就等于 `.`（多余的斜杠无害），
// 而且两种长度假设（strlen 或编译期长度）下都能正确工作。
const PATCHED = Buffer.from(".///");

const args = process.argv.slice(2);
const checkOnly = args.includes("--check");
const path = args.find((a) => !a.startsWith("--"));

if (!path) {
	console.error("用法: node tools/patchgodot.mjs <godot 二进制> [--check]");
	process.exit(2);
}

const buf = fs.readFileSync(path);

let count = 0;
for (let i = buf.indexOf(NEEDLE); i >= 0; i = buf.indexOf(NEEDLE, i + 1)) count++;

if (count === 0 && buf.indexOf(PATCHED) >= 0) {
	console.log("已打过补丁，无需改动: " + path);
	process.exit(0);
}
if (count !== 1) {
	console.error(`⚠️ 目标字符串 /tmp 出现 ${count} 次（预期恰好 1 次），不敢自动改。`);
	console.error("   可能是 Godot 版本变了，请重新确认补丁点，不要盲目跳过。");
	process.exit(1);
}

const off = buf.indexOf(NEEDLE);
if (checkOnly) {
	console.log(`未打补丁（可以打）: ${path}  @0x${off.toString(16)}`);
	process.exit(0);
}

const out = Buffer.from(buf);
PATCHED.copy(out, off);
fs.writeFileSync(path, out);
console.log(`✅ 已打补丁: ${path}`);
console.log(`   偏移 0x${off.toString(16)}: "/tmp" → ".///"（等于当前工作目录，临时文件落在那里）`);
