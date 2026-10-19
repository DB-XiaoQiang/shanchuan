# FTP 传输本机集成验证

在项目根目录运行：

```sh
python3 Tests/Transfer/mock_ftp.py
```

脚本仅监听 `127.0.0.1` 随机端口，使用 Python 标准库实现最小 FTP 测试服务，编译独立 Swift 测试程序，再通过真实 `/usr/bin/curl` 上传。无需外部服务、第三方 Python 包、真实凭据或固定端口。

覆盖：含引号和反斜杠密码通过 stdin curl config 传入；中文、空格、分号文件名原样保留；UTF-8 文本字节一致；ditto 文件夹 zip 可解压且内容一致；16 MB 上传取消返回 cancelled；凭据控制字符在连接前拒绝。

另将 16 MB 合成文件上传为 `progress.bin`，回环服务每接收 64 KB 等待 20 ms，让真实 `curl` 持续产生进度。Swift 测试用锁保护回调采样，要求至少两个不同的 `0 < value < 1` 中间值、全部数值有效且单调，并逐字节核对收到的完整内容。随后上传 25 字节控制文件，用 `TransferByteProgress` 验证大载荷和小控制文件按照字节加权；载荷完成时接近 100%，控制文件完成后才到 100%。脚本只对 `progress.bin` 限速，保留独立的取消场景，Swift 程序总超时仍为 30 秒。

成功时输出 `REAL_CURL_INTERMEDIATE_PROGRESS_PASS`（含采样数）、`PAYLOAD_CONTROL_BYTE_WEIGHT_PASS`、`CANCELLATION_PASS`、`CONTROL_CHARACTER_REJECTION_PASS`、`UPLOAD_AND_ZIP_PASS`、`LOOPBACK_FTP_CONTENT_AND_ARCHIVE_PASS`。

准备流程的取消与复用另由纯本机单元测试覆盖：运行 `swift test --filter PreparationCancellationTests`，确认提前 `cancel()` 后文本与文件夹计划均抛出 `cancelled`；同一实例 `resetCancellation()` 后可重新生成文本控制文件、文件夹 ZIP 和 MD5 清单。该组测试只使用合成临时文件，不建立 FTP 连接。

接口：`FTPSettings(host:port:username:password:directory:)`；`FTPTransfer.upload(file:remoteName:settings:progress:)`、`upload(text:remoteName:settings:progress:)`；`cancel()`；`FTPTransfer.archiveDirectory(_:destination:)`。调用方在后台串行队列使用同步上传，负责排队及清理 zip 目的文件。可取消 zip 时使用实例 `zip(directory:destination:)`。

普通 FTP 为原应用的协议兼容实现。该测试不证明任何真实服务器的网络、权限或兼容性已通过。进度来自 `curl` 的实际进度条；这里使用慢速回环接收确保覆盖多次中间进度，实际传输中的回调频率仍由 `curl` 和网络状态决定。
