# AgendAI 会小纪

> 纯原生 macOS 会议听记工具：录制麦克风和电脑音频，实时转写，并生成可编辑、可导出的会议纪要。

AgendAI 会小纪优先将会议数据保留在本机，支持线上与线下会议录音、实时转写、正式会议纪要、独立 AI 分析、会议内问答，以及 Markdown/HTML 导出。

> 当前处于早期开发阶段，建议先在测试会议中使用。

## 功能

- 采集麦克风、屏幕或应用音频，支持混合录音。
- 实时转写与会后正式会议纪要生成。
- 会议笔记、图片笔记、常用词库和参会人员管理。
- 独立 AI 分析与结构化待办，不改变原始会议纪要。
- Markdown、HTML 导出，以及会议内 Agent 问答。
- 本地 SQLite 持久化；模型服务地址、协议和模型可配置。

## 快速开始

环境要求：macOS 14 或更高版本、Xcode Command Line Tools、Node.js 25 或更高版本。首次录制时需在系统设置中授权麦克风和屏幕录制。

```sh
git clone https://github.com/leoyoul/AgendAI.git
cd AgendAI
sh scripts/check_macos.sh
sh scripts/install_macos_app.sh
open '/Applications/AgendAI 会小纪.app'
```

应用使用你在“模型配置”中填写的兼容 OpenAI API 的 ASR 与文本模型服务。

## 开发与测试

```sh
swift test
sh scripts/check_macos.sh
```

完整检查会运行 Swift 测试、Agent/MCP 测试、公开文档检查，并生成已签名的通用 macOS 安装包。

## 隐私与安全

- 会议数据默认只保存在本机。接入第三方模型服务时，转写和图片会按你的配置发送给该服务。
- 请勿提交 API Key、真实录音、转写、SQLite 数据库、模型文件或本机配置。
- `.gitignore` 已排除个人 Codex 配置、Skills、数据库、构建产物、模型环境、依赖和生成预览。
- 漏洞报告请参阅 [SECURITY.md](SECURITY.md)。

## 参与贡献

欢迎提交 Issue 和 Pull Request。开发约定见 [CONTRIBUTING.md](CONTRIBUTING.md)。

## 许可证

本项目采用 [MIT License](LICENSE)。
