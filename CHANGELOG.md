# Changelog

## v1.1.0 — 打包可复用

### 自足化
- `scripts/stage.sh` 不再依赖任何预装环境：自己下载 Godot、
  用仓库内置 `tools/tpkg.mjs` 从 Termux 仓库抽取 glibc/JDK/依赖、
  打 libc 补丁、拉导出模板。**只需 node，无需 npm install。**
- 新增 `tools/tpkg.mjs`（Termux .deb 抽取器）
- 内置 `tools/vendor/xz-decompress`（71KB，纯 JS/WASM）——
  Termux 的 deb 是 `data.tar.xz`，而安卓自带工具链（含 toybox）
  没有任何 xz 解压器，这个依赖无法用系统工具替代
- `tpkg` 支持 `TPKG_PREFIX` / `TPKG_CACHE` / `TPKG_STAGE` 覆盖

### 上游文档草稿
- `docs/upstream/issue-1-input-scan-crash.md` —— `/dev/input` 不可读时
  编辑器以堆损坏崩溃（含 gdb 调用栈、`.eh_frame` 函数定位、字符串指纹）
- `docs/upstream/issue-2-etc2-host-os.md` —— ETC2/ASTC 校验依赖宿主 OS

### 文档
- README 新增《安装（从零开始）》

## v1.0.1

- 统一签名：CI 支持通过 `KEYSTORE_BASE64` Secret 使用仓库配置的密钥库，
  使云端与本机构建的 APK 同签名、可互相覆盖升级

## v1.0.0

首个版本：在 Android 平板上跑无头 Godot 的完整方案。

### 能力

- Godot 4.7.2 无头运行（官方 `linux.arm64` 构建 + glibc 兼容层）
- 项目导入 → APK 导出 → 签名 → 装机 → 运行，**全部在设备上完成**
- 持久化双层布局（数据在 `/sdcard`，执行层在 `/data/local/tmp`）
- 一键恢复：执行层被清空后可从暂存区重建
- GitHub Actions 自动构建

### 解决的关键问题

| 问题 | 根因 | 解法 |
|---|---|---|
| 编辑器/导出崩溃 `free(): invalid size` | Godot 输入设备扫描读不了 `/dev/input`，走进有堆损坏 bug 的错误路径 | 以 `shell` 身份运行（属于 `input` 组） |
| `popen()` 全废 | Termux 的 glibc 把 shell 路径硬编码进 `libc.so.6` | 二进制原地替换 7 处路径字符串 |
| apksigner 建不了临时文件 | 安卓没有 `/tmp` | 包装器指定 `-Djava.io.tmpdir` |
| 本地能导出、CI 报 ETC2/ASTC | `should_import_etc2_astc()` 回退到**宿主 OS** 的首选纹理格式 | 项目显式开启 `import_etc2_astc` |
| Actions 日志读不到 | 日志 API 需要 admin 权限 | 失败时以 commit comment 回传 |

### 工具

- `tools/patchlibc.mjs` — glibc 路径补丁（原地替换，NUL 补齐）
- `tools/elfneed.mjs` — ELF 依赖分析（无需 readelf）
- `tools/tpzfetch.mjs` — 远程 ZIP 局部下载（1.22GB 的模板包只取 221MB）
