# CLAUDE.md — NAS JPG Watcher

> Claude Code 在这个目录工作时先读这个文件。给你快速上下文，避免重复推演。

## 这个项目干什么

Win 电脑上的定时任务，每 3 分钟扫描 NAS 上指定目录，**只修一种故障**：JPG 的 `JFIF:ResolutionUnit=None`（0）—— 该故障会让 ErgoSoft 等严守 JFIF 标准的下游软件把 DPI 回落到 72，导致打印尺寸错算为实际的 ~4.17 倍。

## 架构

```
Win 任务计划程序（每 3 min）
   └─ scan.cmd （瘦封装，仅转发）
         └─ powershell.exe -File scan.ps1
                 ├─ 列出 $Roots 下的一级子目录
                 ├─ 过滤 CreationTime 在最近 $Days 天内的
                 └─ 把这些目录一次性传给 exiftool 递归处理
                        └─ exiftool.exe （本地绿色版）
                              ├─ -if "JFIF:ResolutionUnit eq 'None'"  （只改真坏的）
                              ├─ -JFIF:ResolutionUnit=inches          （只翻 1 字节）
                              ├─ -overwrite_original                  （原子替换）
                              └─ -P                                   （保留 FileModifyDate）
```

## 文件职责

| 文件 | 改不改 | 职责 |
|---|---|---|
| `scan.cmd` | ❌ | 手动调试入口：`chcp 65001` + 调 `powershell -File scan.ps1`。可见窗口 |
| `scan-silent.vbs` | ❌ | 计划任务真正的入口：VBScript `Shell.Run(..., 0, False)` 隐藏启动 `scan.cmd`，彻底无窗口闪现 |
| `scan.ps1` | ✅ | 配置（`$Roots` / `$Days`）+ 所有逻辑 |
| `exiftool/exiftool.exe` | ❌ | ExifTool 13.57 Win 64 绿色版，整包自带 |
| `install-task.cmd` | 偶尔 | 注册 `schtasks /sc minute /mo 3`。改周期改这里的 `/mo` |
| `uninstall-task.cmd` | ❌ | 一行 `schtasks /delete`  |
| `scan.log` | 运行时生成 | UTF-8 追加写，每次 start/target/done 三类行 |
| `部署说明.md` | ✅ | 给最终用户看的部署 + 排查文档 |

## 设计决策（重要，别回退）

### 为什么 CMD 薄封装 + PowerShell 主逻辑
- CMD 里算日期和枚举目录太痛苦；PowerShell 的 `Get-ChildItem -Directory | Where CreationTime` 一行完事
- 但 `schtasks` 调 `.ps1` 会遇到执行策略拦截；调 `.cmd` 最简。所以保留 `scan.cmd` 作为不变的入口

### 为什么有个 `scan-silent.vbs`
- 计划任务直接调 `scan.cmd` 会闪黑窗（schtasks 在"只在用户登录时运行"模式下每次触发都可见）
- 走 "不管用户是否登录都运行" 模式能彻底静默，但要填账密 → 用户拒绝
- VBScript 的 `Shell.Run(..., 0, False)` 是经典"完全无窗口"启动方案，0 = SW_HIDE
- 流程：计划任务 → wscript.exe scan-silent.vbs → （隐藏）scan.cmd → chcp + powershell scan.ps1
- 手动调试时仍可直接双击 `scan.cmd`，会看到窗口输出

### 为什么按 LastWriteTime + 两层遍历
- 早期版本 1：按 `yyyyMMdd` 目录名匹配 → 假设命名约定
- 早期版本 2：按 CreationTime → 实测踩坑：月级目录（`4月`）CreationTime = 月初，5 天后被过滤掉
- 早期版本 3：按 LastWriteTime 只看一级子目录 → 命中月级目录，exiftool 递归整月，HDD 上可能几十秒到几分钟
- **最终**：两层遍历。月级 LastWriteTime 筛 → 日级 LastWriteTime 筛 → 只把活跃的日级目录交给 exiftool。单轮只扫当天活跃的几十到几百张文件
- Fallback：如果某个匹配月下没有日子目录（或都不活跃），降级用月级作为 target
- 副作用：假设目录结构最多 2 层嵌套（月/日）。如果用户将来改结构成 3 层（月/周/日）脚本需调整 `$MaxDepth` 或改成递归

### 为什么不用 `-q`
- 要让"N image files updated"这行能打到日志里，方便用户自检。每轮多 1 行，无所谓

### 为什么变量名叫 `$etArgs` 不叫 `$args`
- `$args` 是 PowerShell 自动变量（脚本参数）。覆盖它可能出怪问题。踩过这个坑

### 中文路径 Unicode：为什么不能走命令行，必须用 arg 文件
Windows + PS 5.1 + 外部 Perl 程序（exiftool）传中文路径有个死角：

- PS 5.1 调 `& exe.exe arg` 时，内部用 `CreateProcessW`（UTF-16 命令行）
- 但 Perl exiftool 从 `GetCommandLineA` 读参数 → Windows 用**系统 ACP (ANSI Code Page)** 把 UTF-16 转 ANSI 字节
- 中文 Win 的 ACP = 936 (GBK)，exiftool 拿到 GBK 字节
- `chcp 65001` 只改**控制台 codepage**，**不改系统 ACP**，所以没用
- `[Console]::OutputEncoding` 也只影响 STDOUT/STDIN 读写，不影响 args 传递

唯一靠谱解法：**用 exiftool 的 `-@ argfile` 从 UTF-8 文件读参数**。命令行上只留 ASCII 参数（`-charset ExifTool=UTF8 -@ path`），中文路径全进 arg 文件。

