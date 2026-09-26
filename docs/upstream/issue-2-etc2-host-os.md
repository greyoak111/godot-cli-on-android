# [Draft] ETC2/ASTC 校验依赖**宿主 OS**，但提示信息没说明这一点

> 状态：草稿，待提交到 https://github.com/godotengine/godot/issues/new
> 关联：https://github.com/godotengine/godot/issues/123504（已关闭）

---

**Godot version:** 4.7.2.stable.official

**System information:** 见下方"为什么这个现象值得注意"

---

## 背景

[#123504](https://github.com/godotengine/godot/issues/123504) 修好了一个很痛的问题：
ETC2/ASTC 未开启时导出失败，但**错误信息是空白的**，headless CI 用户完全无从排查。
修复后（`EditorExportPlatformAndroid::has_valid_project_configuration`）会输出：

```
ERROR: Cannot export project with preset "Android" due to configuration errors:
ETC2/ASTC texture compression is required for Android export. In the Project Settings,
search for 'ETC2' in the search field, or enable 'Advanced Settings', and go to
Rendering > Textures > VRAM Compression to enable 'Import ETC2 ASTC'.
```

这个提示帮我们迅速定位了问题，**先为此道谢**。

不过我们在排查时发现，这个校验还有一个**未被提示信息覆盖、也没有文档**的行为，
它会造成"同一个项目、同一个 Godot 版本，换个宿主就一个能导一个不能"的困惑。

---

## 问题：校验结果取决于**宿主操作系统**

`editor/import/resource_importer_texture_settings.cpp`：

```cpp
bool ResourceImporterTextureSettings::should_import_etc2_astc() {
    if (GLOBAL_GET("rendering/textures/vram_compression/import_etc2_astc")) {
        return true;
    }
    // If the project settings override is not enabled, import
    // ETC2/ASTC only when the host operating system needs it.
    return OS::get_singleton()->get_preferred_texture_format()
           == OS::PREFERRED_TEXTURE_FORMAT_ETC2_ASTC;
}
```

也就是说，当项目**没有显式开启**该设置时，是否通过校验取决于**构建机（宿主）**：

| 宿主 | `get_preferred_texture_format()` | 导出安卓 |
|---|---|---|
| Android | `ETC2_ASTC` | ✅ 通过 |
| Linux / Windows / macOS | `S3TC_BPTC` | ❌ 失败 |

### 我们实际踩到的场景

在 Android 设备上（Godot 官方 **Linux arm64** 构建 + glibc 运行时）能正常导出安卓 APK；
把**完全相同的项目**推到 GitHub Actions（ubuntu-latest）后立刻失败。

一开始我们以为是 CI 环境差异，排查了一圈才发现根因是上面那个宿主判断——
**项目本地的成功反而掩盖了它缺少必要设置这件事**。

---

## 建议

三选一即可，都是小改动：

### 1. 提示信息里点明宿主依赖（最小改动）

当 `valid = false` 是因为这条时，补一句类似：

> ...enable 'Import ETC2 ASTC'.
> **Note:** this check depends on the host platform: when the project setting is
> not explicitly enabled, exporting succeeds only when the host OS itself prefers
> ETC2/ASTC (e.g. running the editor on Android), which is why a project may
> export locally but fail in CI.

### 2. 文档补充

在《Exporting for Android》文档里加一句：**项目应显式设置
`rendering/textures/vram_compression/import_etc2_astc=true`，不要依赖宿主默认值。**

### 3. 重新考虑默认值（更大，可能不适合现在做）

既然目标是**导出到 Android**，而 Android GPU 普遍需要 ETC2/ASTC，
那么校验是否应该看**目标平台**而不是宿主平台？不过这会改变现有项目的行为，
可能更适合作为 proposal 讨论而不是直接改。

就我们而言，**方案 1 或 2 就足够解决困惑**了。

---

## 附：我们的规避方式

在 `project.godot` 里显式开启，这样项目在任何宿主上行为一致：

```ini
[rendering]
textures/vram_compression/import_etc2_astc=true
```

## 提交前自查

- [ ] 是否应作为 **proposal**（godotengine/godot-proposals）而非 issue 提交？建议 3 涉及行为变更，但 1/2 是纯提示与文档
- [ ] 是否需要附上"同项目在不同宿主上行为不同"的最小示例仓库（我们这边有现成的）
