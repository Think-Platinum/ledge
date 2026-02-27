# Ledge — macOS Widget Dashboard for Corsair Xeneon Edge

## Project Summary

**Ledge** is a native macOS application designed to turn a Corsair Xeneon Edge 14.5" touchscreen into a fully functional, customisable widget dashboard — filling the gap left by Corsair's Windows-only iCUE software.

On macOS, the Xeneon Edge currently works only as a plain secondary display. There is no widget system, no brightness/colour control, and touch input behaves like a normal mouse click (stealing focus from your active application). Ledge aims to solve all of these problems.

## The Problem

The Corsair Xeneon Edge is a 14.5" ultrawide touchscreen (2560×720, 60Hz, 5-point multi-touch) intended as a companion display. On Windows, Corsair's iCUE software provides:

- A widget overlay system (up to 6 configurable widgets per layout)
- System monitoring (CPU/GPU temp, fan speed, graphs)
- Media and audio controls
- Twitch chat, iFrame/web embeds, shortcuts, clocks
- Smart home integration (Nanoleaf, Philips Hue, Govee)
- Brightness, contrast, and colour profile control via USB
- Touch interaction that does **not** steal focus from your foreground application

On macOS, **none of this works**. The display functions as a bare secondary monitor. iCUE for macOS does not support the Xeneon Edge's widget features. Even basic settings like brightness require iCUE on Windows.

## How iCUE Solves the Focus Problem (Windows)

This is a critical design insight. On Windows, iCUE does **not** present widgets as standard application windows on the desktop. Instead, it renders its own interactive overlay directly onto the Xeneon Edge display. Touch input on widgets is intercepted and processed by iCUE internally, rather than being routed through Windows' standard window focus system. This is why you can tap a Spotify control widget without alt-tabbing out of a fullscreen game.

This is conceptually similar to how an Elgato Stream Deck works — the deck's software handles button presses in its own process without disturbing the foreground application.

## How Ledge Will Solve This on macOS

macOS provides a mechanism for exactly this behaviour: **`NSPanel`** with the **`.nonactivatingPanel`** style mask.

An `NSPanel` configured with `.nonactivatingPanel` can:
- Receive key and touch/mouse events
- Become the key window (for input) without becoming the main window
- Float above other content without activating the owning application
- Operate on a specific display (the Xeneon Edge)

This means a user can tap a media control widget on the Xeneon Edge and the foreground application (a game, IDE, browser) remains focused and unaffected. This is the foundational architectural decision for Ledge.

## Goals

1. **Non-intrusive widget dashboard** — Full-screen on the Xeneon Edge, no focus stealing
2. **Pluggable widget system** — First-party and third-party widgets via a plugin architecture
3. **User-configurable layouts** — Grid-based layout that users can customise (widget placement, sizing, arrangement)
4. **Touch-first interaction** — Designed for the Xeneon Edge's 5-point multi-touch
5. **USB device control** — Brightness, contrast, colour profile management via USB HID
6. **DDC/CI integration** — Standard monitor controls (brightness, contrast, volume) via DDC/CI over I²C
7. **Native macOS experience** — Swift, SwiftUI, AppKit; no Electron or web wrappers

## Non-Goals (Initial Release)

- Windows or Linux support (macOS only for now)
- Smart home integration (possible future plugin)
- Streaming/OBS integration (possible future plugin)
- App Store distribution (will distribute outside the store initially to avoid sandboxing constraints on USB/HID access)

## Hardware Reference

| Spec | Value |
|------|-------|
| Display | 14.5" AHVA LCD |
| Resolution | 2560 × 720 (roughly 32:9) |
| Refresh Rate | 60Hz |
| Touch | 5-point capacitive multi-touch |
| Connectivity | USB-C (DP Alt Mode + data), HDMI |
| USB Vendor ID | 0x1B1C (Corsair) |
| USB Product ID | TBD (needs identification via `lsusb` or IOKit) |
| Peak Brightness | 350 cd/m² |

## Key Research Sources

- [Corsair iCUE Xeneon Edge Widget Guide](https://www.corsair.com/us/en/explorer/gamer/monitors/how-to-set-up-xeneon-monitor-widgets-in-icue-nexus/)
- [Apple NSPanel Documentation](https://developer.apple.com/documentation/appkit/nspanel)
- [NSPanel nonactivatingPanel Style Mask](https://developer.apple.com/documentation/appkit/nswindow/stylemask-swift.struct/nonactivatingpanel)
- [NSPanel Nonactivating Bug Analysis](https://philz.blog/nspanel-nonactivating-style-mask-flag/)
- [OpenLinkHub Xeneon Edge Feature Request](https://github.com/jurkovic-nikola/OpenLinkHub/issues/56)
- [MonitorControl (DDC/CI on macOS)](https://github.com/MonitorControl/MonitorControl)
- [DDC on Apple Silicon — The Journey](https://alinpanaitiu.com/blog/journey-to-ddc-on-m1-macs/)
- [HIDAPI Library](https://github.com/libusb/hidapi)