**调试踩坑历史**：
- v1：`$etArgs` 数组 + `[Console]::OutputEncoding = UTF8` → exiftool 报 `FileName encoding not specified`
- v2：加 `-charset FileName=UTF8` → 报 `Invalid filename encoding`（PS 把 UTF-16 按 ACP=GBK 转字节给 exiftool，exiftool 按 UTF-8 解析失败）
- v3：加 `chcp 65001` 到 scan.cmd → 依然 `Invalid filename encoding`（chcp 不改 ACP）
- **v4（当前）**：`-@ argfile`。把所有带中文的 args 写进 UTF-8 无 BOM 文件，命令行只有 `-charset ExifTool=UTF8 -@ file.args`。所有中文原样送达

### `chcp 65001` 还留着的理由
虽然 chcp 对 exiftool 子进程没效果，但它让 exiftool 的 STDOUT 输出（错误信息里的路径）能按 UTF-8 打回来，log 文件里不乱码。保留它不亏。

### `.cmd` 文件必须全 ASCII（不能写中文 echo）
cmd.exe 读批处理用系统默认 codepage（中文 Win = 936/GBK）。如果 `.cmd` 文件用 UTF-8 保存却含中文 echo 行，cmd 按 GBK 解析 UTF-8 字节序列，会把 `"` `^` 等命令字符识错，报"XXX 不是内部或外部命令"这类错。
- `REM` 注释里的中文不影响执行（cmd 忽略 REM 内容）
- 但 `echo 中文` / `set "X=中文"` / `if "X" equ "中文"` 这些都会炸
- 所以所有 `.cmd` 文件都用纯 ASCII，中文文档留在 `.md` 和 `.ps1`（PS 用 UTF-8 BOM 读，无此问题）

踩过的坑：`install-task.cmd` 初版有 `echo 注册任务:` 之类中文输出，管理员运行时炸出一屏错。改为英文后正常。

### 为什么 `-overwrite_original` 安全
- exiftool 实现是：写临时文件到同目录 → 原子 rename 覆盖。不存在"改到一半文件坏掉"的中间态
- 被其他进程独占锁住时 exiftool 报错跳过（有 `-ignoreMinorErrors`），下一轮再试

## 当前配置（用户真实环境）

- NAS：`\\192.168.0.150\nas`（挂载为 `Z:`），HDD 存储
- 根目录：`\小红书\2026\` 和 `\淘宝\2026\`
- **实际子目录结构：月 / 日**（`4月/20260423/*.jpg`）
- 脚本做两层遍历：月级筛 LastWriteTime → 日级再筛 LastWriteTime → 拿到最活跃的日级目录作为扫描起点。如果某月下没有日子目录，fallback 用月级本身
- `$Days = 5`（覆盖 1-5 分钟延迟要求以及"几天内可能还要再处理"的业务窗口）
- 目标文件量：日增 ~几百张 JPG

## 对用户的潜在坑（按常见度排序，详见部署说明.md §五）

1. 后台任务没 NAS 凭据 → 凭据管理器存
2. "不管用户是否登录都运行" 的 Win 账号密码过期 → 任务静默停
3. NAS 返回的 CreationTime 不对（极少见）→ 第一次日志里看 `created` 时间是否合理
4. 复制老文件夹进来 → 被识别为新，扫一次无害
5. PowerShell 执行策略拦截 → `scan.cmd` 用了 `-ExecutionPolicy Bypass`，一般不会遇到

## 已知未处理的故障模式

当前脚本只解决 **JPG 故障模式 1**（JFIF unit=None）。模式 2-5 参考：

| # | 特征 | 当前方案 |
|---|---|---|
| 1 | JFIF unit=None, XRes 有值 | ✅ 已解 |
| 2 | JFIF 和 IFD0 都没 XResolution（PS "存储为 Web" 剥了） | ❌ 需源头处理或脚本写默认值 |
| 3 | JFIF:XRes=72 但 EXIF:XRes=300（PS 老 bug） | ⚠️ 需升级为 `-JFIF:XResolution<EXIF:XResolution` |
| 4 | JFIF 段缺失但 IFD0 有值 | ⚠️ 同 3 |
| 5 | JFIF=72 且 IFD0=72 真实低 DPI | ❌ 数据不是 bug，需业务规则 |

用户遇到修了还不对的图，让他跑诊断命令贴输出：
```
exiftool -G1 -a -s -ResolutionUnit -XResolution -YResolution "问题图.jpg"
```
对号入座后升级 `scan.ps1`。

## 相关项目

- `../SendToErgoSoft/`：同一个用户的另一个工具，AHK 脚本，手动把选中 JPG 投递到 ErgoSoft HotFolder（同时顺手修 JFIF）。早期方案，现在用户只要 NAS 巡检这个项目
- `~/.claude/plans/rip-ergosoft-ui-unified-bumblebee.md`：主规划文档，包含 JPG 故障模式 1-5 的完整诊断和验证过程

## 用户偏好（摘自 ~/.claude/CLAUDE.md）

- 中文交流，回复简洁
- 不喜欢造轮子，优先现成工具
- 破坏性操作需确认
- 大的更新后 commit 前请用户注释

## 常见修改场景速查

- **加一个扫描根目录** → `scan.ps1` 的 `$Roots` 数组加一行
- **改扫描周期** → `install-task.cmd` 的 `/mo 3` 改，卸载旧任务后重装
- **改扫描天数** → `scan.ps1` 的 `$Days`
- **换修复逻辑（比如加 XRes 同步）** → `scan.ps1` 里 `$etArgs` 那段，按 exiftool 语法加参数
- **加 mtime 预过滤优化** → 日增量爆到 5000+ 张才考虑，用 `Get-ChildItem -Recurse` + `Where LastWriteTime`
