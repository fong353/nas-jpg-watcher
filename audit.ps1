# 只读 audit：扫 JFIF.unit=None 的文件，统计 Photoshop / EXIF / JFIF 三段 XRes 分布
# 不修任何文件，只产出 audit.json + 控制台报告
#
# 用途：定期验证"真实坏文件分布"，决定修复逻辑是否还合理。
# 首次跑的产出见 CLAUDE.md「2026-05-24 NAS 实测分布」段。

$Roots = @(
    '\\192.168.0.150\nas\小红书\2026',
    '\\192.168.0.150\nas\淘宝\2026'
)
$Days = 30
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$ExifTool = Join-Path $Here 'exiftool\exiftool.exe'
$AuditJson = Join-Path $Here 'audit.json'

[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
$OutputEncoding = [System.Text.UTF8Encoding]::new()

# 复用 scan.ps1 的两层遍历
$cutoff = (Get-Date).AddDays(-$Days)
$targets = @()
foreach ($root in $Roots) {
    if (-not (Test-Path -LiteralPath $root)) { Write-Host "skip: $root"; continue }
    $l1dirs = Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
              Where-Object { $_.LastWriteTime -gt $cutoff }
    foreach ($l1 in $l1dirs) {
        $l2dirs = Get-ChildItem -LiteralPath $l1.FullName -Directory -ErrorAction SilentlyContinue |
                  Where-Object { $_.LastWriteTime -gt $cutoff }
        if ($l2dirs.Count -eq 0) {
            $targets += $l1.FullName
        } else {
            foreach ($l2 in $l2dirs) { $targets += $l2.FullName }
        }
    }
}

Write-Host "targets: $($targets.Count)"
$targets | ForEach-Object { Write-Host "  $_" }

if ($targets.Count -eq 0) { Write-Host "no targets, abort"; return }

# argfile：-if 筛 JFIF.unit=None，-j -G1 输出 JSON
$argsFile = Join-Path $env:TEMP ("audit-" + [guid]::NewGuid().ToString() + ".args")
$lines = [System.Collections.Generic.List[string]]::new()
$lines.Add('-charset')
$lines.Add('FileName=UTF8')
$lines.Add('-if')
$lines.Add('$JFIF:ResolutionUnit eq ''None''')
$lines.Add('-j')
$lines.Add('-G1')
$lines.Add('-FilePath')
$lines.Add('-Photoshop:XResolution')
$lines.Add('-EXIF:XResolution')
$lines.Add('-JFIF:XResolution')
$lines.Add('-JFIF:ResolutionUnit')
$lines.Add('-r')
$lines.Add('-ext')
$lines.Add('jpg')
$lines.Add('-ext')
$lines.Add('jpeg')
foreach ($t in $targets) { $lines.Add($t) }

[System.IO.File]::WriteAllLines($argsFile, $lines, (New-Object System.Text.UTF8Encoding $false))

Write-Host "`nrunning exiftool (read-only)..."
try {
    & $ExifTool '-charset' 'ExifTool=UTF8' '-@' $argsFile | Out-File -FilePath $AuditJson -Encoding utf8
}
finally {
    Remove-Item -LiteralPath $argsFile -ErrorAction SilentlyContinue
}

# 统计
$rows = Get-Content $AuditJson -Raw -Encoding UTF8 | ConvertFrom-Json
$n = $rows.Count
Write-Host "`n=== 命中 JFIF.unit=None 文件数: $n ==="

if ($n -eq 0) { return }

function Has($row, $key) {
    $v = $row.$key
    if (-not $v) { return $false }
    try { return ([double]$v) -gt 1 } catch { return $false }
}

$ps   = ($rows | Where-Object { Has $_ 'Photoshop:XResolution' }).Count
$exif = ($rows | Where-Object { Has $_ 'IFD0:XResolution' -or (Has $_ 'ExifIFD:XResolution') }).Count
# EXIF XRes 在 IFD0 段（-G1 下组名是 IFD0 不是 EXIF），单独探下
$exifIFD0 = ($rows | Where-Object { Has $_ 'IFD0:XResolution' }).Count
$jfif = ($rows | Where-Object { Has $_ 'JFIF:XResolution' }).Count

Write-Host ""
Write-Host "  Photoshop:XRes > 1 : $ps"
Write-Host "  IFD0:XRes      > 1 : $exifIFD0   (EXIF 在 -G1 下叫 IFD0)"
Write-Host "  JFIF:XRes      > 1 : $jfif"

# 交叉分布：每个文件三段哪些有
$buckets = @{}
foreach ($r in $rows) {
    $tags = @()
    if (Has $r 'Photoshop:XResolution') { $tags += 'PS' }
    if (Has $r 'IFD0:XResolution')      { $tags += 'EXIF' }
    if (Has $r 'JFIF:XResolution')      { $tags += 'JFIF' }
    $key = if ($tags.Count -eq 0) { '(none)' } else { ($tags -join '+') }
    if (-not $buckets.ContainsKey($key)) { $buckets[$key] = 0 }
    $buckets[$key]++
}

Write-Host "`n=== 三段交叉分布 ==="
$buckets.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object {
    "{0,-20} {1,5}" -f $_.Key, $_.Value
}

Write-Host "`n详细数据写入: $AuditJson"
