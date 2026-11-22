<#
.SYNOPSIS
    Fast Media & YouTube-Readiness Dashboard v0.04beta (PowerShell + ffprobe/ffmpeg)
.DESCRIPTION
    Scans video archives quickly via ffprobe and exports 3 formats simultaneously
    (unquoted UTF-8 BOM TSV, self-contained HTML with inline CSS3, and JSON)
    with a practical column order for media review, sorting, and re-encoding reference.
    Includes Camera_model, audio bitrate/sample rate, resolution tiering (with HD_CROPPED),
    CFR/Progressive/48kHz checks, and Color Space / HDR (Dolby Vision, HDR10, HLG, SDR) detection.
    Pass -AudioCheck to append audio diagnostics (CLIP / LOW_VOL) on the right.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$TargetPath = ".",

    [Parameter(Mandatory = $false)]
    [string]$OutputTsv = ".\media_dashboard.tsv",

    [Parameter(Mandatory = $false)]
    [switch]$AudioCheck,

    # Audio flag thresholds (tunable)
    [double]$LowVolThresholdDb = -24.0,
    [double]$ClipPeakThresholdDb = -0.1
)

$OutputEncoding = [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding

if (-not (Get-Command .\ffprobe -ErrorAction SilentlyContinue)) {
    Write-Error "ffprobe not found in current path (.\ffprobe)."
    exit 1
}
if ($AudioCheck -and -not (Get-Command .\ffmpeg -ErrorAction SilentlyContinue)) {
    Write-Error "ffmpeg not found in current path (.\ffmpeg, required when -AudioCheck is enabled)."
    exit 1
}

$videoExts = @(".mp4", ".mov", ".mkv", ".webm", ".avi", ".m4v", ".3gp", ".mpg", ".mpeg", ".ts")

function Sanitize-TsvField {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return "" }
    $str = [string]$Value
    $str = $str -replace "[\r\n\t]+", " "
    return $str.Trim()
}

function ConvertTo-HtmlSafe {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return "" }
    return [System.Net.WebUtility]::HtmlEncode([string]$Value)
}

function Parse-RationalFps {
    param([string]$RateStr)
    if ([string]::IsNullOrWhiteSpace($RateStr) -or $RateStr -eq "0/0") { return 0.0 }
    if ($RateStr -match "^(\d+)/(\d+)$") {
        $den = [double]$matches[2]
        if ($den -ne 0) {
            return [Math]::Round(([double]$matches[1] / $den), 2)
        }
    }
    $num = 0.0
    if ([double]::TryParse($RateStr, [ref]$num)) { return [Math]::Round($num, 2) }
    return 0.0
}

function Get-CameraModel {
    param(
        $FormatObj,
        $VideoStream
    )

    $candidates = @()

    foreach ($tags in @($VideoStream.tags, $FormatObj.tags)) {
        if ($null -eq $tags) { continue }
        foreach ($prop in $tags.PSObject.Properties) {
            $nameLower = $prop.Name.ToLower()
            if ($nameLower -match "model|device|camera") {
                if (-not [string]::IsNullOrWhiteSpace([string]$prop.Value)) {
                    $candidates += [string]$prop.Value
                }
            }
        }
    }

    if ($candidates.Count -gt 0) {
        return ($candidates[0] -replace "[\r\n\t]+", " ").Trim()
    }
    return ""
}

function Get-YtReadyMode {
    param(
        [int]$Width,
        [int]$Height
    )
    if ($Width -le 0 -or $Height -le 0) { return "UNKNOWN" }

    $pixels = [double]$Width * [double]$Height
    $dar = [double]$Width / [double]$Height
    $isNear16x9 = ([Math]::Abs($dar - (16.0 / 9.0)) -le 0.08)
    $isNear9x16 = ([Math]::Abs($dar - (9.0 / 16.0)) -le 0.08)

    if ($Height -ge 4320 -or $Width -ge 7680) { return "8K" }
    if ($Height -ge 2160 -or $Width -ge 3840) { return "4K" }

    # 1080p tier: standard 1920x1080 (or vertical 1080x1920)
    if (($Width -ge 1920 -and $Height -ge 1080) -or ($Width -ge 1080 -and $Height -ge 1920)) {
        return "1080p"
    }

    # Standard HD (720p tier) vs non-16:9 / 1440x1080
    if ($Height -ge 720 -and $Width -ge 1280) {
        if ($isNear16x9 -or $isNear9x16) { return "HD" }
        return "HD_CROPPED"
    }

    # Cropped / trimmed HD-usable media (e.g., 1280x504 or high-detail trim)
    if ($pixels -ge 600000 -and ($Width -ge 1000 -or $Height -ge 700)) {
        return "HD_CROPPED"
    }

    return "SD"
}

