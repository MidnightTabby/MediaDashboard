# 📊 MediaDashboard_v0.03beta

> **"Why is this 12-second phone clip 400MB and why can't anyone hear me?!"**  
> A fast, zero-bloat PowerShell + `ffprobe`/`ffmpeg` scanner that turns your chaotic video folder into a clean, human-readable TSV dashboard.  
> Built by **MidnightTabby** in the dead of night—engineered for Gen-Z creators, students, and digital packrats who want order without opening 500 files one by one.

---

## 🚀 Why This Exists

If your camera roll, external SSD, or project folder is an absolute graveyard of mystery `.mp4` and `.mov` clips, you know the struggle:
- You have **gigabytes of footage you'll never actually use**, buried because you don't have time to watch every single clip.
- Some clips are secretly **Dolby Vision / HDR10** (ready to blow out your timeline colors).
- Mobile recordings are constantly whispering at **-30 dB (`LOW_VOL`)**, forcing you to guess gain settings in post.
- You just want to **re-encode or match export specs** without decoding cryptic `ffprobe` walls of text.

**MediaDashboard** scans your archive in seconds and outputs a clean, **unquoted UTF-8 TSV** file ready for Excel, Google Sheets, or CLI filtering—helping you spot trash clips to delete and prep the keepers for editing.
**"Stop guessing why that 4K clip feels heavy—audit your entire media stash in one clean TSV."**  
A fast PowerShell media triage & quality dashboard powered by `ffprobe` (and optional `ffmpeg` audio loudness checks) to help creators declutter raw footage, spot HDR/VFR quirks, and prep exports without opening 40 tabs.

