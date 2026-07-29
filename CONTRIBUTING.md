# 贡献指南

## 开始前

- 使用 macOS 14 或更高版本、Xcode Command Line Tools 和 Node.js 25 或更高版本。
- 不提交 API Key、真实录音、SQLite 数据库、模型文件或构建产物。
- 变更用户可见文案时，同时更新 README 或相关文档。

## 提交前检查

```sh
swift test
sh scripts/check_macos.sh
```

涉及 `Tools/tinglan_agentd` 或 `Tools/tinglan_mcp` 时，还应分别执行目录中的 `npm test`。

## Pull Request

- 一个 PR 聚焦一个问题。
- 说明行为变化、验证方式和已知限制。
- 涉及权限、录音、文件访问或模型请求的改动，请说明数据流和回退行为。