function Get-ColorInfo {
    param($VideoStream)

    if (-not $VideoStream) {
        return [PSCustomObject]@{
            Color_Space = ""
            HDR_Mode    = ""
        }
    }

    $cSpace     = if ($VideoStream.color_space)     { [string]$VideoStream.color_space }     else { "" }
    $cTransfer  = if ($VideoStream.color_transfer)  { [string]$VideoStream.color_transfer }  else { "" }
    $cPrimaries = if ($VideoStream.color_primaries) { [string]$VideoStream.color_primaries } else { "" }

    $hasDovi = $false
    if ($VideoStream.side_data_list) {
        $hasDovi = [bool]($VideoStream.side_data_list | Where-Object {
            $_.side_data_type -match "Dolby Vision|DOVI"
        })
    }

    $hdrMode = if ($hasDovi) {
        "DolbyVision"
    } elseif ($cTransfer -eq "smpte2084") {
        "HDR10"
    } elseif ($cTransfer -eq "arib-std-b67") {
        "HLG"
    } elseif ($cSpace -eq "bt2020nc" -or $cPrimaries -eq "bt2020") {
        "HDR_OTHER"
    } else {
        "SDR"
    }

    $displaySpace = if ($cSpace) { $cSpace } elseif ($cPrimaries) { $cPrimaries } else { "unknown" }

    return [PSCustomObject]@{
        Color_Space = $displaySpace
        HDR_Mode    = $hdrMode
    }
}

function Get-AudioLevels {
    param([string]$FilePath)

    $raw = & .\ffmpeg -hide_banner -nostats -i $FilePath -vn -af "volumedetect" -f null NUL 2>&1 | Out-String

    $meanDb = $null
    $maxDb  = $null

    if ($raw -match "mean_volume:\s*([-\d\.]+)\s*dB") {
        $meanDb = [double]$matches[1]
    }
    if ($raw -match "max_volume:\s*([-\d\.]+)\s*dB") {
        $maxDb = [double]$matches[1]
    }

    $flags = @()
    if ($null -ne $maxDb -and $maxDb -ge $ClipPeakThresholdDb) {
        $flags += "CLIP"
    }
    if ($null -ne $meanDb -and $meanDb -le $LowVolThresholdDb) {
        $flags += "LOW_VOL"
    }

    return [PSCustomObject]@{
        Measured_dB = if ($null -ne $meanDb) { [Math]::Round($meanDb, 1) } else { "" }
        Peak_dB     = if ($null -ne $maxDb)  { [Math]::Round($maxDb, 1) }  else { "" }
        Audio_Flag  = ($flags -join ",")
    }
}

