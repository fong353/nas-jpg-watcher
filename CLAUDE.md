# CLAUDE.md — NAS JPG Watcher

> Claude Code 在这个目录工作时先读这个文件。给你快速上下文，避免重复推演。

## 这个项目干什么

Win 电脑上的定时任务，每 30 分钟扫描 NAS 上指定目录，做 **PS→ErgoSoft 的 DPI 对齐中间件**：
确保 JPG 的 JFIF 段头写入"PS 读取到的 DPI 数值"，让 ErgoSoft（严守 JFIF 的下游）看到的打印尺寸 = 业务员在 PS 里看到的物理尺寸。

**核心原则**：不发明数字。能从文件里推断出 PS 视角的 DPI 才动手；推不出来（Save for Web 这类信息全剥的文件）就**什么都不做**——该文件在 PS 和 ErgoSoft 里都会显示默认 72，两边天然一致。

## 架构

```
Win 任务计划程序（每 30 min）
   └─ scan.cmd （瘦封装，仅转发）
         └─ powershell.exe -File scan.ps1
                 ├─ 两层遍历 $Roots（月级 → 日级），按 LastWriteTime 过滤
                 └─ 把活跃目录一次性传给 exiftool 递归处理
                        └─ exiftool.exe （本地绿色版）
                              ├─ -if 1: $JFIF:ResolutionUnit eq 'None'             （只看 unit 坏的文件）
                              ├─ -if 2: 至少一个段 (8BIM/EXIF/JFIF) XRes>1          （有可信 DPI 来源才动手）
                              ├─ -JFIF:ResolutionUnit=inches                       （翻 unit）
                              ├─ -JFIF:XResolution<EXIF:XResolution                （EXIF 覆盖 JFIF 基线）
                              ├─ -JFIF:XResolution<Photoshop:XResolution           （8BIM 最高优先，最后覆盖）
                              ├─ （同上 YResolution）
                              ├─ -overwrite_original                               （原子替换）
                              └─ -P                                                 （保留 FileModifyDate）
```

## 文件职责

| 文件 | 改不改 | 职责 |
|---|---|---|
| `scan.cmd` | ❌ | 手动调试入口：`chcp 65001` + 调 `powershell -File scan.ps1`。可见窗口 |
| `scan-silent.vbs` | ❌ | 计划任务真正的入口：VBScript `Shell.Run(..., 0, False)` 隐藏启动 `scan.cmd`，彻底无窗口闪现 |
| `scan.ps1` | ✅ | 配置（`$Roots` / `$Days`）+ 所有逻辑 |
| `exiftool/exiftool.exe` | ❌ | ExifTool 13.57 Win 64 绿色版，整包自带 |
| `install-task.cmd` | 偶尔 | 注册 `schtasks /sc minute /mo 30`。改周期改这里的 `/mo`（支持 `/sc minute/hourly/daily` 等） |
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

### 为什么要两个 `-if` 条件（条件 2 的存在理由）

v1（第一版）只有 `$JFIF:ResolutionUnit eq 'None'` 一个条件，假设"unit 是唯一被破坏的字节，XRes/YRes 的数值是可信的"。

2026-04-22 踩到的坑：PS "存储为 Web (旧版)" 导出的文件会输出 `JFIF unit=None, XRes=1, YRes=1`（JFIF 规范里这表示"无 DPI 信息，像素纵横比 1:1"，是合法状态）。v1 命中后翻成 `unit=inches`，XRes=1 被字面解读成 1 dpi → PS 和 ErgoSoft 都显示 1 dpi → 打印尺寸爆炸 72 倍。

**v2（当前）加条件 2**：`$Photoshop:XResolution > 1 or $EXIF:XResolution > 1 or $JFIF:XResolution > 1`。Save for Web 文件 8BIM/EXIF 都没，JFIF.XRes=1，三项全不满足，跳过。

`-JFIF:XResolution<EXIF:XResolution` 和 `-JFIF:XResolution<Photoshop:XResolution` 的级联是处理故障模式 4：后写的 `<src` 会覆盖前面的，所以 Photoshop 写在最后 = 最高优先。

### argfile 模式下条件里必须用 `ne ""` 不能用 `defined()`

踩坑：想用 `defined $Photoshop:XResolution and $Photoshop:XResolution > 1` 做防御，但 argfile 模式下报：
```
Condition: Argument "" isn't numeric in numeric gt (>)
```

原因：exiftool 的 `$tag` 求值若 tag 不存在，替换成空串而不是 undef。`defined "" ` 永远是 true，短路失败，接着 `"" > 1` 抛数值转换错误。

解法：`$Photoshop:XResolution ne "" and $Photoshop:XResolution > 1`——先字符串判空，再比较数值。

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

## PS 读 JPG DPI 的优先级（2026-04-24 实测 PS 26.2 Mac 确认）

```
PS view DPI =
    1. Photoshop:XResolution  (APP13 / 8BIM 0x03ED)  — 最高优先
    2. EXIF:XResolution       (APP1 IFD0)
    3. JFIF:XResolution       (APP0) —— 仅当 JFIF:ResolutionUnit = inches/cm AND XRes > 0 才被信任
    4. 72                     — 默认 fallback
```

实测真值表（样本见 `~/Desktop/dpi-test/`，每个文件在 PS "图像→图像大小"对话框里读的数）：

