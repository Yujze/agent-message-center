# 智能体消息中心 · AMC

Agent Message Center 是一个 Windows 桌面浮窗。写代码或处理文档时，看一眼胶囊就能知道哪些会话需要输入、哪些刚完成还没读，以及还有几个正在进行。点击胶囊展开列表，再点会话回到对应应用。

## 下载与启动

**安装版**适合日常使用。双击 MSI 为当前用户安装，然后在开始菜单搜索「智能体消息中心」。需要卸载时，打开 Windows「设置 → 应用 → 已安装的应用」，找到 Agent Message Center。[下载 Windows x64 安装包](https://github.com/Yujze/agent-message-center/releases/download/v0.2.0-beta.2/AMC-v0.2.0-beta.2-windows-x64.msi)

**便携版**适合解压即用。把整个 ZIP 解压到一个文件夹，再双击其中的 `AMC.exe`。[下载 Windows x64 便携包](https://github.com/Yujze/agent-message-center/releases/download/v0.2.0-beta.2/AMC-v0.2.0-beta.2-windows-x64-portable.zip)

两种包都包含 PowerShell 和 Python。按住气泡图标可移动浮窗，右键系统托盘里的 AMC 图标可退出。Release 附件中各有一份同名 `.sha256` 文件，可用 `Get-FileHash` 核对。[全部发布文件](https://github.com/Yujze/agent-message-center/releases/tag/v0.2.0-beta.2)

## 会话列表

列表默认显示最近 7 天跨项目的本地会话，也可以切换为近 24 小时、全部时间或单一 Agent。按最近消息或创建时间排序，完成未读会话优先显示。收起和展开沿同一条轨迹过渡，Windows 关闭界面动画时会直接切换。

| 来源 | 可以查看与打开的内容 |
| --- | --- |
| Codex | 读取桌面端的本地会话。侧聊归在主会话下，点击侧聊会打开主会话并选中对应标签。同组重名或无法确认目标时提示手动选择。 |
| DeepSeek Harness（DSH） | 读取桌面工作区和会话投影；点击会话时在 DSH 侧栏定位唯一匹配的完整标题。 |
| Qoder | 合并独立桌面版和 IDE 的本地会话，按 ID 去重。独立版可按 ID 跳转，只有 IDE 记录的会话可在 AMC 中查看。 |

胶囊统计使用与列表相同的筛选条件。「外观」里可以选极简或丰富模式，也可以调整形状、字体、颜色和透明度。待输入、完成未读和进行中各有独立底色。丰富模式把每个 Agent 的图标和会话数放在对应状态内，任务总数和已完成数显示在右侧。

AMC 在本机读取已安装应用的会话索引和可访问的侧栏。能显示哪些状态取决于来源提供的数据；云端 ChatGPT Work 会话需要有本地记录才能出现在列表中。外观设置保存在当前用户的 `%LOCALAPPDATA%\DaiWoJieShou\appearance.json`。

## 从源码运行与打包

源码运行需要 Windows x64、PowerShell 7，以及 PATH 中的 Python 3。在仓库根目录运行：

```powershell
pwsh -NoProfile -STA -File .\app\Start-Reminder.ps1 -CodexLocal
```

在有 Python 3.11 或更高版和 Windows .NET Framework 4.x 编译器的 x64 Windows 上运行以下命令可生成同一版式的便携包。构建脚本从官方发行地址下载已锁定的两个运行时，逐个校验 SHA-256，结果写入 `dist/`。

```powershell
python .\packaging\build.py
```

MSI 使用同版本便携 ZIP 作为输入。将 WiX 4 安装到构建缓存后运行：

```powershell
dotnet tool install wix --version 4.0.6 --tool-path .\.cache\wix4
python .\packaging\build_msi.py .\dist\AMC-v0.2.0-beta.2-windows-x64-portable.zip --wix .\.cache\wix4\wix.exe
```

源码测试使用临时会话数据。在 `app/` 目录运行：

```powershell
python -B -m unittest -q test_codex_local_sessions
pwsh -NoProfile -STA -File .\Test-Reminder.ps1
pwsh -NoProfile -File .\Test-CodexDesktop.ps1
pwsh -NoProfile -File .\Test-ReminderSummary.ps1
```

第三方图标和运行时的来源见[第三方说明](THIRD-PARTY-NOTICES.md)。