function Export-DashboardReports {
    param(
        [Parameter(Mandatory = $true)]
        [array]$Rows,
        [Parameter(Mandatory = $true)]
        [string]$BaseOutputPath,
        [Parameter(Mandatory = $true)]
        [string]$ScannedTarget,
        [Parameter(Mandatory = $true)]
        [bool]$HasAudioCheck,
        [Parameter(Mandatory = $true)]
        [double]$ElapsedSeconds,
        [Parameter(Mandatory = $true)]
        [string[]]$DefaultHeaders
    )

    $fullPath = [System.IO.Path]::GetFullPath($BaseOutputPath)
    $outDir   = [System.IO.Path]::GetDirectoryName($fullPath)
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($fullPath)

    if (-not [string]::IsNullOrWhiteSpace($outDir) -and -not (Test-Path -LiteralPath $outDir)) {
        New-Item -ItemType Directory -Path $outDir -Force | Out-Null
    }

    $tsvPath  = Join-Path $outDir "$baseName.tsv"
    $htmlPath = Join-Path $outDir "$baseName.html"
    $jsonPath = Join-Path $outDir "$baseName.json"

    $headers = if ($Rows.Count -gt 0) { @($Rows[0].PSObject.Properties.Name) } else { $DefaultHeaders }

    # 1. Export unquoted TSV with UTF-8 BOM
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add(($headers -join "`t"))
    foreach ($r in $Rows) {
        $vals = foreach ($hName in $headers) {
            Sanitize-TsvField -Value $r.$hName
        }
        $lines.Add(($vals -join "`t"))
    }
    $utf8Bom = New-Object System.Text.UTF8Encoding($true)
    [System.IO.File]::WriteAllLines($tsvPath, $lines, $utf8Bom)

    # 2. Export JSON with UTF-8 (no BOM)
    $hdrCount = ($Rows | Where-Object { $_.HDR_Mode -and $_.HDR_Mode -ne "SDR" }).Count
    $vfrCount = ($Rows | Where-Object { $_.YT_CFR -eq $false }).Count
    $flagCount = if ($HasAudioCheck) {
        ($Rows | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.Audio_Flag) }).Count
    } else {
        0
    }

    $jsonPayload = [PSCustomObject]@{
        tool            = "MediaDashboard"
        version         = "v0.04beta"
        generated_at    = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        target_path     = $ScannedTarget
        audio_check     = $HasAudioCheck
        elapsed_seconds = $ElapsedSeconds
        summary         = [PSCustomObject]@{
            total_files      = $Rows.Count
            hdr_or_wide_hdr  = $hdrCount
            vfr_or_non_cfr   = $vfrCount
            audio_flagged    = $flagCount
        }
        items           = $Rows
    }
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($jsonPath, ($jsonPayload | ConvertTo-Json -Depth 6), $utf8NoBom)

    # 3. Export self-contained HTML with inline CSS3 and UTF-8 (no BOM)
    $thBuilder = New-Object System.Text.StringBuilder
    foreach ($hName in $headers) {
        [void]$thBuilder.Append("<th>$(ConvertTo-HtmlSafe $hName)</th>")
    }

    $tbodyBuilder = New-Object System.Text.StringBuilder
    foreach ($r in $Rows) {
        [void]$tbodyBuilder.AppendLine("        <tr>")
        foreach ($hName in $headers) {
            $cellVal = $r.$hName
            $cellStr = if ($null -eq $cellVal) { "" } else { [string]$cellVal }
            $safeStr = ConvertTo-HtmlSafe $cellStr

            if ($hName -eq "HDR_Mode" -and $cellStr -ne "" -and $cellStr -ne "SDR") {
                [void]$tbodyBuilder.Append("<td><span class='badge badge-hdr'>$safeStr</span></td>")
            } elseif ($hName -eq "Audio_Flag" -and $cellStr -ne "") {
                [void]$tbodyBuilder.Append("<td><span class='badge badge-warn'>$safeStr</span></td>")
            } elseif ($hName -eq "YT_Ready_Mode" -and ($cellStr -eq "4K" -or $cellStr -eq "8K" -or $cellStr -eq "1080p")) {
                [void]$tbodyBuilder.Append("<td><span class='badge badge-ok'>$safeStr</span></td>")
            } else {
                [void]$tbodyBuilder.Append("<td>$safeStr</td>")
            }
        }
        [void]$tbodyBuilder.AppendLine("        </tr>")
    }

    $htmlContent = @"
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>MediaDashboard v0.04beta Report</title>
  <style>
    :root {
      --bg: #f4f6f9;
      --surface: #ffffff;
      --surface-alt: #eef2f6;
      --text: #18202c;
      --muted: #5c6878;
      --border: #d5dde7;
      --accent: #0f62fe;
      --ok-bg: #defbe6;
      --ok-fg: #0e6027;
      --hdr-bg: #e8daff;
      --hdr-fg: #491d8b;
      --warn-bg: #fff1c2;
      --warn-fg: #7a4900;
      --shadow: 0 6px 20px rgba(24, 32, 44, 0.06);
    }
    @media (prefers-color-scheme: dark) {
      :root {
        --bg: #0b0f17;
        --surface: #131a26;
        --surface-alt: #1a2434;
        --text: #e6edf7;
        --muted: #8b9bb4;
        --border: #263347;
        --accent: #58a6ff;
        --ok-bg: rgba(46, 160, 67, 0.22);
        --ok-fg: #56d364;
        --hdr-bg: rgba(163, 113, 247, 0.22);
        --hdr-fg: #d2a8ff;
        --warn-bg: rgba(210, 153, 34, 0.24);
        --warn-fg: #f2cc60;
        --shadow: 0 10px 28px rgba(0, 0, 0, 0.4);
      }
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      padding: 24px;
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Noto Sans JP", sans-serif;
      background: linear-gradient(160deg, var(--bg) 0%, var(--surface-alt) 100%);
      color: var(--text);
      line-height: 1.45;
    }
    .container {
      max-width: 1520px;
      margin: 0 auto;
    }
    .header {
      display: flex;
      flex-wrap: wrap;
      justify-content: space-between;
      align-items: flex-end;
      gap: 12px;
      padding: 18px 22px;
      background: var(--surface);
      border: 1px solid var(--border);
      border-radius: 12px;
      box-shadow: var(--shadow);
      margin-bottom: 16px;
    }
    .header h1 {
      margin: 0 0 4px 0;
      font-size: 1.3rem;
      color: var(--accent);
    }
    .meta {
      font-size: 0.85rem;
      color: var(--muted);
      word-break: break-all;
    }
    .cards {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(170px, 1fr));
      gap: 12px;
      margin-bottom: 16px;
    }
    .card {
      background: var(--surface);
      border: 1px solid var(--border);
      border-radius: 12px;
      padding: 14px 16px;
      box-shadow: var(--shadow);
      transition: transform 0.15s ease, border-color 0.15s ease;
    }
    .card:hover {
      transform: translateY(-2px);
      border-color: var(--accent);
    }
    .card .label {
      font-size: 0.76rem;
      text-transform: uppercase;
      letter-spacing: 0.05em;
      color: var(--muted);
    }
    .card .value {
      font-size: 1.55rem;
      font-weight: 700;
      margin-top: 4px;
    }
    .controls {
      margin-bottom: 14px;
    }
    .search {
      width: 100%;
      max-width: 460px;
      padding: 10px 14px;
      font-size: 0.9rem;
      color: var(--text);
      background: var(--surface);
      border: 1px solid var(--border);
      border-radius: 8px;
      outline: none;
    }
    .search:focus {
      border-color: var(--accent);
      box-shadow: 0 0 0 3px rgba(88, 166, 255, 0.2);
    }
    .table-wrap {
      background: var(--surface);
      border: 1px solid var(--border);
      border-radius: 12px;
      box-shadow: var(--shadow);
      overflow: auto;
      max-height: 72vh;
    }
    table {
      width: 100%;
      border-collapse: collapse;
      font-size: 0.84rem;
    }
    th, td {
      padding: 8px 12px;
      border-bottom: 1px solid var(--border);
      text-align: left;
      white-space: nowrap;
    }
    th {
      position: sticky;
      top: 0;
      z-index: 1;
      background: var(--surface-alt);
      font-weight: 600;
    }
    tbody tr:nth-child(even) {
      background: rgba(127, 127, 127, 0.03);
    }
    tbody tr:hover {
      background: rgba(88, 166, 255, 0.1);
    }
    .badge {
      display: inline-block;
      padding: 2px 8px;
      border-radius: 999px;
      font-size: 0.75rem;
      font-weight: 600;
    }
    .badge-ok  { background: var(--ok-bg);  color: var(--ok-fg); }
    .badge-hdr { background: var(--hdr-bg); color: var(--hdr-fg); }
    .badge-warn{ background: var(--warn-bg);color: var(--warn-fg); }
  </style>
