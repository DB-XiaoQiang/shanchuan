# 原协议上传本机集成验证

在项目根目录运行：

```sh
python3 Tests/ProtocolTransfer/mock_ftp.py
```

脚本只监听 `127.0.0.1` 的随机端口，不读取任何应用配置、钥匙串或真实凭据，不访问原 FTP 服务器。它使用 Python 标准库实现最小 FTP 服务，单独编译 `KeyboardShortcutConfiguration.swift`、`History.swift`、`DirectoryExclusions.swift`、`FTPTransfer.swift` 和 `TransferProtocol.swift`，再通过应用实际使用的 `/usr/bin/curl` 上传三个合成传输计划。快捷键配置源码为 `History.swift` 中的设置模型提供类型定义。需要本机 Swift 编译器、Python 3 和 macOS 自带的 `curl`、`ditto`。

验证内容：

- 文本计划只上传带时间戳的控制文件；中文、emoji、CRLF 和 LF 的 UTF-8 字节完全保留。
- 文件与文件夹计划都上传到精确的 `/share/system_temp`；普通文件实体去掉扩展名，文件夹实体不附加 `.zip`。
- 文件实体先上传，控制文件最后上传；控制内容的文件名、`folder:` 前缀、MD5、CRLF 和时间戳与实际收到的数据逐字节匹配，内容时间戳与控制文件名相同。
- 线上收到的文件夹实体是有效 ZIP；中文路径在 ZIP 中央目录与本地条目头都声明 UTF-8，标准解压后保留中文与空格相对路径、嵌套目录和二进制文件内容，且不多套一层源目录名。

成功时最后输出 `LOOPBACK_PROTOCOL_TRANSFER_PASS`。所有编译产物、合成源文件和协议暂存文件自动清理。

本测试证明本机真实 FTP 传输路径与协议生成能协同工作；它不证明原内网接收端已接收或处理成功。

- 同名不同后缀的 PDF/Markdown 文件使用一个独立文件夹实体发送，ZIP 内保留两个完整文件名和原字节，控制文件含 `folder:` 及 ZIP MD5，并在实体之后上传。
