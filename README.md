# Sony WH-1000XM5 Controller for Windows

A lightweight, dependency-free Windows desktop controller for the Sony WH-1000XM5 headphones, written as a single PowerShell 5.1 script with a native WPF (Windows 11 style) UI.

![icon](icon.png)

The official Sony **Windows** app is famously missing in action — and most third-party clients were written for the XM3/XM4 generation and stopped working on the XM5 because Sony switched to a new Bluetooth SPP service UUID and a new (mdr.v2) command set. This tool speaks the XM5's protocol directly over RFCOMM.

## Features

- **Ambient Sound Control** — Noise Cancelling / Ambient Sound / Off, with a live status indicator
- **Ambient Sound level** — 0–20 slider (debounced, sent when you release)
- **Focus on Voice** — quick toggle (note: the headphones only honor this in Ambient Sound mode — same behavior as the official mobile app)
- **Speak-to-Chat on/off** — a toggle the official Windows ecosystem simply never had; the panel reads back the current state from the headphones, so what you see is what the headphones report
- **Live connection management** — auto-connect on launch, automatic init handshake with retry, graceful handling of disconnects, and an activity log

Everything is sent straight to the headphones; the panel state always mirrors what the headphones acknowledge, not a local guess.

## Requirements

- Windows 10/11
- Windows PowerShell 5.1 (`powershell.exe` — ships with Windows, no install needed)
- A Bluetooth adapter, and the headphones **paired** with the PC
- No admin rights, no dependencies, nothing to install

## Run

Double-click won't work for `.ps1` by default, so create a shortcut with this target (or run it from a terminal):

```
powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -File SonyXM5Panel.ps1
```

Tip: right-click the script → create shortcut → set the shortcut to run `powershell.exe -STA ... -File <path>` and pick an icon. `-STA` matters (WPF wants a single-threaded apartment).

## How it works

- Connects to the headphones' SPP service UUID `956C7B26-D49A-4BA8-B03F-B17D393CB6E2` (the new UUID the XM5 generation introduced) via `Windows.Devices.Bluetooth.Rfcomm` WinRT APIs.
- Performs the same initialization handshake used by open-source implementations to switch the headphones into the **mdr.v2** command set.
- Wraps commands in the Sony RFCOMM framing (`0x3E ... 0x3C` with byte-stuffing and a trailing checksum) and talks to the headphones with these payloads:

| Function | Payload (COMMAND_1) |
|---|---|
| Init handshake | `00 00` |
| Ambient Sound Control GET / SET | `66 17` / `68 17 ...` |
| Speak-to-Chat GET / SET | `F6 0C` / `F8 0C <00=on,01=off> 01` |

A background runspace keeps reading the socket (ACKing command frames as required), parses ACK / RET / NOTIFY frames and pushes state changes to the UI thread, so toggling a button on the headphones themselves updates the panel too.

## Credits & prior art

This stands on the shoulders of excellent open-source reverse-engineering work:

- [Gadgetbridge](https://codeberg.org/Freeyourgadget/Gadgetbridge) — the definitive protocol reference (Sony `SonyProtocolImplV2`, `Message` framing)
- [Plutoberth/SonyHeadphonesClient](https://github.com/Plutoberth/SonyHeadphonesClient) — the original XM3/XM4-era Windows client (archived; XM5 support never landed, see issue #77)
- [Alpakash/SonyHeadphonesClientXM5](https://github.com/Alpakash/SonyHeadphonesClientXM5) — cross-platform XM5 client

## Disclaimer

This is an unofficial, community tool. Not affiliated with or endorsed by Sony. Protocol details were learned from open-source projects and light testing; firmware updates may break things. Use at your own risk.

## Roadmap

- [ ] Equalizer (v2 command known, needs testing)
- [ ] Battery / touch-sensor notifications in the panel
- [ ] Packaging into a single `.exe`
- [ ] Other XM5-generation models (WF-1000XM5 etc.)

---

## 中文说明

这是为索尼 WH-1000XM5 写的一个 Windows 桌面控制面板：单个 PowerShell 脚本 + WPF（Win11 风格 UI），无任何依赖、不需要管理员权限。

- 环境声控制（降噪 / 环境声 / 关闭）+ 环境声等级滑条（0–20）
- 关注语音（Focus on Voice）开关（耳机只在环境声模式下接受该设置，与官方 App 行为一致）
- **智能免摘（Speak-to-Chat）开关** —— 官方 Windows 生态一直没有的功能；面板状态直接读自耳机回包
- 自动连接、init 握手自动重试、断线处理、活动日志

运行：

```
powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -File SonyXM5Panel.ps1
```

协议说明见上方英文部分（SPP UUID、mdr.v2 命令表）。灵感与协议依据来自 Gadgetbridge 与 Plutoberth/SonyHeadphonesClient 的逆向工作，在此致谢。非官方工具，与索尼公司无关，固件更新可能导致失效，使用风险自担。

## License

MIT
