# ![Logo](Logo.png) NSudo — System Administration Toolkit

[![VirusTotal 0/61](https://img.shields.io/badge/VirusTotal-0%2F61-brightgreen?logo=virustotal)](https://www.virustotal.com/gui/file/c191f4fa0285f0786e9bfbc3c761f89b694aab54409abec9d29321d4f6459154)
[![License](https://img.shields.io/badge/license-MIT-green.svg)](License.md)

## Overview

**NSudo.cmd** is a 100% native PowerShell 5.1 / Batch polyglot that completely replaces the traditional C++ NSudo Launcher with a single, highly evasive, zero-compiled-binary `.cmd` script.

---

## Key Features

- **Zero Compiled Binaries** — No `.exe` or `.dll` files required. The entire application, including the WinForms UI and the Win32 API bridge, is packed into one file.
- **Defender-Friendly (0/61 VT)** — Designed to bypass modern AV heuristics and Sigma rules (e.g., utilizing `fltmc` for elevation checks).
- **Zero Temp-File Execution** — UAC elevation and Current Working Directory (CWD) preservation are handled entirely in-memory using Base64 encoding.
- **"Crazy Path" Immunity** — Preserves working directories containing complex Unicode or brackets `[ ]` across CMD, PowerShell, and PowerShell ISE, bypassing native Microsoft path-resolution bugs.
- **Win11 UWP Alias Bypass** — Explicitly routes commands like `notepad` to `System32\notepad.exe` to prevent `Win32 Error 2` when running under the `TrustedInstaller` identity.
- **Ghost-Window Free** — Natively executes non-PE files like `.msc` (e.g., `services.msc`) by dynamically routing them through `mmc.exe`, preventing `Win32 Error 193`.

---

## Usage

Double-click `NSudo.cmd` to open the GUI, or run it directly from the command line:

```
Format: NSudo.cmd [ Options and parameters ] Command line or ShortCut Command

Options:

  -U:[ Option ]               Create a process with a specified user option.
    T   TrustedInstaller
    S   System
    C   Current User
    E   Current User (Elevated)
    P   Current Process
    D   Current Process (Drop right)

  -P:[ Option ]               Create a process with a specified privilege option.
    E   Enable All Privileges
    D   Disable All Privileges

  -M:[ Option ]               Create a process with a specified Integrity Level.
    S   System
    H   High
    M   Medium
    L   Low

  -Priority:[ Option ]        Create a process with a specified priority.
    Idle
    BelowNormal
    Normal
    AboveNormal
    High
    RealTime

  -ShowWindowMode:[ Option ]  Create a process with a specified window mode.
    Show
    Hide
    Maximize
    Minimize

  -Wait                       Wait for the created process to exit before returning.
  -CurrentDirectory:[ Path ]  Set the working directory for the created process.
  -UseCurrentConsole          Create a process using the current console window.
  -Version                    Display NSudo version information.
  -? / -H / -Help             Show this help content.
```

---

## Technical Details

Under the hood, `NSudo.cmd` acts as an advanced C# wrapper dynamically compiled via PowerShell's `Add-Type`. It relies on direct Win32 API calls to accurately duplicate and adjust process tokens across active sessions, with no third-party dependencies:

- `CreateProcessWithTokenW`
- `DuplicateTokenEx`
- `OpenProcessToken`
- `SetTokenInformation`