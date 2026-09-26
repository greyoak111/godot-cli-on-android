# 在 Android 平板上跑无头 Godot —— 完整自举方案

> 让 **Godot 4.7.2 在没有 PC、没有 Termux、没有 root 的安卓设备上**完成
> 项目导入 → APK 导出 → 签名 → 装机 → 运行 的全流程。
>
> **运行环境**：本项目是在 **[DeepSeek Harness 手机版](https://github.com/woaiys3/deepseek-harness-android-app)**
> 里跑起来的 —— 它提供了 Shizuku 特权通道（`shell` 身份运行正是绕开 `/dev/input` 崩溃的关键）
> 与文件访问权限。配套工具集见
> **[deepseek-harness-android-tools](https://github.com/greyoak111/deepseek-harness-android-tools)**。

## 这是什么

Godot 官方只提供桌面端的无头 CLI。这个项目把它搬到了 Android 上，并解决了
一路上的三个硬障碍：

| 障碍 | 现象 | 解法 |
|---|---|---|
| **Godot 上游 bug** | 编辑器/导出必崩 `free(): invalid size` | 以 `shell` 身份运行（拿到 `/dev/input` 读权限），绕开有缺陷的错误路径 |
| **glibc 硬编码 Termux 路径** | `popen()` 全废 → 密钥库校验失败 | 二进制原地替换 `libc.so.6` 中 7 处路径字符串 |
| **Java 无 `/tmp`** | apksigner 建不了临时文件 | 包装器指定 `-Djava.io.tmpdir` |

完整定位过程（gdb 抓栈 → `.eh_frame` 定函数 → 反汇编 → 字符串指纹）
见下文《关键技术说明》。

## 适用场景

- 只有平板/手机，想写 Godot 游戏并出 APK
- 想在 Android 设备上做 CI（导出 + 签名）
- 想研究 Godot Linux 构建在非标准环境下的行为

## 前置条件

- Android 11+，arm64 设备，约 1.5GB 空闲存储
- [Shizuku](https://shizuku.rikka.app/)（提供 `shell` 身份，用于导出）
- 一个能访问 GitHub / 下载 Godot 官方构建的网络

## 实测环境

**Lenovo TB320FC**（Android 15 / 骁龙 8+ Gen 1 / 14.9GB RAM）
下文所有数据与结论均来自该设备的实测。

---

## 安装（从零开始）

前置：Android 11+ arm64、[Shizuku](https://shizuku.rikka.app/)、
一个能跑 `node` 的身份、网络、约 3GB 空闲空间。

```sh
git clone <本仓库> && cd godot-cli-on-android

# 1) 应用侧暂存 —— 下载 Godot、用 tpkg 抽取 glibc/JDK、给 libc 打补丁、拉模板
sh scripts/stage.sh

# 2) shell 侧部署 —— 必须以 shell 身份（Shizuku），导出依赖 /dev/input 读权限
sh scripts/setup.sh

# 3) 体检
sh scripts/doctor.sh
```

> `stage.sh` 需要 node（用于 tpkg / patchlibc / tpzfetch，全部内置在本仓库，
> **不需要 npm install**）。若你的应用身份跑不了 node，可在 Termux 里执行第 1 步。
> 第 2 步必须在 shell 身份下。

装好之后：

```sh
S=scripts   # 或 /sdcard/DeepSeekHarness/godot/scripts

sh $S/new.sh mygame com.dsh.mygame   # 1. 建项目
sh $S/export.sh mygame               # 2. 导出（自动提权到 shell）
sh $S/run.sh mygame                  # 3. 装机 + 运行 + 截图

sh $S/doctor.sh                      # 环境体检（22 项）
```

另外提供了一个 **`godot` 命令**（任意身份调用，自动提权到 shell）：

```sh
godot --headless --path <工程目录>              # 无头运行项目
godot --headless --path <工程目录> --quit-after 300
godot --headless --version                      # 版本
```

> 应用身份**不能直接执行** `/data/local/tmp` 里的文件（SELinux 把那里标为
> `shell_data_file`），所以 `godot` 命令内部走 `priv` 提权，实体脚本在
> `/data/local/tmp/dshgodot/cli.sh`。

产出：
- APK → `/sdcard/DeepSeekHarness/godot/out/<项目名>.apk`
- 截图 → `/sdcard/DeepSeekHarness/godot/out/<项目名>-screenshot.png`
- 工程 → `/sdcard/DeepSeekHarness/godot/projects/<项目名>/`

> `export.sh` / `run.sh` 需要 **shell 身份**（Shizuku）。
> 以普通应用身份调用时脚本会**自动提权**；Shizuku 没开则报错。

---

## 目录布局（三层设计）

### 持久层 `/sdcard/DeepSeekHarness/godot/`（可见、可备份、可清理）

```
templates/4.7.2.stable/     导出模板（222MB，android_debug/release.apk）
keystore/debug.keystore     签名密钥库（alias: androiddebugkey / 密码: android）
platform/android.jar        Android 平台 jar（25MB）
projects/<名字>/            你的 Godot 工程
out/                        导出的 APK 与截图
scripts/                    管理脚本
_stage/                     重建用暂存区（794MB，可删）
```

### 执行层 `/data/local/tmp/dshgodot/`（shell 可执行、快）

```
godot                                   Godot 4.7.2 linux.arm64（官方构建）
glibclib/                               glibc 运行时（libc.so.6 已打补丁）
lib/                                    依赖库（fontconfig 等 + SONAME 链接）
jvm/                                    OpenJDK 17（apksigner 用）
sdk/build-tools/36.1.0/apksigner        包装器（已设 tmpdir）
sdk/platform-tools/adb                  桩文件（Godot 只做存在性校验）
fakebin/sh                              popen 用的 shell（见下文补丁）
home/                                   Godot 的 HOME（配置/缓存）
```

**数据部分用符号链接打通**（`/data/local/tmp` 是 ext4，支持链接）：

| 链接 | 指向 |
|---|---|
| `home/.local/share/godot/export_templates` | `持久层/templates` |
| `home/.android` | `持久层/keystore` |
| `projects` | `持久层/projects` |
| `out` | `持久层/out` |
| `sdk/platforms/android-36/android.jar` | `持久层/platform/android.jar` |

好处：**大文件（模板 222MB）和你的工程都在用户存储里**，看得见、能备份、
清掉 `/data/local/tmp` 也不丢。

---

## 恢复流程（`/data/local/tmp` 被清空后）

```sh
# 1) 应用侧暂存（因为源码在应用私有目录，shell 读不到）
sh /sdcard/DeepSeekHarness/godot/scripts/stage.sh

# 2) shell 侧部署
sh /sdcard/DeepSeekHarness/godot/scripts/setup.sh

# 3) 体检
sh /sdcard/DeepSeekHarness/godot/scripts/doctor.sh
```

`stage.sh` 是**自足**的：它自己下载 Godot、用仓库内置的 `tools/tpkg.mjs`
从 Termux 仓库抽取 glibc / JDK / 依赖库，**并自动给 libc 重新打补丁**（见下）。
不依赖任何预装环境，只需要 node。

若只想重建执行层而不想重新下载（暂存区还在），直接跑第 2 步即可。

---

## 关键技术说明

### 1. 为什么必须用 shell 身份

Godot 的 Linux 构建会扫描 `/dev/input` 找输入设备。安卓上
`untrusted_app` 读不了它（`shell` 属于 `input` 组，gid 1004，可以）。

读取失败会走进 Godot 的一条**有堆损坏 bug 的错误路径**，表现为：

```
Regenerating editor help cache
Class 'AnchorPresetPicker' is not exposed, skipping.
free(): invalid size          ← glibc 检出堆损坏 → SIGABRT
```

游戏模式不崩、**编辑器/导出必崩**，且 **4.5.1 与 4.7.2 一样崩**（非版本回归）。

定位过程：

1. `strace` 看到主线程 285 次 `brk` 扩堆 444MB，随后某工作线程报堆损坏
2. 装 **gdb 18.1**（Termux 抽取）——旧版 gdb 读不了 glibc 2.44 的
   `.relr.dyn` 与 DWARF 5，且自身依赖 Guile，需要设
   `GUILE_LOAD_PATH` + `set startup-with-shell off`（因为 gdb 也硬编码了
   Termux 的 shell 路径）
3. 拿到真实调用栈，`#6` 落在 Godot 二进制 `0x814400`（stripped，无符号）
4. 用 `.eh_frame` 的 FDE 表定出所属函数 `0x8141e0..0x814bb8`
5. 反汇编认出 `0x8143fc: bl free@plt`
6. 提取函数的字符串引用得到指纹：
   `_query_device` / `Cannot open file descriptor for %s. Error: %d.` /
   `/dev/` / `ioctl` / `close` → **输入设备扫描线程**确认

### 2. libc 二进制补丁（**必须保留**）

Termux 的 glibc 把 shell 路径**硬编码**成了它自己的前缀：

```
/data/data/com.termux/files/usr/glibc/bin/sh
```

我们把包装到别处后这个路径不存在 → **`popen()` 全废** →
Godot 的密钥库校验（调 `keytool`）失败 → 导出中止。

修法：在 `libc.so.6` 里**原地替换**这些字符串（新路径更短，NUL 补齐，
不破坏任何偏移）：

| 原路径（长度） | 替换为（长度） |
|---|---|
| `.../glibc/bin/sh` (44) | `/data/local/tmp/dshgodot/fakebin/sh` (35) |
| `.../glibc/bin/csh` (45) | 同上 (35) |
| `.../usr/tmp/sem.XXXXXX` (46) | `/data/local/tmp/dshgodot/tmp/sem.XXXXXX` (39) |
| `.../usr/tmp` (35) | `/data/local/tmp/dshgodot/tmp` (28) |

共 7 处。工具：`tools/patchlibc.mjs`（`stage.sh` 会自动调用）。

> ⚠️ 如果改了执行层路径，**必须同步改 `patchlibc.mjs` 里的替换目标并重新打补丁**，
> 否则 popen 会指向不存在的路径。

### 3. 其它

- **`-Djava.io.tmpdir`**：安卓没有 `/tmp`，Java 建临时文件会失败，
  apksigner 包装器里已指定到执行层 `tmp/`。
- **`adb` 桩**：Godot 只对 adb 做存在性校验；装机实际走 `pm install`。
- **`/sdcard` 不支持符号链接**，所以暂存/中转发 `cp -RL`（解引用），
  SONAME 链接由 `setup.sh` 在目标位置重建。
- Godot 用 `use_gradle_build=false`（预编译 APK 模板路线），**不需要 Gradle**。

---

## 环境参数

| 项目 | 值 |
|---|---|
| Godot | 4.7.2-stable official（`linux.arm64`，官方构建） |
| glibc | 2.44（Termux glibc 仓库，经二进制补丁） |
| JDK | OpenJDK 17.0.20 |
| apksigner | 0.9（v2 + v3 签名方案） |
| 导出模板 | Android arm64-v8a |
| 执行层体积 | 789 MB |
| 持久层体积 | ~1.0 GB（含 794MB 暂存区，可删） |

**已验证**：导出 → v2/v3 签名校验通过 → `pm install` → 启动 → GLES 渲染 → 截图。

---

## 工具

| 工具 | 用途 |
|---|---|
| `tools/patchlibc.mjs` | 给 glibc 打路径补丁（原地替换，NUL 补齐） |
| `tools/elfneed.mjs` | 读 ELF 的 `DT_NEEDED` / `PT_INTERP`，无需 readelf |
| `tools/tpzfetch.mjs` | **远程 ZIP 局部下载**——只取压缩包里需要的条目<br>（用它从 1.2GB 的 Godot 导出模板包里只下了 426MB，省掉 0.78GB 传输） |

---

## 上游文档（草稿）

`docs/upstream/` 下是两份准备提交给 Godot 上游的报告草稿，
记录了本次排查中发现的、可能与平台无关的问题：

| 草稿 | 内容 |
|---|---|
| [issue-1-input-scan-crash.md](docs/upstream/issue-1-input-scan-crash.md) | `/dev/input` 不可读时编辑器以堆损坏崩溃（含 gdb 调用栈、函数定位过程） |
| [issue-2-etc2-host-os.md](docs/upstream/issue-2-etc2-host-os.md) | ETC2/ASTC 校验依赖**宿主 OS**，但提示信息未说明 |

> 关联：上游 [issue #123504](https://github.com/godotengine/godot/issues/123504) 修复了
> "配置错误信息空白"的问题 —— 我们正是靠着这个修复才能在三天内定位到 ETC2 那个坑。

## 已知边界

- 导出**必须走 shell 身份**；普通应用身份跑编辑器会触发上述 Godot 上游 bug。
  （根因在 Godot 的错误处理路径，非本环境问题）
- **Shizuku 重启后失效**，需要手动重新启动。
- 未处理：3D 项目的资产管线（光照烘焙等）在移动端会比较吃力。

## 鸣谢

**运行环境（地基）**

- **[woaiys3/deepseek-harness-android-app](https://github.com/woaiys3/deepseek-harness-android-app)**
  —— DeepSeek Harness 手机版。本项目全程在它里面完成。
  本方案里**最关键的"以 shell 身份运行"**，靠的正是它的 Shizuku 特权通道 ——
  没有那条通道，Godot 编辑器会在 `/dev/input` 的错误路径上必崩。

**上游**

- **[Godot Engine](https://godotengine.org/)** —— 引擎本体。官方只发桌面端无头 CLI，本项目把它搬到了 Android。
- **[Termux](https://termux.dev/)** —— 提供安卓上可用的 glibc 运行时与工具链。
- **[Shizuku](https://shizuku.rikka.app/)** —— 免 root 拿到 `shell`(uid=2000) 权限。

**配套**

- **[deepseek-harness-android-tools](https://github.com/greyoak111/deepseek-harness-android-tools)**
  —— 本仓库用到的 `tpkg.mjs` / `patchlibc.mjs` / `elfneed.mjs` 的正式归宿。
- **[blender-cli-android](https://github.com/greyoak111/blender-cli-android)**
  —— 姊妹项目：Blender 无头 CLI + GPU 加速渲染。
  两者合起来是完整的移动端管线：`Blender → glTF → Godot → APK → 装回本机`。

## License

MIT
