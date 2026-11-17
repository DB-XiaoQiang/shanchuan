# 快捷键只读时序探针

这是独立命令行工具，不创建 AppKit 窗口。它只注册指定的一个 Carbon 快捷键，不监听其他按键、不投递事件、不读取剪贴板、不调用 FTP。组合已被占用时直接失败；不关闭或替换原占用程序。

仅编译，不运行：

```sh
zsh Tests/GlobalShortcuts/run-timing-probe.sh --build-only /tmp/shanchuan-timing-probe
```

在已登录的 macOS 桌面会话中运行默认探针，再手动完整按下和松开 Control+Option+Shift+F12。默认 30 秒自动退出并释放组合：

```sh
zsh Tests/GlobalShortcuts/run-timing-probe.sh > /tmp/shanchuan-hotkey-timing.jsonl
```

可显式指定主键的 macOS 虚拟键码、修饰键和 1～300 秒时限，例如 Control+Option+C（C 的键码为 8）：

```sh
zsh Tests/GlobalShortcuts/run-timing-probe.sh --key-code 8 --modifiers control,option --duration 30
```

若闪传正在占用该组合，该命令会失败。可以先用不冲突的默认组合观察时序；只有用户正常退出占用应用后，才使用原组合验证。探针是临时排查工具，不修改闪传配置。

输出为逐行 JSON，包含 Carbon pressed/released 时间、系统 uptime、配置主键是否仍按下、修饰键 flags，以及 HID/combined 两类来源的具名事件计数。在回调当时和延后 5、25、100 毫秒采样。计数读取不是系统原子快照，因此同时记录每次采样起止时间；`actualDelayMs` 可用于识别主线程或事件队列延迟。它不记录其他按键的键码和内容。
