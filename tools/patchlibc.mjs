// patchlibc.mjs — 原地替换 glibc 里硬编码的 Termux 路径（新路径更短，NUL 补齐）
import fs from "node:fs";

const src = process.argv[2];
const dst = process.argv[3];
const b = fs.readFileSync(src);

// 原路径 -> 新路径（新必须不长于原）
const REPL = [
  ["/data/data/com.termux/files/usr/glibc/bin/sh", "/data/local/tmp/dshgodot/fakebin/sh"],
  ["/data/data/com.termux/files/usr/glibc/bin/csh", "/data/local/tmp/dshgodot/fakebin/sh"],
  ["/data/data/com.termux/files/usr/tmp/sem.XXXXXX", "/data/local/tmp/dshgodot/tmp/sem.XXXXXX"],
  ["/data/data/com.termux/files/usr/tmp", "/data/local/tmp/dshgodot/tmp"],
];

let patched = 0;
for (const [oldS, newS] of REPL) {
  if (newS.length > oldS.length) {
    console.log(`  ❌ 跳过（新路径更长）: ${newS}`);
    continue;
  }
  const oldBuf = Buffer.from(oldS, "latin1");
  const newBuf = Buffer.concat([
    Buffer.from(newS, "latin1"),
    Buffer.alloc(oldS.length - newS.length, 0), // NUL 补齐
  ]);
  let from = 0, count = 0;
  for (;;) {
    const i = b.indexOf(oldBuf, from);
    if (i < 0) break;
    newBuf.copy(b, i);
    count++;
    from = i + oldBuf.length;
  }
  console.log(`  ${count} 处  "${oldS}"\n         -> "${newS}"`);
  patched += count;
}

fs.writeFileSync(dst, b);
console.log(`\n共替换 ${patched} 处，已写出 ${dst} (${(b.length / 1048576).toFixed(1)} MB)`);
