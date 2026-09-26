# Cline 桌面端中文汉化补丁 (cline-desktop-zh)

基于 WebView2 远程调试协议 (CDP) 的 **运行时 DOM 动态注入汉化方案**。

专为 Cline 桌面客户端（Tauri + WebView2 架构）打造，具备 **零侵入二进制、防官方更新失效、无黑框后台静默运行、随软件退出自动回收** 等核心特性。

> **本项目是 [JACK5920/cline-desktop-zh](https://github.com/JACK5920/cline-desktop-zh) 的延续分支（Fork）**：在其 418 条词典的基础上继续扩充与维护，当前规模为 **文本 1062 条 + 属性 94 条 + 文本模式 62 条 + 属性模式 94 条**（共 1300+ 条匹配规则）。
> 上游以 MIT 许可发布，本分支同样以 MIT 许可发布并保留上游版权声明。来源与署名详见 [NOTICE](NOTICE) 与 [THIRD-PARTY-LICENSES.md](THIRD-PARTY-LICENSES.md)。

---

## 🌟 核心特性

- **🛡️ 零侵入与防更新失效**：不修改任何官方 `.exe`、动态链接库或核心文件。官方客户端自动覆盖更新后，汉化依然稳定生效。
- **🤫 零黑框后台静默运行**：VBS 启动器静默守护进程，彻底消除终端黑框。
- **🌐 双栈网络与端口自适应**：自动探测 `127.0.0.1` (IPv4) 与 `[::1]` (IPv6)，在候选端口（19333 / 19334 / 19527 / 9333）中自动选择并锁定可用端口，杜绝端口占用与连接失败。
- **🔄 生命周期自动化感知**：注入器随 Cline 启动挂载；Cline 退出后注入进程在约 15 秒内自动安全终止，同时清理孤儿 `code-sidecar.exe` 进程，零资源残留。
- **⚡ 词典热重载**：注入器每 3 秒自动重载 `dictionary.json`，修改词条后**无需重启 Cline**，界面刷新即生效。
- **🧩 深度组件级汉化（1000+ 词条）**：
  - **会话与聊天界面**：输入框占位符、操作按钮、提示标签、Token / 缓存 / 费用统计、各类确认与删除弹窗。
  - **定时任务 (Routine / Schedule)**：任务列表、执行频率（每天/每周/单次）、预设模板与表单。
  - **自定义与扩展 (Customize / Extensions)**：工具 (Tools)、插件 (Plugins)、技能 (Skills)、规则 (Rules)、MCP、钩子 (Hooks) 选项卡；内置工具（`ask_question`、`editor`、`read_files`、`run_commands`、`search_codebase`、`skills`、`tasks`、`spawn_agent` 等）行为说明；开关、搜索框与批量控制。
  - **模型提供商 (Providers)**：添加提供商表单、API Key 管理、模型能力标签（流式传输、工具调用、深度思考/推理、视觉识别、提示词缓存）、高级网络设置、模型列表状态与动态计数。
  - **语音输入 (Voice)**：麦克风权限、听写设置、实时/非实时转录模型选择。
  - **常规与系统设置**：通知（系统横幅/音效）、外观（主题/字体大小/强调色/应用图标）、运行环境、CLI 自动更新开关、新手引导重播。
  - **导入会话 (Import Sessions)**：VS Code / Cursor / Cline CLI 的会话导入流程。
- **⚡ React/JSX 空白字符折叠归一化**：内置换行符与制表符归一化匹配引擎，杜绝多行长文本匹配失效。

---

## 📂 目录结构

```text
cline-zh/
├── dictionary.json                 # 汉化词典 (texts / attrs / wholeElements / textPatterns / attrPatterns)
├── inject.js                       # 基于 WebView2 CDP 的核心注入器 (Node.js)
├── launch-silent.vbs               # 静默启动器 (无黑框、防多开、自动拉起、孤儿进程清理)
├── 启动 Cline 中文版.cmd            # 调试运行脚本 (显示控制台输出，便于排查)
├── 停止后台汉化.cmd                 # 一键结束后台注入器进程
├── LICENSE                         # MIT 许可证 (含上游版权声明)
├── NOTICE                          # 来源、许可与合规声明
├── THIRD-PARTY-LICENSES.md         # 上游项目 MIT 许可全文
└── .gitignore
```

---

## 🚀 快速上手

### 前置条件

- Windows 10 / 11
- 已安装 [Cline 桌面客户端](https://cline.bot/)
- 已安装 [Node.js](https://nodejs.org/) 22 LTS 或更高版本（注入器使用 Node 内置 WebSocket 客户端；本项目在 Node 24 上验证通过）

### 安装与部署

1. 将本仓库（`cline-zh` 文件夹）放置在 Cline 安装目录下（与 `cline-app.exe` 同级），例如：
   - `C:\Program Files\Cline\cline-zh`
   - `E:\Program Files\Cline\cline-zh`
   - 或其他自定义安装路径下的 `cline-zh` 子目录
2. 在桌面创建快捷方式：
   - **目标 (Target)**：`wscript.exe "C:\Program Files\Cline\cline-zh\launch-silent.vbs"`
   - **起始位置 (Start in)**：`"C:\Program Files\Cline\cline-zh"`
   - **图标 (Icon)**：`C:\Program Files\Cline\cline-app.exe`
3. 以后双击该快捷方式，即可享受纯净无黑框的中文版 Cline。

> 启动器会自动推导 `cline-zh` 及其上级目录中的 `cline-app.exe` 位置，无需手工修改脚本。

### 调试运行

需要查看注入日志时，直接运行 `启动 Cline 中文版.cmd`（保留控制台输出）。要恢复英文原版，运行 `停止后台汉化.cmd` 或直接启动官方 `cline-app.exe`。

---

## 🧩 可选：无 AVX2 老 CPU 的 sidecar 兼容

若你的 CPU 不支持 AVX2（如 Pentium Gold、部分 Nehalem / Westmere / Whiskey Lake 型号），官方 `code-sidecar.exe` 可能启动即崩溃。此时可将自行重编译的 `code-sidecar.exe` 放入 `cline-zh\bin\` 目录：启动器检测到该文件后，会自动通过 `CLINE_CODE_SIDECAR_BIN` 环境变量固定使用该副本（不修改安装目录、官方更新后依然生效）。

重编译步骤与此场景的一键重打脚本见姊妹项目：[cline-sidecar-preavx2-fix](https://github.com/cingedf/cline-sidecar-preavx2-fix)。

---

## ❓ 常见问题 (FAQ)

### Q: Cline 客户端更新后汉化会失效吗？

**不会失效**。本补丁采用独立的外部挂载与运行时注入设计，官方安装包更新时仅覆盖自身程序文件，不会影响 `cline-zh` 目录与桌面快捷方式。

### Q: 想补充 / 修改词条怎么办？

直接编辑 `dictionary.json`：`texts` 为"英文原文 → 中文"，`attrs` 为属性文案，`textPatterns` / `attrPatterns` 为 `[正则, 替换]` 模式。保存后无需重启，注入器会在 3 秒内自动加载新词典。

### Q: 端口冲突 / 注入没有反应？

注入器会在 19333、19334、19527、9333 中自动探测可用端口，也可通过环境变量 `CDP_PORT` 指定。若仍无反应，请用 `启动 Cline 中文版.cmd` 启动以查看报错输出。

### Q: 如何完全恢复原版英文界面？

运行 `停止后台汉化.cmd` 结束注入器，然后直接启动官方 `cline-app.exe` 即可。

---

## 📄 开源许可与合规

- 本项目基于 [MIT License](LICENSE) 开源，并**保留上游 [JACK5920/cline-desktop-zh](https://github.com/JACK5920/cline-desktop-zh) 的完整版权声明**。
- 词典中的英文键为查找用的界面原文引用（来源：应用运行时界面，以及 Apache-2.0 许可的 [cline/cline](https://github.com/cline/cline) 开源仓库文案）；中文值为本项目或已署名社区项目的原创译文。
- 本项目**不包含**任何官方或第三方二进制程序、图标资源，也不包含 Cline 官方插件市场 (Marketplace) 的目录文案。
- 来源、署名与移除请求渠道详见 [NOTICE](NOTICE) 与 [THIRD-PARTY-LICENSES.md](THIRD-PARTY-LICENSES.md)。
- 本项目为非官方社区项目，与 Cline 官方无任何隶属或背书关系。