# Changelog

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
