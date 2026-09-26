# [Draft] Editor crashes with heap corruption when `/dev/input` is not readable

> 状态：草稿，待提交到 https://github.com/godotengine/godot/issues/new
> 提交前请先按文末《提交前自查》核对

---

**Godot version:** 4.5.1.stable.official, 4.7.2.stable.official（两个版本表现一致）

**System information:**
Android 15 (SDK 35) / arm64 / Snapdragon 8+ Gen 1

⚠️ **先说清楚环境，避免误导维护者**：我们跑的是 **Godot 官方 Linux arm64 构建**
（`Godot_v4.7.2-stable_linux.arm64`），在 Android 上通过 Termux 的 glibc 2.44 运行时加载。
这是**非官方支持的组合**。但下面的现象指向的可能是与平台无关的错误路径问题，
所以仍然值得报告。

---

## Issue description

当进程**无权读取 `/dev/input`** 时，编辑器相关操作（`--import` / `--editor` / `--export-*`）
会以 **glibc 堆损坏**（`free(): invalid size` → SIGABRT）终止，而不是优雅降级。

**运行游戏（`--headless --path <proj>`）不受影响**，只有走编辑器代码路径的操作会崩。
崩溃点不在主线程，而在一个输入设备扫描的工作线程。

### 现象

```
$ godot --headless --path proj --export-release Android out.apk
Godot Engine v4.7.2.stable.official.ed1daf0bf - https://godotengine.org
Regenerating editor help cache
Class 'AnchorPresetPicker' is not exposed, skipping.
free(): invalid size
（进程 SIGABRT，退出码 134）
```

`--import` 的表现略有不同：**能正常完成导入**，但在**退出时**以同一条消息崩溃。
`--editor --quit` 与导出同样崩溃。

### 关键 A/B 对照

同一个二进制、同一个项目、同一台设备，**唯一差别是进程有没有 `/dev/input` 读权限**：

| 运行身份 | `/dev/input` | 编辑器 / 导出 |
|---|---|---|
| `untrusted_app`（普通安卓应用，读不了） | ❌ Permission denied | ❌ 崩溃 |
| `shell`（属于 `input` 组 gid 1004，可读） | ✅ 可读 | ✅ 全部正常 |

`ls /dev/input` 在第一种身份下是 `Permission denied`，第二种能列出 `event0..event5`。

---

## 调试证据

用 gdb 18.1（Termux 抽取的构建）抓到的真实调用栈：

```
#0  __pthread_kill_implementation   (libc)
#1  raise                           (libc)
#2  abort                           (libc)
#3  __libc_message_impl             (libc)
#4  malloc_printerr                 (libc)
#5  malloc_printerr_tail            (libc)
#6  0x0000000000814400 in ?? ()     ← 崩溃函数（二进制已 strip，无符号）
#7  0x0000007fc3acd600 in ?? ()
Backtrace stopped: previous frame inner to this frame (corrupt stack?)
```

由于官方构建是 stripped 的，通过以下方式反推 `#6` 的身份：

1. 用 `.eh_frame` 的 FDE 表定出 `0x814400` 所属函数范围：**`0x8141e0..0x814bb8`**
2. 反汇编该处，`0x8143fc` 是一条 `bl free@plt`，返回地址即 `0x814400`
3. 提取该函数的字符串引用，得到指纹：

```
"_query_device"                                  ← 疑似函数名
"Cannot query device. Error: %d."
"Cannot open file descriptor for %s. Error: %d."
"/dev/"
"video"
"emit_signal"
```

结合同一函数内的 `ioctl` / `close` / `__errno_location` 调用，判断这是
**输入设备（evdev）扫描**相关的代码路径，且崩溃发生在**打开设备失败**之后的错误处理分支里。

`free()` 的参数来自栈上 `[sp, #240]`，glibc 判定它不是合法的 chunk 起始地址。

---

## Steps to reproduce

我们**只在 Android + glibc 这个非官方组合上验证过**，但推测在标准 Linux 上
只要让 `/dev/input` 不可读就能复现。建议维护者先用容器试（无需 root）：

```bash
# 容器里通常没有 /dev/input
docker run --rm -v "$PWD/proj:/proj" ubuntu:24.04 bash -c '
  apt-get update -qq && apt-get install -y -qq unzip libfontconfig1 >/dev/null
  cd /tmp
  curl -fsSL -o g.zip https://github.com/godotengine/godot/releases/download/4.7.2-stable/Godot_v4.7.2-stable_linux.x86_64.zip
  unzip -q g.zip && chmod +x Godot_v4.7.2-stable_linux.x86_64
  ./Godot_v4.7.2-stable_linux.x86_64 --headless --editor --quit --path /proj
'
```

或者在有 root 的机器上临时收权限：

```bash
sudo chmod 000 /dev/input
godot --headless --editor --quit --path /path/to/project
sudo chmod 755 /dev/input      # 记得改回来
```

**最小复现项目**：空的 Godot 4.7 项目即可（只需 `project.godot` + 一个场景）。
导出还需要 Android 导出模板与 SDK，但 `--editor --quit` 不需要。

---

## 期望行为

`/dev/input` 不可读应当是**可恢复的错误**（打印一条警告、跳过输入设备枚举即可），
而不是让编辑器以堆损坏崩溃。

如果在 Android 上跑官方 Linux 构建确实不在支持范围内，那么至少
**错误处理分支不应破坏堆** —— 这一点与平台无关。

---

## Workaround（我们的规避方式）

让运行身份具备 `/dev/input` 读权限，例如：

- Android：通过 Shizuku 以 `shell` 用户（属于 `input` 组）运行
- Linux：把用户加入 `input` 组，或在容器里提供 `/dev/input`

---

## 提交前自查

- [ ] 是否已在**标准 Linux** 上验证过（哪怕只是容器）？若没有，正文里要明确写"未在桌面 Linux 验证"
- [ ] 标题是否需要更中性的措辞（例如强调"错误路径导致堆损坏"而非 Android）
- [ ] 附上完整的最小复现项目（可以只含 `project.godot`）
- [ ] 若维护者认为 Android+glibc 组合超出支持范围，可主动降级为 discussion
