# 闪传

闪传是面向 macOS 和 Windows 的剪贴板历史与 FTP 投递应用。它提供全局自定义复制发送快捷键、显式文件／文件夹投递、传输进度与本地操作日志。普通系统复制不进入闪传记录，也不上传。

## Windows 版

Windows 10/11 版本位于 `windows/`，采用 C#/.NET 8 + WPF。核心协议、目录排除和进度统计与界面分离，并提供单元测试、发布脚本和 GitHub Actions 工作流。构建、使用与数据位置详见 `windows/README.md`。

## macOS 构建

要求 macOS 13 或更新版本、Apple Silicon，以及 Swift 5.9+（Xcode Command Line Tools）。项目不依赖第三方 Swift 包。

```sh
swift build
swift test
python3 Tests/Transfer/mock_ftp.py
python3 Tests/ProtocolTransfer/mock_ftp.py
python3 Tests/FTPConnection/mock_ftp.py
./scripts/package.sh
```

打包结果位于 `dist/闪传.app` 和 `dist/闪传-macos-arm64.zip`。打包需要稳定的 Apple Development 签名身份，以保留 macOS 辅助功能和钥匙串授权。身份无法唯一确定时，可通过 `COPYTOOL_SIGNING_IDENTITY` 指定证书 SHA-1；脚本在签名失败时停止，不回退到 ad hoc 签名。

## 功能

- 默认 Control+Option+C 将当前应用选中文本复制并发送；Control+Option+V 将系统剪贴板粘贴到当前应用。快捷键可以自定义。Command+C 保持系统普通复制行为。
- 普通剪贴板变化不会被后台监听、记录或上传。文件选择、拖放、手动重发和自定义复制发送都是明确操作。
- FTP 配置自动保存到本机应用数据，密码保存在 macOS 钥匙串。
- FTP 地址旁的“测试连接”使用当前表单值，验证账号登录和目标目录访问。它不会上传、创建或删除文件；测试成功不代表服务器允许写入，也不代表接收端已处理文件。
- 上传按队列顺序执行，可取消；屏幕右上角进度卡片显示阶段、百分比与字节数。主窗口关闭后传输仍继续。
- 剪贴板历史与结构化传输日志保存在本机，支持搜索、筛选和隐私模式。应用不将日志或剪贴板历史上传到 GitHub。
- 通过菜单栏和设置页面管理前台复制／粘贴入口、传输提示与登录启动。

## FTP 传输协议

独立实现按照目标应用的可观察行为兼容 FTP 投递格式：文本使用 UTF-8；文件与目录发布控制清单；目录先打包为 ZIP。特殊 Office 路由标记只决定投递目录，不执行解密。

自动化 FTP 验证均使用仅绑定 `127.0.0.1` 的临时模拟服务器与合成数据。真实服务器的连接、权限与接收结果取决于用户当前网络和服务器配置。

## 本机数据与隐私

偏好设置、历史、图片缓存及传输日志保存在用户的 `~/Library/Application Support/CopyToolIndependent/` 中。密码由 macOS 钥匙串管理，不写入偏好设置 JSON 或进程参数。剪贴板历史可能包含用户主动发送的内容；隐私模式只控制界面显示。

`evidence/` 保存本机调查记录与 GUI 验收资料，`dist/` 和 `.build/` 保存本机构建产物；这些目录由 `.gitignore` 排除，不属于本仓库提交内容。