</head>
<body>
  <div class="container">
    <div class="header">
      <div>
        <h1>MediaDashboard v0.04beta</h1>
        <div class="meta">Target: $(ConvertTo-HtmlSafe $ScannedTarget)</div>
      </div>
      <div class="meta">Elapsed: ${ElapsedSeconds}s | AudioCheck: $HasAudioCheck | Generated: $((Get-Date).ToString("yyyy-MM-dd HH:mm:ss"))</div>
    </div>

    <div class="cards">
      <div class="card"><div class="label">Total Clips</div><div class="value">$($Rows.Count)</div></div>
      <div class="card"><div class="label">HDR / Wide</div><div class="value">$hdrCount</div></div>
      <div class="card"><div class="label">Non-CFR / VFR</div><div class="value">$vfrCount</div></div>
      <div class="card"><div class="label">Audio Flags</div><div class="value">$flagCount</div></div>
    </div>

    <div class="controls">
      <input id="filterInput" class="search" type="search" placeholder="Filter by filename, camera, codec, HDR, or flag..." oninput="filterDashboard()" />
    </div>

    <div class="table-wrap">
      <table id="dashboardTable">
        <thead>
          <tr>$($thBuilder.ToString())</tr>
        </thead>
        <tbody>
$($tbodyBuilder.ToString())
        </tbody>
      </table>
    </div>
  </div>

  <script>
    function filterDashboard() {
      const q = document.getElementById('filterInput').value.trim().toLowerCase();
      const rows = document.querySelectorAll('#dashboardTable tbody tr');
      rows.forEach(tr => {
        if (!q) {
          tr.style.display = '';
          return;
        }
        const match = tr.textContent.toLowerCase().includes(q);
        tr.style.display = match ? '' : 'none';
      });
    }
  </script>