Companion to [**MediaTimestampFixer**](https://github.com/MidnightTabby/MediaTimestampFixer). Keep your timestamps straight with one, and inspect your footage specs and audio levels with the other.
---

## ✨ Key Features

- **⚡ Blazing-Fast Metadata Scan (`ffprobe`)**: Extracts resolution, FPS, codecs, video/audio bitrates, color space, and camera models across entire directory trees without touching your original files (**100% non-destructive**).
- **🧹 Spot Unused & Low-Value Footage Instantly**: Sort by `Size_MB`, `Duration`, or `YT_Ready_Mode` (`8K`, `4K`, `1080p`, `HD`, `HD_CROPPED`, `SD`) to catch accidental pocket recordings, low-res scraps, and storage hogs before editing.
- **🌈 HDR & Color Space Decoder**: Translates cryptic transfer characteristics into plain labels (`DolbyVision`, `HDR10`, `HLG`, `HDR_OTHER`, `SDR`) alongside raw `Color_Space` values.
- **🎛️ Re-Encode Reference Layout**: Columns are ordered logically (`File Info` → `Video Specs` → `Audio Specs` → `YT Flags`) so you have exact bitrates, sample rates, and codecs right next to each other.
- **🔊 Optional Audio Diagnostics (`-AudioCheck`)**: Runs `ffmpeg` `volumedetect` to flag quiet mobile footage (`LOW_VOL`) or clipped audio (`CLIP`) with measured mean/peak dB levels.
- **📄 Clean, Unquoted TSV Output**: Exported with UTF-8 BOM and zero annoying double-quotes (`""`) for effortless spreadsheet pasting and text parsing.

---

## 📋 Dashboard Columns Explained

| Group | Columns | What It Tells You |
| :--- | :--- | :--- |
| **File & Device** | `FullName`, `Size_MB`, `Duration`, `Camera_model`, `Container` | Where it lives, how heavy/long it is, and what shot it (e.g., iPhone model tags). |
| **Video Specs** | `Resolution`, `FPS`, `V_Codec`, `V_Bitrate_kbps`, `Color_Space`, `HDR_Mode` | Exact specs for matching re-encodes + instant HDR warning labels. |
| **Audio Specs** | `A_Codec`, `A_Bitrate_kbps`, `A_SampleRate` | Clean audio specs without redundant VBR/CBR guesswork. |
| **YT Readiness** | `YT_Ready_Mode`, `YT_Progressive`, `YT_CFR`, `YT_Audio_48k` | Quick sanity checks for frame-rate stability (CFR), progressive scan, and 48kHz audio. |
| **Audio Check*** | `Measured_dB`, `Peak_dB`, `Audio_Flag` | *(Appended when `-AudioCheck` is enabled)* Flags `LOW_VOL` or `CLIP`. |

---

## ⚡ Quick Start & Usage

### 1. Prerequisites
- **Windows 10 / 11** (PowerShell 7 recommended / Windows PowerShell 5.1+)
- **`ffprobe.exe` (Required)** & **`ffmpeg.exe` (Required only with `-AudioCheck`)**:  
  Official FFmpeg builds for Windows x64 are distributed via trusted community builds:
  - **Gyan.dev** ([Windows builds](https://www.gyan.dev/ffmpeg/builds/#release-builds)): Download **`ffmpeg-release-essentials.zip`** (lighter and plenty for `MediaDashboard`—includes `ffmpeg.exe`, `ffprobe.exe`, and `ffplay.exe` in folder named `bin`).
  - **BtbN** ([FFmpeg-Builds Releases](https://github.com/BtbN/FFmpeg-Builds/releases)): Download the latest **`win64-gpl`** `.zip` archive if you prefer GitHub releases.
  - Extract `bin\ffprobe.exe` (and `bin\ffmpeg.exe` if you plan to use `-AudioCheck`) into a folder included in your **System PATH**, or place them alongside the script.

### 2. Folder Structure
Keep your workspace tidy—put the script in your project/toolkit folder (and `ffprobe.exe` / `ffmpeg.exe` either on your `PATH` or right next to it):

```text
📁 MediaDashboard/
 ├── 📜 MediaDashboard_v0.03beta.ps1
 ├── ⚙️ ffprobe.exe          # Optional if already in System PATH
 └── ⚙️ ffmpeg.exe           # Optional (only needed with -AudioCheck)
 ```

### 3. Run the Scanner
Open PowerShell in your folder and run:

#### Fast scan (everyday triage—resolution, HDR, FPS, YouTube flags)[cite: 2]:
```powershell
.\MediaDashboard_v0.03beta.ps1 -TargetPath "D:\Videos\Chaos_Archive" -OutputTsv ".\media_dashboard.tsv"
```

#### Audio check mode (adds Measured_dB, Peak_dB, and Audio_Flag)[cite: 1, 2]:
```powershell
.\MediaDashboard_v0.03beta.ps1 -TargetPath "D:\Videos\Chaos_Archive" -OutputTsv ".\media_dashboard.tsv" -AudioCheck
```

#### Optional Parameters
- `-LowVolThresholdDb` (Default: `-24.0`): Adjust sensitivity for `LOW_VOL` flags.
- `-ClipPeakThresholdDb` (Default: `-0.1`): Adjust peak threshold for `CLIP` warnings.

### 4. Open the generated .tsv in Excel, Google Sheets, or your favorite viewer to filter, sort, and make quick storage/edit calls.

---

## 🗺️ Roadmap (Coming Soon)
- **Suggested Gain Hints**: Pair `LOW_VOL` with estimated boost hints (e.g., `+12dB` headroom guide) while keeping `Peak_dB` in check.
- **Flexible Date Formatting**: Keep ISO default sorting while offering optional US-friendly date formats (`MM/dd/yyyy`, casual `WED Sept 21 6p` style notes).
- **Cross-Platform / Lightweight Helper**: Exploring standalone Go helpers for zero-dependency portability across Windows, macOS, and Chromebook (Linux).

---

## ☕ Credits & Behind the Scenes
- **FFmpeg / ffprobe Team**: For powering practically every media pipeline on planet Earth.
- **Author**: **MidnightTabby** — fueled by late-night coffee and an urge to bring *Aesthetic peacekeeping* to messy hard drives.
- **AI Collaborator**: **Gemini** — helping translate late-night workflow ideas and real-world creator headaches into clean PowerShell.

---

## 💡 Pro Tips & Shortcuts

- **CLI / `winget` shortcut**: Prefer installing via terminal? Run `winget install --id=Gyan.FFmpeg -e` in PowerShell, then restart your terminal so `PATH` updates pick up `ffprobe.exe` and `ffmpeg.exe`.

- **`essentials` vs. `full`**: `MediaDashboard` only needs `ffprobe` and `ffmpeg` (volumedetect), so `release essentials` saves bandwidth and disk space without sacrificing functionality.

- **Test small first**: Point `-TargetPath` at a single folder of mixed clips before scanning a massive multi-terabyte archive.