| 样本 | 8BIM | EXIF | JFIF | PS 实测 | 说明 |
|---|---|---|---|---|---|
| S0/02原图 | 300 | 300 | 无 | 300 | Save As 正常基线 |
| S1 | 300 | 72  | 无 | 300 | **8BIM 胜 EXIF** |
| S2 | 无  | 300 | 无 | 300 | 仅 EXIF |
| S3 | 无  | 无  | inches,150 | 150 | 仅 JFIF 合理值 |
| S4 | 无  | 无  | **None**,300 | **72** | **unit=None → PS 无视 XRes，回落默认** |
| S5 | 无  | 无  | inches,**1** | **1** | PS 老实读 1，不做智能判断 |
| S6 | 无  | 无  | 无 | 72 | PS 默认 |

两个非常重要的结论：
- **S4**：unit=None 时 PS 跟 ErgoSoft 一样严格——XRes 的数值完全不被采纳
- **S5**：PS 不会把"XRes=1"识别为异常值，会老实显示 1 dpi（业务员质检时可以看出）

## ErgoSoft 读 JPG DPI 的优先级（2026-04-24 实测 ErgoSoft HotFolder 确认）

```
ErgoSoft view DPI =
    1. Photoshop:XResolution  (APP13 / 8BIM 0x03ED)  — 最高优先（与 PS 一致）
    2. JFIF:XResolution        — 仅当 unit=inches/cm AND XRes > 0 才被信任
    3. 72                      — 默认 fallback
    ❌ EXIF:XResolution        — 不读！
```

实测方法：`~/Desktop/final-test/T1–T4` 只写单段 DPI 分别 120/240/360，对比 PS 和 ErgoSoft 显示的物理尺寸。

关键发现：
- **T2（仅 EXIF=240）** ErgoSoft 显示 72 dpi 回落 —— EXIF 被完全忽略
- **T4（三段冲突）** ErgoSoft 显示 360 = 8BIM 值 —— 与 PS 优先级一致
- **sample-E（JFIF inches 1）** ErgoSoft **直接崩溃**（不是 72 fallback），证明 ErgoSoft 对 1 dpi 无 sanity check，数值爆栈

## PS vs ErgoSoft 对比（为什么中间件只写 JFIF）

| 优先级 | PS 读 | ErgoSoft 读 |
|---|---|---|
| 1 | 8BIM | 8BIM |
| 2 | EXIF | **JFIF** ← 分歧点 |
| 3 | JFIF | 72 |

**只在 8BIM 缺失时两边才会分歧**。中间件目标 = 修复 JFIF，让两边都对齐到 PS 视角的值。写 JFIF 即可（8BIM 存在时两边本来就对齐，写 JFIF 冗余但无害）。

## 故障模式表（2026-04-24 更新，含 ErgoSoft 实测）

| # | 特征 | JFIF 段 | PS 视角 | ErgoSoft 视角 | 当前脚本行为 |
|---|---|---|---|---|---|
| 1 | JFIF unit=None, XRes 有值 (>1) | 存在 | 72（PS 不信 unit=None）| 72（同 PS）| ✅ 翻 unit→inches，PS 和 ErgoSoft 同步改读 XRes 值 |
| 2 | JFIF 段缺失，8BIM 存在（PS Save As 输出）| 无 | 读 8BIM | **读 8BIM**（实测 T3/T4 确认）| ➖ 不命中条件 1，跳过（本来就对齐）|
| 3 | JFIF unit=None, XRes=1（PS "存储为 Web" 输出）| 存在 | 72 | 72 | ✅ **命中条件 1 但不满足条件 2**，**显式跳过**——避免把"无 DPI"误改成"1 dpi"|
| 4 | JFIF unit=None，但 8BIM/EXIF 有合理值 | 存在 | 读 8BIM/EXIF 值 | 72（被 JFIF unit=None 拖累）| ✅ 翻 unit 并用 `-JFIF:X/YRes<EXIF/Photoshop:X/YRes` 级联同步 |
| 5 | 无 8BIM 无 JFIF，只有 EXIF + APP14（合成样本 sample-B）| 无 | 读 EXIF | **72 fallback**（EXIF 不读）| ❌ **死区**：exiftool 拒绝给 APP14 文件建 JFIF，剥 APP14 有色彩风险 → 放弃。业务员 PS Save 正常流程不会产生这种文件 |
| 6 | 所有段都是 72 且业务需要 300 | — | 72 | 72 | ❌ 数据不是 bug，业务员在 PS 里一眼看出 72，需源头处理 |
| 7 | **历史损坏 JFIF inches XRes=1**（旧版 scan.ps1 修坏的存量文件）| 存在 | 1 dpi（PS 显示数米尺寸，业务员能发现）| **崩溃**（ErgoSoft 无 sanity check）| ❌ **不修**（用户决定）：新中间件条件 2 挡住避免再造，存量需业务员 PS 重导出救回 |

诊断命令：
```
exiftool -G1 -a -s -ResolutionUnit -XResolution -YResolution "问题图.jpg"
```

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
- **改扫描周期** → `install-task.cmd` 的 `/mo 30` 改数字（或换 `/sc` 单位），卸载旧任务后重装
- **改扫描天数** → `scan.ps1` 的 `$Days`
- **换修复逻辑（比如加 XRes 同步）** → `scan.ps1` 里 `$etArgs` 那段，按 exiftool 语法加参数
- **加 mtime 预过滤优化** → 日增量爆到 5000+ 张才考虑，用 `Get-ChildItem -Recurse` + `Where LastWriteTime`
