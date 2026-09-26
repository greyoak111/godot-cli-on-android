# GitHub Actions 自动构建 APK

推代码 → 云端自动构建并签名 → 下载安装。**全程不需要电脑。**

```
git push  ──▶  GitHub Actions (ubuntu-latest)  ──▶  Artifact / Release
                  1. 装 Godot 4.7.2 linux.x86_64
                  2. 取 Android 导出模板（只下需要的）
                  3. 导入项目资源
                  4. 导出 + 签名 APK
                  5. 上传产物
```

---

## 快速开始

### 1. 推代码即构建

推送到 `main`（且改动了 `sample/**` `scripts/**` `tools/**` `ci/**`）会自动触发。

```sh
git push
```

### 2. 打 tag 出 Release（**手机下载最方便**）

```sh
git tag -a v1.0.0 -m "首个版本"
git push origin v1.0.0
```

会创建 Release 并附上 APK。**直链形式**：

```
https://github.com/<用户>/<仓库>/releases/download/v1.0.0/<项目名>-v1.0.0.apk
```

手机上点开就能下载安装 —— 比 Artifacts 方便得多（Artifacts 需要登录）。

### 3. 手动触发

Actions 页面 → `Build APK` → `Run workflow`，可指定项目目录与构建类型。

---

## ⚠️ 最大的坑：ETC2/ASTC 与宿主 OS

**同一个项目，本机（Android）能导出，CI（Linux）却报错**：

```
ERROR: Cannot export project with preset "Android" due to configuration errors:
ETC2/ASTC texture compression is required for Android export.
```

根因在 `editor/import/resource_importer_texture_settings.cpp`：

```cpp
bool ResourceImporterTextureSettings::should_import_etc2_astc() {
    if (GLOBAL_GET("rendering/textures/vram_compression/import_etc2_astc")) {
        return true;
    }
    // 项目没显式开启时，看**宿主 OS** 的首选纹理格式
    return OS::get_singleton()->get_preferred_texture_format()
           == OS::PREFERRED_TEXTURE_FORMAT_ETC2_ASTC;
}
```

| 宿主 | 首选格式 | 校验 |
|---|---|---|
| Android | `ETC2_ASTC` | ✅ 通过 |
| Linux / Windows / macOS | `S3TC_BPTC` | ❌ 失败 |

所以**项目必须显式开启**才能跨宿主构建。在 `project.godot` 里加：

```ini
[rendering]
textures/vram_compression/import_etc2_astc=true
```

本仓库的 `scripts/new.sh` 生成的项目已默认带上；
`ci/build-apk.sh` 里也有一道保险，缺了就自动补。

---

## 配置自己的签名密钥（可选但推荐）

不配置时，CI 每次会**现场生成一个临时密钥库**：
APK 能装能用，但**无法覆盖**由其它密钥签名的旧版本
（`INSTALL_FAILED_UPDATE_INCOMPATIBLE`）。

要统一签名，把本地密钥库加为仓库 Secret：

### 1. 生成 base64

```sh
# 本机（Android）上
base64 -w0 /sdcard/DeepSeekHarness/godot/keystore/debug.keystore
```

### 2. 添加 Secret

👉 `https://github.com/<用户>/<仓库>/settings/secrets/actions`

| Secret 名 | 值 |
|---|---|
| `KEYSTORE_BASE64` | 上一步的 base64 字符串（一整行） |
| `KEYSTORE_PASS` | `android`（可选，默认就是它） |
| `KEYSTORE_ALIAS` | `androiddebugkey`（可选，默认就是它） |

配好后，CI 与本机导出的 APK 就**同签名、可互相覆盖升级**了。

---

## 设计取舍

### 为什么用 tpzfetch 而不是直接下 .tpz

官方导出模板包 `Godot_v4.7.2-stable_export_templates.tpz` 有 **1.22 GB**，
但安卓导出只需要其中两个文件：

```
templates/android_debug.apk     121 MB
templates/android_release.apk   100 MB
```

`tools/tpzfetch.mjs` 做**远程 ZIP 局部下载**——读中央目录、按 range 请求
只取需要的条目，**省掉约 0.9 GB 传输**。

### 为什么不需要本仓库本地那套 hack

本地（Android）环境需要 libc 二进制补丁、shell 身份、`/dev/input` 处理——
那些是「Termux 抽取的运行时 + 安卓沙箱」特有的问题。

CI runner 是标准 x86_64 Linux，用 Godot 官方构建，**这些坑一个都不存在**。
两个环境共用的是同一套 `scripts/` 与导出预设。

### 缓存

`actions/cache` 缓存 `~/godot` 与导出模板目录（约 300 MB）。
首次运行约 2 分钟，命中缓存后**约 40 秒**。

---

## 远程排查技巧

**Actions 日志需要 admin 权限才能通过 API 读取**（匿名用户读不到），
这在移动端排查时很难受。本仓库的做法：

1. `ci/build-apk.sh` 把全程日志写到 `$RUNNER_TEMP/build.log`
   （用直接重定向而**不是** `tee` —— 进程替换在异常退出时会丢缓冲，
   我们踩过这个坑，最关键的失败现场被吞了）
2. 失败时工作流用 `gh api` 把日志尾部发成 **commit comment**

commit comment 是公开可读的，于是可以这样远程看失败原因：

```sh
curl -s https://api.github.com/repos/<用户>/<仓库>/commits/<sha>/comments \
  | jq -r '.[-1].body'
```

失败时脚本还会把日志写进 **Step Summary**。

---

## 本地等价物

CI 里的 `ci/build-apk.sh` 是本机 `scripts/export.sh` 的 Linux 版本，
两者共用 `scripts/preset.template`。想在本地 Linux 上跑同样的流程：

```sh
KEYSTORE_BASE64="$(base64 -w0 /path/to/debug.keystore)" \
  ci/build-apk.sh sample/mygame build/app.apk release
```
