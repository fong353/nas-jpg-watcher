# How Photoshop & Print RIPs Read JPEG DPI — JFIF vs EXIF vs Photoshop/8BIM

> **TL;DR** — A JPEG can carry its resolution (DPI/PPI) in **three different places**, and Photoshop and print RIP software trust them in **different orders**. When they disagree, the same file prints at a different physical size than it looked in Photoshop — usually collapsing to **72 dpi**. This repo documents the *tested* priority rules, the failure modes, and a safe, non-destructive fix.
>
> 一张 JPEG 的分辨率（DPI/PPI）可以存在**三个不同的地方**，而 Photoshop 与印刷 RIP 软件**信任它们的顺序不同**。一旦冲突，同一文件在印刷端的物理尺寸就和它在 Photoshop 里看到的不一样——通常塌缩成 **72 dpi**。本仓库记录了**实测得出**的优先级规则、故障模式，以及一个安全、无损的修复方法。

**Languages:** [English](#english) · [中文](#中文)

> ℹ️ This repository started as a small Windows scheduled-task tool ("nas-jpg-watcher") that auto-aligned JFIF DPI on a NAS. **The code is now retired** — what remains valuable, and what this repo now preserves, are the **conclusions** about how image software interprets JPEG DPI metadata. The original implementation and its full engineering notes live in [`CLAUDE.md`](./CLAUDE.md) and the git history.
>
> 本仓库最初是一个 Windows 定时任务小工具（"nas-jpg-watcher"），自动对齐 NAS 上文件的 JFIF DPI。**代码现已退役**——真正有价值、本仓库现在保留的，是关于图像软件如何解读 JPEG DPI 元数据的**结论**。原始实现与完整工程笔记见 [`CLAUDE.md`](./CLAUDE.md) 和 git 历史。

---

## English

### The problem in one picture

A designer sees an image as **300 dpi → 10 inches wide** in Photoshop. The same file enters a print RIP and comes out at **72 dpi → 41.6 inches wide** (or crashes, or prints blurry). Nothing about the pixels changed — only *which metadata field each program chose to believe*.

### Where DPI lives in a JPEG

| Segment | Marker | Tag | Written by |
|---|---|---|---|
| **Photoshop / 8BIM** | APP13 `Photoshop 3.0` | resource `0x03ED` | Photoshop, Lightroom |
| **EXIF** | APP1 (IFD0) | `XResolution` / `YResolution` / `ResolutionUnit` | cameras, phones, most editors/converters |
| **JFIF** | APP0 | `Xdensity` / `Ydensity` / `units` | the baseline JPEG container; almost always present |

### Priority order — *tested*, not guessed

**Adobe Photoshop** (verified on PS 26.2, Mac):

```
1. Photoshop/8BIM XResolution   (APP13 0x03ED)        ← highest
2. EXIF XResolution             (APP1 IFD0)
3. JFIF Xdensity                (APP0)  — ONLY if units = inches/cm AND value > 0
4. 72 dpi                                              ← default fallback
```

**ErgoSoft RIP** (verified via HotFolder) — representative of the whole "JFIF-trusting RIP" family:

```
1. Photoshop/8BIM XResolution   (APP13 0x03ED)        ← highest (same as PS)
2. JFIF Xdensity                — ONLY if units = inches/cm AND value > 0
3. 72 dpi                                              ← default fallback
✗  EXIF XResolution             — NOT read at all
```

**The single point of divergence:** when 8BIM is absent (the common real-world case), Photoshop falls through to **EXIF** while the RIP falls through to **JFIF**. If those two disagree — or if JFIF is broken — the two programs show different sizes.

| Priority | Photoshop reads | ErgoSoft / JFIF-RIP reads |
|---|---|---|
| 1 | 8BIM | 8BIM |
| 2 | **EXIF** | **JFIF** ← divergence |
| 3 | JFIF | 72 |

### Two facts that explain everything

**1. JFIF `units = 0` does NOT mean "0 dpi" — it means "no resolution, aspect ratio only."**
Per the JFIF 1.02 spec (W3C/ECMA), when `units = 0`, `Xdensity:Ydensity` is the **pixel aspect ratio**, not DPI. `1,1` = square pixels, *no resolution info*. A program that literally reads "1 dpi" from such a file is buggy — and several have shipped that bug (ImageMagick #8460, libvips #1641). Correct behavior is to ignore it and fall back to 72.

**2. The EXIF standard itself declares camera DPI "meaningless."**
CIPA DC-008 / JEITA CP-3451 (the EXIF spec) sets the default `XResolution`/`YResolution` to **72**, says *"When image resolution is unknown, 72 [dpi] shall be designated,"* and states outright: *"for images produced by digital cameras, image resolution values such as ppi are meaningless."* Manufacturers stamp arbitrary, inconsistent values (Canon 72/180/350, Nikon 300/100, Sony varies). **This is why print RIPs distrust EXIF and read JFIF instead** — it is not paranoia, the defining body says the field is meaningless.

> Nuance: a camera's *original* EXIF DPI is junk, but when a downstream tool (a converter, a phone editor) **recomputes and rewrites** EXIF resolution, that value can be correct. So "EXIF DPI" is sometimes junk and sometimes the only trustworthy source in a given file — the only safe discriminator is *"is there a value > 1?"*.

### Failure modes (field-tested)

| # | What the file looks like | Photoshop shows | JFIF-RIP shows | Safe action |
|---|---|---|---|---|
| 1 | JFIF `units=None`, Xdensity > 1 | 72 | 72 | Flip `units → inches`; both then read the real value |
| 2 | No JFIF, 8BIM present | reads 8BIM | reads 8BIM | nothing — already aligned |
| 3 | JFIF `units=None`, Xdensity = 1 ("Save for Web") | 72 | 72 | **nothing** — this is "no DPI", do NOT turn it into "1 dpi" |
| 4 | JFIF `units=None`, but 8BIM/EXIF has a real value | reads 8BIM/EXIF | 72 (dragged down by JFIF) | flip unit + cascade value from EXIF/8BIM into JFIF |
| 5 | only EXIF + APP14, no JFIF/8BIM | reads EXIF | 72 (EXIF ignored) | dead zone — re-export from the source app |
| 6 | every segment is 72, business wanted 300 | 72 | 72 | not a metadata bug — fix at the source |
| 7 | JFIF `inches`, Xdensity = 1 (legacy corruption) | shows 1 dpi (huge size) | **crashes** (no sanity check) | re-export from Photoshop |

### The safe fix (ExifTool)

The whole correction is "be a courier for a trustworthy number, never invent one." Only act when (a) the JFIF unit is broken **and** (b) some segment carries a value worth copying:

```sh
exiftool \
  -if "$JFIF:ResolutionUnit eq 'None'" \
  -if "$Photoshop:XResolution > 1 or $EXIF:XResolution > 1 or $JFIF:XResolution > 1" \
  -JFIF:ResolutionUnit=inches \
  -JFIF:XResolution#"<EXIF:XResolution" \
  -JFIF:XResolution#"<Photoshop:XResolution" \
  -JFIF:YResolution#"<EXIF:YResolution" \
  -JFIF:YResolution#"<Photoshop:YResolution" \
  -overwrite_original -P -charset ExifTool=UTF8 \
  target_dir
```

- Cascade order matters: the later `<src` wins, so Photoshop is written last = highest priority, EXIF is the baseline.
- The second `-if` is the guard that **skips "Save for Web" files** (`XRes=1`, no 8BIM/EXIF) so you never manufacture a "1 dpi" file.

Diagnose any file with:

```sh
exiftool -G1 -a -s -ResolutionUnit -XResolution -YResolution image.jpg
```

### Verification status across RIPs

| Software | Reads EXIF DPI? | Evidence |
|---|---|---|
| **ErgoSoft** | ✗ JFIF only, 72 fallback | first-hand HotFolder test |
| **Onyx** | ✗ JFIF only, 72 fallback | Pillow #3328, ruby-vips #247 |
| **Generic libs** (ImageSharp, Qt) | ✗ JFIF wins over EXIF | ImageSharp #745, Qt QTBUG-62249 |
| **Caldera / ColorGate / EFI Fiery** | unknown — vendor black box | no public docs (searched EN/DE/中文); test locally |
| **Photoshop** | ✓ EXIF (when no 8BIM) | PS 26.2 test + ExifTool forum #1515 (8BIM > EXIF) |

**Takeaway:** writing the correct DPI into **JFIF** is the *universal* fix, not an ErgoSoft-specific patch — it feeds every "JFIF-trusting" RIP at once. The vendors that publish nothing (Caldera/ColorGate/EFI) can only be confirmed by dropping in an "EXIF-only" and a "JFIF unit=None" test file and reading the displayed size.

### Sources

JFIF 1.02 spec (W3C / ECMA TR-98) · CIPA DC-008 / JEITA CP-3451 (EXIF) · ImageMagick #8460 · libvips #1641 · ExifTool forum topics #1515 & #8651 · Adobe Community 9614560 · Pillow #3328 · ruby-vips #247 · ImageSharp #745 · Qt QTBUG-62249.

---

## 中文

### 一张图说清问题

设计师在 Photoshop 里看到一张图是 **300 dpi → 宽 10 英寸**。同一个文件进了印刷 RIP，输出却是 **72 dpi → 宽 41.6 英寸**（或者崩溃、或者打印发虚）。像素一个没变——变的只是**每个程序选择相信哪个元数据字段**。

### JPEG 里 DPI 藏在哪

| 段 | 标记 | 字段 | 谁写的 |
|---|---|---|---|
| **Photoshop / 8BIM** | APP13 `Photoshop 3.0` | 资源 `0x03ED` | Photoshop、Lightroom |
| **EXIF** | APP1 (IFD0) | `XResolution` / `YResolution` / `ResolutionUnit` | 相机、手机、多数编辑器/转换器 |
| **JFIF** | APP0 | `Xdensity` / `Ydensity` / `units` | JPEG 基础容器；几乎总是存在 |

### 优先级——**实测**，非猜测

**Adobe Photoshop**（PS 26.2 Mac 实测）：

```
1. Photoshop/8BIM XResolution   (APP13 0x03ED)        ← 最高
2. EXIF XResolution             (APP1 IFD0)
3. JFIF Xdensity                (APP0)  — 仅当 units = inches/cm 且 值 > 0
4. 72 dpi                                              ← 默认兜底
```

**ErgoSoft RIP**（HotFolder 实测）——代表整个"信 JFIF 的 RIP"家族：

```
1. Photoshop/8BIM XResolution   (APP13 0x03ED)        ← 最高（与 PS 一致）
2. JFIF Xdensity                — 仅当 units = inches/cm 且 值 > 0
3. 72 dpi                                              ← 默认兜底
✗  EXIF XResolution             — 完全不读
```

**唯一的分歧点**：当 8BIM 缺失时（现实中的常见情况），Photoshop 落到 **EXIF**，而 RIP 落到 **JFIF**。这两者一旦不一致——或 JFIF 被写坏——两个程序就显示不同尺寸。

| 优先级 | Photoshop 读 | ErgoSoft / 信 JFIF 的 RIP 读 |
|---|---|---|
| 1 | 8BIM | 8BIM |
| 2 | **EXIF** | **JFIF** ← 分歧 |
| 3 | JFIF | 72 |

### 两个事实解释一切

**1. JFIF `units = 0` 不是"0 dpi"，是"无分辨率、仅纵横比"。**
按 JFIF 1.02 规范（W3C/ECMA），`units = 0` 时 `Xdensity:Ydensity` 表示**像素纵横比**而非 DPI。`1,1` = 方形像素、*无分辨率信息*。把这种文件字面读成"1 dpi"的程序是有 bug 的——而且确实有软件出过这个 bug（ImageMagick #8460、libvips #1641）。正确做法是无视它、回落 72。

**2. EXIF 标准自己宣布相机 DPI"无意义"。**
CIPA DC-008 / JEITA CP-3451（即 EXIF 规范）把 `XResolution`/`YResolution` 默认值定为 **72**，写明*"分辨率未知时，规定填 72"*，并直接声明：*"对数码相机产生的图像，ppi 这类分辨率值是无意义的。"* 厂商各填各的、互不一致（佳能 72/180/350、尼康 300/100、索尼按机型）。**这就是印刷 RIP 不信 EXIF、转而读 JFIF 的根因**——不是偏执，是定标准的机构自己说这个字段无意义。

> 细微差别：相机*原始*的 EXIF DPI 是垃圾，但当下游工具（转换器、手机修图 app）**重算并重写** EXIF 分辨率时，那个值可能是对的。所以"EXIF DPI"有时是垃圾、有时又是某个文件里唯一可信的来源——唯一安全的判据是*"是否存在 > 1 的值"*。

### 故障模式（实地验证）

| # | 文件长什么样 | Photoshop 显示 | 信 JFIF 的 RIP 显示 | 安全动作 |
|---|---|---|---|---|
| 1 | JFIF `units=None`，Xdensity > 1 | 72 | 72 | 翻 `units → inches`；两边随即读到真值 |
| 2 | 无 JFIF，有 8BIM | 读 8BIM | 读 8BIM | 不动——本来就对齐 |
| 3 | JFIF `units=None`，Xdensity = 1（"存储为 Web"）| 72 | 72 | **不动**——这是"无 DPI"，绝不能改成"1 dpi" |
| 4 | JFIF `units=None`，但 8BIM/EXIF 有真值 | 读 8BIM/EXIF | 72（被 JFIF 拖累）| 翻 unit + 把 EXIF/8BIM 的值级联进 JFIF |
| 5 | 只有 EXIF + APP14，无 JFIF/8BIM | 读 EXIF | 72（EXIF 被忽略）| 死区——回源 app 重导出 |
| 6 | 所有段都是 72，业务想要 300 | 72 | 72 | 不是元数据 bug——从源头改 |
| 7 | JFIF `inches`，Xdensity = 1（历史损坏）| 显示 1 dpi（尺寸巨大）| **崩溃**（无 sanity check）| 回 Photoshop 重导出 |

### 安全修复（ExifTool）

整个修复的精神是"只当可信数字的搬运工，绝不发明数字"。仅当 (a) JFIF unit 坏了 **且** (b) 某个段带着值得搬运的值时才动手：

```sh
exiftool \
  -if "$JFIF:ResolutionUnit eq 'None'" \
  -if "$Photoshop:XResolution > 1 or $EXIF:XResolution > 1 or $JFIF:XResolution > 1" \
  -JFIF:ResolutionUnit=inches \
  -JFIF:XResolution#"<EXIF:XResolution" \
  -JFIF:XResolution#"<Photoshop:XResolution" \
  -JFIF:YResolution#"<EXIF:YResolution" \
  -JFIF:YResolution#"<Photoshop:YResolution" \
  -overwrite_original -P -charset ExifTool=UTF8 \
  目标目录
```

- 级联顺序有讲究：后写的 `<src` 覆盖前面，所以 Photoshop 写在最后 = 最高优先，EXIF 作基线。
- 第二个 `-if` 是守门员，**跳过"存储为 Web"文件**（`XRes=1`、无 8BIM/EXIF），保证绝不制造出"1 dpi"文件。

诊断任意文件：

```sh
exiftool -G1 -a -s -ResolutionUnit -XResolution -YResolution image.jpg
```

### 各 RIP 核实状态

| 软件 | 读 EXIF DPI 吗？ | 证据 |
|---|---|---|
| **ErgoSoft** | ✗ 只读 JFIF，回落 72 | 一手 HotFolder 实测 |
| **Onyx** | ✗ 只读 JFIF，回落 72 | Pillow #3328、ruby-vips #247 |
| **通用图像库**（ImageSharp、Qt）| ✗ JFIF 压倒 EXIF | ImageSharp #745、Qt QTBUG-62249 |
| **Caldera / ColorGate / EFI Fiery** | 未知——厂商黑盒 | 无公开文档（中英德三语搜过）；需本地实测 |
| **Photoshop** | ✓ EXIF（无 8BIM 时）| PS 26.2 实测 + ExifTool 论坛 #1515（8BIM > EXIF）|

**核心结论**：把正确的 DPI 写进 **JFIF** 是**普适**修复，而非只针对 ErgoSoft 的补丁——它一次喂对所有"信 JFIF"的 RIP。那些什么都不公开的厂商（Caldera/ColorGate/EFI）只能靠丢一张"仅 EXIF"和一张"JFIF unit=None"的测试图、读显示尺寸来确认。

### 出处

JFIF 1.02 规范（W3C / ECMA TR-98）· CIPA DC-008 / JEITA CP-3451（EXIF）· ImageMagick #8460 · libvips #1641 · ExifTool 论坛 #1515 与 #8651 · Adobe 社区 9614560 · Pillow #3328 · ruby-vips #247 · ImageSharp #745 · Qt QTBUG-62249。

---

*Original tool implementation & full engineering notes (Chinese): [`CLAUDE.md`](./CLAUDE.md). Retired but preserved for reference.*
*原始工具实现与完整工程笔记（中文）见 [`CLAUDE.md`](./CLAUDE.md)，已退役但保留作参考。*
