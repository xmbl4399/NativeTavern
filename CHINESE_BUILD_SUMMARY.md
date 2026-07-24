# NativeTavern — 汉化与构建记录

> 基于 [miaoxworld/NativeTavern](https://github.com/miaoxworld/NativeTavern) 的 Flutter 项目，
> 完成工具链搭建、UI 汉化、APK 构建的全流程。

---

## 工作内容

### 1. 开发环境搭建

| 组件 | 版本 | 说明 |
|:---|:---:|:---|
| JDK | 17 (Amazon Corretto) | `C:\Program Files\Amazon Corretto\jdk17.0.20_8` |
| Flutter SDK | 3.44.7 (stable) | `C:\Users\ASUS\flutter` |
| Android SDK | 36 | `C:\Users\ASUS\Android\Sdk` |
| Android NDK | 26.1.10909125 | 已安装 |
| Rust targets | aarch64/armv7/x86_64-android | 已安装 |

### 2. 构建过程修复

| 问题 | 修复 |
|:---|:---|
| `flutter_inappwebview_android` 使用已废弃的 `proguard-android.txt` | 替换为 `proguard-android-optimize.txt` |
| `flutter_plugin_android_lifecycle` 要求 compileSdk ≥ 36 | 强制 compileSdk = 36 |
| Kotlin 增量缓存损坏 | 禁用 Gradle daemon，`kotlin.incremental=false` |
| CupertinoIcons 字体未打包 | 添加 `cupertino_icons: ^1.0.8` 依赖 |

### 3. UI 汉化（~170 处字符串）

#### 提示词管理器（核心）
- 默认系统提示词、Post-History 提示、NSFW 提示词 → 中文
- 28 个段落类型名称和描述 → 中文
- 8 个内置预设（默认/角色聚焦/世界信息优先/极简模式）→ 中文

#### 设置页面（16 个文件）
- sprite_settings / prompt_manager_screen / image_gen_settings
- statistics / regex / tokenizer / theme / vector_storage
- variables / tts / stt / translation / quick_reply
- settings / persona_editor / world_info_entry_editor

#### 本地化
- `app_zh.arb` — 补全 2 条遗漏翻译；其余未译条目为品牌名/占位符，保持英文

### 4. 构建产出

| 文件 | 大小 | 路径 |
|:---|:---:|:---|
| app-release.apk | 92 MB | `Z:\app-release.apk` |

> APK 使用 debug signing key 签名，发布前需替换为正式签名。

### 5. 已知限制

- 环境变量 `JAVA_HOME`、`ANDROID_HOME` 需重启终端生效
- 路由器代理可能影响大文件下载
- l10n 仍有 ~800 条未翻译条目（显示英文 fallback，不影响运行）
- Rust 原生核心 (`rust/`) 未编译（需 MSVC Build Tools + cargo-ndk）
