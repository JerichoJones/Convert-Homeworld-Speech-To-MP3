# Convert-HomeworldSpeechToMp3

PowerShell 7 script for extracting **Homeworld Remastered** speech audio from a `.big` archive and converting the contained FDA assets to MP3.

**Current script version:** `1.0.14`

Note: TommyJ's fda2aifc Tool is here in case it disappears from the web. The script is automated so it will attempt to download required tools for you.
---

## Overview

This script automates the Windows workflow for:

1. Locating or downloading the required helper tools
2. Decrypting the source `.big` file when needed
3. Extracting the archive with **Archive.exe** from the Homeworld Remastered Toolkit
4. Staging the extracted FDA files into a flat working set
5. Converting FDA files to WAV using **decShell.exe**
6. Converting WAV files to MP3 using **FFmpeg**
7. Producing a manifest CSV that maps the original extracted paths to staged and output filenames

---

## Scope

This script is intended for **Homeworld Remastered** speech assets such as `EnglishSpeech.big`.

It is designed to run on **Windows with PowerShell 7**.

---

## Requirements

- Windows
- PowerShell 7 or newer
- A valid Homeworld Remastered speech archive such as `EnglishSpeech.big`
- Homeworld Remastered Toolkit `Archive.exe`
  - The script can use an explicit `-ArchiveExePath`
  - If not supplied, it attempts discovery and can try to trigger toolkit installation through Steam

---

## Parameters

### Required

#### `-BigFilePath`

Path to the source `.big` file.

### Commonly used

#### `-WorkingDirectory`

Root folder for staging, extraction, logs, and tools.

#### `-OutputDirectory`

Final MP3 output folder. Defaults to `<WorkingDirectory>\mp3`.

#### `-ArchiveExePath`

Explicit path to `Archive.exe`.

#### `-Mp3BitrateKbps`

Target MP3 bitrate. Default: `96`

#### `-ForceRestage`

Rebuilds the FDA staging set and manifest.

#### `-ForceRedownload`

Redownloads tools and reruns BIG decryption.

#### `-KeepIntermediate`

Preserves intermediate staged and extracted files.

#### `-SkipMp3`

Stops after WAV generation.

#### `-SkipToolkitInstallAttempt`

Disables the automatic Steam-triggered toolkit install attempt.

---

## Example usage

### Basic

```powershell
pwsh -File .\Convert-HomeworldSpeechToMp3.ps1 `
  -BigFilePath 'D:\SteamLibrary\steamapps\common\Homeworld\HomeworldRM\Data\EnglishSpeech.big' `
  -WorkingDirectory 'C:\WorkingDir' `
  -ArchiveExePath 'D:\SteamLibrary\steamapps\common\Homeworld 347380\GBXTools\WorkshopTool\Archive.exe'
```

### Force a clean restage of FDA naming and output mapping

```powershell
pwsh -File .\Convert-HomeworldSpeechToMp3.ps1 `
  -BigFilePath 'D:\SteamLibrary\steamapps\common\Homeworld\HomeworldRM\Data\EnglishSpeech.big' `
  -WorkingDirectory 'C:\WorkingDir' `
  -ArchiveExePath 'D:\SteamLibrary\steamapps\common\Homeworld 347380\GBXTools\WorkshopTool\Archive.exe' `
  -ForceRestage
```

---

## Output

The script produces:

- MP3 files in the output directory
- A manifest CSV describing the staged and output mapping
- Intermediate extraction and conversion data under the working directory unless cleanup behavior or options preserve or remove them differently

---

## Naming and data-preservation notes

Recent work on the script focused on **preventing data loss caused by filename collisions**.

### Important design point

The output naming logic is intended to preserve **source-path context** rather than collapsing files down to short leaf-only names.

That matters because different extracted source paths may otherwise normalize to the same output filename and overwrite one another.

### Current behavior in `v1.0.13`

- The flattened output naming keeps more of the original extracted path context intact
- The stage manifest now includes a **name strategy version marker**
- If an older manifest is found from a previous naming strategy, the script rebuilds staging rather than silently reusing the outdated naming model

### What this does **not** do yet

The current script revision does **not** yet perform content-based audio dedupe.

That means:

- It is designed to avoid losing distinct source/context assets through naming collisions
- It does **not** currently hash decoded WAV or PCM content to identify true duplicate audio payloads

---

## Recommended operating guidance

If you previously ran an older revision that used unsafe or more aggressive filename normalization, use one of these approaches when testing the current revision:

- Run to a **fresh output directory**
- Manually clear the existing MP3 output directory first, then rerun with `-ForceRestage`

This helps avoid mixing older stale outputs with the current safer naming results.

---

## Known limitations

- No content-hash duplicate-audio detection yet
- No canonical duplicate report yet
- Runtime behavior depends on the availability of the external tools the script downloads or locates
- This script targets the **Homeworld Remastered** workflow specifically, not every historical Homeworld audio tool path

---

## Version notes

### `1.0.14`

Targeted fix for filename identity safety:

- Removed the parent/leaf collapse behavior from the flattened output name builder
- Preserved more full source-path context in output names
- Added a manifest naming-strategy version marker
- Forces stage rebuild when an older manifest naming strategy is detected
- fda2aifc.zip is now downloaded from the Github location.

---

## Repository contents

### Recommended minimum upload set

- `Convert-HomeworldSpeechToMp3.ps1`
- `README.md`

### Optional

- Sample manifest excerpt
- Screenshots or directory examples
- Release notes

---

## Disclaimer

This project is an automation script for local asset extraction and conversion workflows. Ensure you have the right to access and use the source game files and any produced outputs under the terms that apply to your copy of the game and your intended use.
The code works for me so I doubt I'll work on this further unless someone uncovers a problem with the MP3 file count.
