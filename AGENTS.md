# 闪传

- 使用中文文档和界面；SwiftPM 构建，SwiftUI 界面。
- 原应用 `/Applications/copy-tool.app` 只读，不修改、不导入其历史、账号或授权文件。
- `evidence/` 仅保存本地调查资料，不发布原程序资源或二进制。
- 真实 FTP 服务器连接、数据上传需由用户明确指定；自动化测试只用回环测试服务器与合成数据。
- GUI 通过 macOS LaunchServices/桌面控制启动；不得直接运行 `.app/Contents/MacOS/`。
- 独立实现不复用原品牌图标，不绕过原应用授权。
- `swift build` 与 `swift test` 验证；完成后用 `scripts/package.sh` 打包。
