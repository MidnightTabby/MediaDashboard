# Changelog
> Fast, Unquoted TSV/html/json Media & YouTube-Readiness Dashboard
> Scan chaotic video archives in seconds, spot unused clips before editing, and keep re-encoding specs at your fingertips.

## 📊 MediaDashboard v0.04beta - 2026-11-23 (Pre-release)
Fast PowerShell & ffprobe media dashboard outputting unquoted TSV, inline-CSS3 HTML, and JSON to audit footage specs, HDR/FPS quirks, audio levels, and YouTube readiness.

#### ✨ What's New in v0.04beta
- **Simultaneous 3-Format Export:** Generates `.tsv` (UTF-8 BOM), `.html` (inline CSS3 with summary cards & filter), and `.json` together.
- **Highlighted HDR & Resolution Views:** Easy visual scanning for 4K/8K, HDR/Dolby Vision, VFR, and `-AudioCheck` flags.

#### ⚙️ Requirements
- Windows 10 / 11 (PowerShell 5.1+ / PowerShell 7)
- `ffprobe.exe` (`ffmpeg.exe` required when using `-AudioCheck`)

*Built by MidnightTabby.*

---

## 📊 MediaDashboard v0.03beta - 2026-11-19 (Pre-release)

### ✨ What's New & Key Features
- **Optimized Re-Encode Column Order**: Arranged columns into a natural workflow (`File Info` → `Video Specs` → `Audio Specs` → `YT Readiness Flags` → `Audio Diagnostics`).
- **Device & Audio Metadata**:
  - Added `Camera_model` between `Duration` and `Container` to identify shooting devices from QuickTime/format tags.
  - Added `A_Bitrate_kbps` alongside `A_Codec` and `A_SampleRate` (streamlined by removing redundant VBR/CBR guesswork).
- **Clean, Unquoted TSV Export**: Replaced quoted CSV output with direct tab-delimited string assembly (UTF-8 with BOM), eliminating `""` clutter while sanitizing tabs/newlines safely.
- **HDR & Resolution Tiering**: Detects `DolbyVision`, `HDR10`, `HLG`, `HDR_OTHER`, and `SDR`, plus `HD_CROPPED` resolution tiering.
- **Audio Volume Diagnostics (`-AudioCheck`)**: Uses `ffmpeg` `volumedetect` to flag quiet mobile recordings (`LOW_VOL`) and clipped audio (`CLIP`).

### ⚙️ Requirements
- Windows 10 / 11 (PowerShell 7+)
- `ffprobe.exe` in the script directory (`ffmpeg.exe` required when `-AudioCheck` is passed)

*Built by MidnightTabby in the dead of night.*