</body>
</html>
"@
    [System.IO.File]::WriteAllText($htmlPath, $htmlContent, $utf8NoBom)

    return [PSCustomObject]@{
        TsvPath  = $tsvPath
        HtmlPath = $htmlPath
        JsonPath = $jsonPath
    }
}

$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$files = Get-ChildItem -Path $TargetPath -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $videoExts -contains $_.Extension.ToLower() }

$rows = New-Object System.Collections.Generic.List[PSObject]
$total = $files.Count
$index = 0

foreach ($file in $files) {
    $index++
    if ($AudioCheck -and $total -gt 0) {
        Write-Progress -Activity "Scanning Media (AudioCheck ON)" -Status "[$index / $total] $($file.Name)" -PercentComplete (($index / $total) * 100)
    }

    $probeJson = & .\ffprobe -v error -print_format json -show_format -show_streams $file.FullName 2>$null
    if (-not $probeJson) { continue }

    $probe = $probeJson | ConvertFrom-Json
    $vStream = $probe.streams | Where-Object { $_.codec_type -eq "video" } | Select-Object -First 1
    $aStream = $probe.streams | Where-Object { $_.codec_type -eq "audio" } | Select-Object -First 1

    $w = if ($vStream -and $vStream.width)  { [int]$vStream.width }  else { 0 }
    $h = if ($vStream -and $vStream.height) { [int]$vStream.height } else { 0 }

    $rFps   = if ($vStream) { Parse-RationalFps $vStream.r_frame_rate }   else { 0.0 }
    $avgFps = if ($vStream) { Parse-RationalFps $vStream.avg_frame_rate } else { 0.0 }

    $isCfr = if ($rFps -gt 0 -and $avgFps -gt 0) {
        ([Math]::Abs($rFps - $avgFps) -le 0.15)
    } else {
        $false
    }

    $fieldOrder = if ($vStream -and $vStream.field_order) { $vStream.field_order.ToLower() } else { "" }
    $isProgressive = ($fieldOrder -eq "progressive" -or $fieldOrder -eq "" -or $fieldOrder -eq "unknown")

    $sampleRate = if ($aStream -and $aStream.sample_rate) { [int]$aStream.sample_rate } else { 0 }
    $isAudio48k = ($sampleRate -eq 48000)

    $aBitrateKbps = if ($aStream -and $aStream.bit_rate) {
        [Math]::Round(([double]$aStream.bit_rate / 1000.0), 0)
    } else {
        0
    }

    $durationSec = 0.0
    if ($probe.format -and $probe.format.duration) {
        [double]::TryParse($probe.format.duration, [ref]$durationSec) | Out-Null
    }
    $durationStr = if ($durationSec -gt 0) {
        [TimeSpan]::FromSeconds($durationSec).ToString("hh\:mm\:ss")
    } else {
        "00:00:00"
    }

    $vBitrateKbps = if ($vStream -and $vStream.bit_rate) {
        [Math]::Round(([double]$vStream.bit_rate / 1000.0), 0)
    } elseif ($probe.format -and $probe.format.bit_rate) {
        [Math]::Round(([double]$probe.format.bit_rate / 1000.0), 0)
    } else {
        0
    }

    $cameraModel = Get-CameraModel -FormatObj $probe.format -VideoStream $vStream
    $colorInfo   = Get-ColorInfo -VideoStream $vStream

    $obj = [ordered]@{
        FullName       = $file.FullName
        Size_MB        = [Math]::Round(($file.Length / 1MB), 2)
        Duration       = $durationStr
        Camera_model   = $cameraModel
        Container      = $file.Extension.TrimStart(".").ToLower()
        Resolution     = if ($w -gt 0 -and $h -gt 0) { "${w}x${h}" } else { "" }
        FPS            = if ($avgFps -gt 0) { $avgFps } else { $rFps }
        V_Codec        = if ($vStream) { $vStream.codec_name } else { "" }
        V_Bitrate_kbps = $vBitrateKbps
        Color_Space    = $colorInfo.Color_Space
        HDR_Mode       = $colorInfo.HDR_Mode
        A_Codec        = if ($aStream) { $aStream.codec_name } else { "" }
        A_Bitrate_kbps = $aBitrateKbps
        A_SampleRate   = $sampleRate
        YT_Ready_Mode  = Get-YtReadyMode -Width $w -Height $h
        YT_Progressive = $isProgressive
        YT_CFR         = $isCfr
        YT_Audio_48k   = $isAudio48k
    }

    if ($AudioCheck) {
        if ($aStream) {
            $aud = Get-AudioLevels -FilePath $file.FullName
            $obj["Measured_dB"] = $aud.Measured_dB
            $obj["Peak_dB"]     = $aud.Peak_dB
            $obj["Audio_Flag"]  = $aud.Audio_Flag
        } else {
            $obj["Measured_dB"] = ""
            $obj["Peak_dB"]     = ""
            $obj["Audio_Flag"]  = ""
        }
    }

    $rows.Add([PSCustomObject]$obj) | Out-Null
}

