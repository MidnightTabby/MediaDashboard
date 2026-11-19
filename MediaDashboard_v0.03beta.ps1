<#
.SYNOPSIS
    Fast Media & YouTube-Readiness TSV Dashboard v0.03beta (PowerShell + ffprobe/ffmpeg)
.DESCRIPTION
    Scans video archives quickly via ffprobe and outputs a clean, unquoted UTF-8 BOM TSV file
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

# Export unquoted TSV with UTF-8 BOM
$lines = New-Object System.Collections.Generic.List[string]
if ($rows.Count -gt 0) {
    $headers = @($rows[0].PSObject.Properties.Name)
    $lines.Add(($headers -join "`t"))
    foreach ($r in $rows) {
        $vals = foreach ($hName in $headers) {
            Sanitize-TsvField -Value $r.$hName
        }
        $lines.Add(($vals -join "`t"))
    }
}
else {
    $baseHeaders = @(
        "FullName","Size_MB","Duration","Camera_model","Container",
        "Resolution","FPS","V_Codec","V_Bitrate_kbps","Color_Space","HDR_Mode",
        "A_Codec","A_Bitrate_kbps","A_SampleRate",
        "YT_Ready_Mode","YT_Progressive","YT_CFR","YT_Audio_48k"
    )
    if ($AudioCheck) {
        $baseHeaders += @("Measured_dB","Peak_dB","Audio_Flag")
    }
    $lines.Add(($baseHeaders -join "`t"))
}

$utf8Bom = New-Object System.Text.UTF8Encoding($true)
[System.IO.File]::WriteAllLines($OutputTsv, $lines, $utf8Bom)
$stopwatch.Stop()

Write-Host "Completed: $($rows.Count) files exported to '$OutputTsv' in $([Math]::Round($stopwatch.Elapsed.TotalSeconds, 2))s" -ForegroundColor Green