// tpzfetch.mjs — 远程 ZIP 局部下载：只取指定条目，不下载整个包
// 用法: node tpzfetch.mjs <url> <输出目录> [条目名过滤正则]
import fs from "node:fs";
import path from "node:path";
import zlib from "node:zlib";

const url = process.argv[2];
const outDir = process.argv[3] || ".";
const filter = process.argv[4] ? new RegExp(process.argv[4]) : null;
fs.mkdirSync(outDir, { recursive: true });

async function rng(start, end) {
  const r = await fetch(url, {
    headers: { Range: `bytes=${start}-${end}` },
    signal: AbortSignal.timeout(300000),
  });
  if (r.status !== 206 && r.status !== 200) throw new Error("Range 请求失败: HTTP " + r.status);
  return Buffer.from(await r.arrayBuffer());
}

// 1) 总长度
const head = await fetch(url, { method: "HEAD", redirect: "follow", signal: AbortSignal.timeout(60000) });
const total = Number(head.headers.get("content-length"));
console.log(`远程文件 ${(total / 1073741824).toFixed(2)} GB`);

// 2) 尾部找 EOCD
const tailLen = Math.min(66560, total);
const tail = await rng(total - tailLen, total - 1);
let eocd = -1;
for (let i = tail.length - 22; i >= 0; i--) {
  if (tail.readUInt32LE(i) === 0x06054b50) { eocd = i; break; }
}
if (eocd < 0) throw new Error("找不到 EOCD");
let cdCount = tail.readUInt16LE(eocd + 10);
let cdSize = tail.readUInt32LE(eocd + 12);
let cdOff = tail.readUInt32LE(eocd + 16);
let base = total - tailLen;   // tail 在文件中的起点

// ZIP64 处理
if (cdOff === 0xffffffff || cdCount === 0xffff) {
  for (let i = eocd - 20; i >= 0; i--) {
    if (tail.readUInt32LE(i) === 0x07064b50) {
      const z64Off = Number(tail.readBigUInt64LE(i + 8));
      const z = await rng(z64Off, z64Off + 55);
      cdCount = Number(z.readBigUInt64LE(32));
      cdSize = Number(z.readBigUInt64LE(40));
      cdOff = Number(z.readBigUInt64LE(48));
      console.log(`  ZIP64: ${cdCount} 条目`);
      break;
    }
  }
}
console.log(`中央目录: ${cdCount} 个条目, ${(cdSize / 1048576).toFixed(1)} MB @ ${cdOff}`);

// 3) 拉中央目录
let cd;
if (cdOff >= base) {
  cd = tail.subarray(cdOff - base, cdOff - base + cdSize);
} else {
  cd = await rng(cdOff, cdOff + cdSize - 1);
}

// 4) 解析条目
const entries = [];
let off = 0;
while (off + 46 <= cd.length) {
  if (cd.readUInt32LE(off) !== 0x02014b50) break;
  const method = cd.readUInt16LE(off + 10);
  let csize = cd.readUInt32LE(off + 20);
  let usize = cd.readUInt32LE(off + 24);
  const nlen = cd.readUInt16LE(off + 28);
  const elen = cd.readUInt16LE(off + 30);
  const clen = cd.readUInt16LE(off + 32);
  let lho = cd.readUInt32LE(off + 42);
  const name = cd.subarray(off + 46, off + 46 + nlen).toString("utf8");
  // ZIP64 extra
  if (usize === 0xffffffff || csize === 0xffffffff || lho === 0xffffffff) {
    let e = off + 46 + nlen;
    const eend = e + elen;
    while (e + 4 <= eend) {
      const hid = cd.readUInt16LE(e), hsz = cd.readUInt16LE(e + 2);
      if (hid === 0x0001) {
        let p = e + 4;
        if (usize === 0xffffffff) { usize = Number(cd.readBigUInt64LE(p)); p += 8; }
        if (csize === 0xffffffff) { csize = Number(cd.readBigUInt64LE(p)); p += 8; }
        if (lho === 0xffffffff) { lho = Number(cd.readBigUInt64LE(p)); p += 8; }
        break;
      }
      e += 4 + hsz;
    }
  }
  entries.push({ name, method, csize, usize, lho });
  off += 46 + nlen + elen + clen;
}
console.log(`解析到 ${entries.length} 个条目\n`);

// 5) 下载目标条目
const want = entries.filter((e) => !filter || filter.test(e.name));
console.log(`=== 命中 ${want.length} 个条目 ===`);
let saved = 0;
for (const e of want) {
  const lh = await rng(e.lho, e.lho + 29);
  const nlen = lh.readUInt16LE(26), elen = lh.readUInt16LE(28);
  const dstart = e.lho + 30 + nlen + elen;
  const raw = await rng(dstart, dstart + e.csize - 1);
  const data = e.method === 0 ? raw : zlib.inflateRawSync(raw);
  const dest = path.join(outDir, path.basename(e.name));
  fs.writeFileSync(dest, data);
  saved++;
  console.log(`  ${(data.length / 1048576).toFixed(1).padStart(7)} MB  ${e.name}`);
}
console.log(`\n共下载 ${saved} 个条目，避免了 ${((total - want.reduce((a, e) => a + e.csize, 0)) / 1073741824).toFixed(2)} GB 的传输`);
