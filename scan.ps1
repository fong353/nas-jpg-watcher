# ============================================================
#  NAS JPG 元数据巡检 & 修复 - PowerShell 版
#  策略：两层遍历，按 LastWriteTime 筛选
#    1. 从 $Roots 进入，列出"最近 N 天有变动"的一级子目录（月级）
#    2. 对每个命中的月级目录，再列出"最近 N 天有变动"的二级子目录（日级）
#    3. 日级目录作为 exiftool 扫描起点；如果某月下没有日级子目录，则用月级本身
#  目录结构假设：$Roots / 月 / 日 / *.jpg（最多 2 层嵌套）
# ============================================================

# === 配置区 ===
$Roots = @(
    '\\192.168.0.150\nas\小红书\2026',
    '\\192.168.0.150\nas\淘宝\2026'
)
$Days = 5
# ==============

$ErrorActionPreference = 'Continue'
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$ExifTool = Join-Path $Here 'exiftool\exiftool.exe'
$Log = Join-Path $Here 'scan.log'

# 让 PowerShell 和外部程序（exiftool）之间用 UTF-8 通信
# 否则中文路径会被按 ANSI/GBK 传出去，exiftool 拿到乱码路径打不开文件
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
$OutputEncoding = [System.Text.UTF8Encoding]::new()

function Write-Log($msg) {
    $t = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content -Path $Log -Value "[$t] $msg" -Encoding UTF8
}

Write-Log "--- scan start (last $Days d) ---"

# 两层遍历：月级 → 日级，按 LastWriteTime 筛选
$cutoff = (Get-Date).AddDays(-$Days)
$targets = @()
foreach ($root in $Roots) {
    if (-not (Test-Path -LiteralPath $root)) {
        Write-Log "    WARN: root not accessible: $root"
        continue
    }

    # 一层：月级
    $l1dirs = Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
              Where-Object { $_.LastWriteTime -gt $cutoff } |
              Sort-Object LastWriteTime

    foreach ($l1 in $l1dirs) {
        # 二层：日级
        $l2dirs = Get-ChildItem -LiteralPath $l1.FullName -Directory -ErrorAction SilentlyContinue |
                  Where-Object { $_.LastWriteTime -gt $cutoff } |
                  Sort-Object LastWriteTime

        if ($l2dirs.Count -eq 0) {
            # 月里没有日子目录（或日子目录都不活跃） → 直接用月级
            $targets += $l1.FullName
            Write-Log ("    target: {0}  (modified {1:yyyy-MM-dd HH:mm})" -f $l1.FullName, $l1.LastWriteTime)
        } else {
            foreach ($l2 in $l2dirs) {
                $targets += $l2.FullName
                Write-Log ("    target: {0}  (modified {1:yyyy-MM-dd HH:mm})" -f $l2.FullName, $l2.LastWriteTime)
            }
        }
    }
}

if ($targets.Count -eq 0) {
    Write-Log "    (no subfolders modified in last $Days days)"
    Write-Log "--- scan done ---"
    return
}

# Windows + Unicode 的官方方案：把参数写进 UTF-8 文件，用 -@ 让 exiftool 读
# 这样绕开了 Windows 命令行 ACP (GBK) 转换，中文路径原样送达
$argsFile = Join-Path $env:TEMP ("nas-jpg-scan-" + [guid]::NewGuid().ToString() + ".args")
$lines = [System.Collections.Generic.List[string]]::new()
$lines.Add('-charset')
$lines.Add('FileName=UTF8')
$lines.Add('-P')
# 条件 1：只看 JFIF unit=None 的文件
$lines.Add('-if')
$lines.Add('$JFIF:ResolutionUnit eq ''None''')
# 条件 2：至少一个来源（Photoshop / EXIF / JFIF）有可信 DPI 值（>1）
# 用 ne "" 而不是 defined()，argfile 模式下 defined() 不可靠（undef 会被替换为空串再比较数值，抛错）
$lines.Add('-if')
$lines.Add('($Photoshop:XResolution ne "" and $Photoshop:XResolution > 1) or ($EXIF:XResolution ne "" and $EXIF:XResolution > 1) or ($JFIF:XResolution ne "" and $JFIF:XResolution > 1)')
# 翻 unit；XRes/YRes 按 PS 读取优先级级联（Photoshop > EXIF > JFIF 原值）
# 后面的 -tag<src 会覆盖前面的，所以按优先级从低到高写
# JFIF 原值作为基线（不写 self-copy，因为 -tag<tag 自身会让 exiftool 报错）
$lines.Add('-JFIF:ResolutionUnit=inches')
$lines.Add('-JFIF:XResolution<EXIF:XResolution')
$lines.Add('-JFIF:XResolution<Photoshop:XResolution')
$lines.Add('-JFIF:YResolution<EXIF:YResolution')
$lines.Add('-JFIF:YResolution<Photoshop:YResolution')
# 只有命中两个 -if、实际被改的文件才会触发 -FileName 重命名
# exiftool 写法：%f=主文件名，%e=扩展名 → foo.jpg → foo_fixed.jpg
# 跳过的文件原名不变。下一轮扫再命中（不会，JFIF 已是 inches）也是 foo_fixed_fixed.jpg，条件 1 会挡
$lines.Add('-FileName<%f_fixed.%e')
$lines.Add('-overwrite_original')
$lines.Add('-ignoreMinorErrors')
$lines.Add('-r')
$lines.Add('-ext')
$lines.Add('jpg')
$lines.Add('-ext')
$lines.Add('jpeg')
foreach ($t in $targets) { $lines.Add($t) }

# 写成 UTF-8 无 BOM（exiftool -@ 要求）
[System.IO.File]::WriteAllLines($argsFile, $lines, (New-Object System.Text.UTF8Encoding $false))

try {
    # -charset ExifTool=UTF8 必须在 -@ 之前，告诉 exiftool 以 UTF-8 读 arg 文件
    & $ExifTool '-charset' 'ExifTool=UTF8' '-@' $argsFile 2>&1 | ForEach-Object {
        if ($_ -and $_.ToString().Trim() -ne '') {
            Add-Content -Path $Log -Value "    $_" -Encoding UTF8
        }
    }
}
finally {
    Remove-Item -LiteralPath $argsFile -ErrorAction SilentlyContinue
}

Write-Log "--- scan done ---"