if ($AudioCheck) {
    Write-Progress -Activity "Scanning Media (AudioCheck ON)" -Completed
}

$stopwatch.Stop()
$elapsedSec = [Math]::Round($stopwatch.Elapsed.TotalSeconds, 2)

$defaultHeaders = @(
    "FullName","Size_MB","Duration","Camera_model","Container",
    "Resolution","FPS","V_Codec","V_Bitrate_kbps","Color_Space","HDR_Mode",
    "A_Codec","A_Bitrate_kbps","A_SampleRate",
    "YT_Ready_Mode","YT_Progressive","YT_CFR","YT_Audio_48k"
)
if ($AudioCheck) {
    $defaultHeaders += @("Measured_dB","Peak_dB","Audio_Flag")
}

$exported = Export-DashboardReports `
    -Rows $rows.ToArray() `
    -BaseOutputPath $OutputTsv `
    -ScannedTarget $TargetPath `
    -HasAudioCheck ([bool]$AudioCheck) `
    -ElapsedSeconds $elapsedSec `
    -DefaultHeaders $defaultHeaders

Write-Host "Completed: $($rows.Count) files scanned in ${elapsedSec}s" -ForegroundColor Green
Write-Host "  TSV  : $($exported.TsvPath)"  -ForegroundColor Cyan
Write-Host "  HTML : $($exported.HtmlPath)" -ForegroundColor Cyan
Write-Host "  JSON : $($exported.JsonPath)" -ForegroundColor Cyan