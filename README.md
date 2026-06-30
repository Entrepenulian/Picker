<div align="center">

# Picker

**A native macOS menu-bar color *and font* picker with Liquid Glass.**

Grab any pixel on screen as HEX / RGB / HSL — or click any text in any app to grab its font — and keep a palette and a font list of everything you've sampled.

![macOS 26+](https://img.shields.io/badge/macOS-26%2B-black?logo=apple)
![Swift 6.2](https://img.shields.io/badge/Swift-6.2-orange?logo=swift)
![License: MIT](https://img.shields.io/badge/License-MIT-blue)

<br>

<img src="assets/filled-state.png" height="330" alt="Picker showing a sampled color with HEX, RGB and HSL plus a saved palette">
&nbsp;&nbsp;
<img src="assets/fonts-state.png" height="330" alt="Picker's Fonts section showing a grabbed font's specimen and saved fonts">

<br><br>

<img src="assets/grab-font.png" width="600" alt="Grab Font in action: the overlay highlights a heading on a web page and reads its family, weight, and size">

<sub><i>Grab Font reading a heading straight off a web page — family, weight, and size.</i></sub>

</div>

---

## What it does

Picker lives in your menu bar. Click it and you get two tools behind one glass panel:

- **Colors** — hit **Pick a Color** and your cursor becomes a magnified loupe. Line up the exact pixel anywhere on screen and click; the color drops in as HEX / RGB / HSL, ready to copy and saved to your palette.
- **Fonts** — hit **Grab Font** and your cursor becomes a text picker. Hover any text in **Safari**, another app, or a dropdown — a crosshair highlights the exact run and reads its family and size — then click to keep it. The card shows a live specimen **in the font's real typeface** (downloading it if you don't already have it), and **Find** takes you to the font's source. A saved-fonts strip lets you flip between everything you've grabbed.

A sliding pill switches between the two; nothing else moves.

## Features

- **Magnified-pixel sampling** — the native loupe magnifies the screen pixel-by-pixel, so you grab the exact one every time.
- **Grab any font, anywhere** — a click-through overlay reads the text *under* your cursor through the accessibility tree, so it works on web pages (Safari/WebKit), native apps, and even items in an already-open dropdown — highlighting the actual text run, never a surrounding box.
- **Liquid Glass** — a real macOS 26 glass panel, not a mockup.
- **HEX · RGB · HSL** — every color format at once; click a value to copy it and the icon flips to a checkmark.
- **Real-typeface specimen** — every grabbed font renders in its *actual* face. If you don't have it installed, Picker fetches and registers it on the fly from the open-font catalog (Google Fonts, then Fontsource), so the preview is the real thing — even for variable fonts that hide behind an odd internal name. Faces you can't legally download fall back to a system preview.
- **Find any font** — the **Find** link deep-links to a font's Google Fonts page when it's free, and otherwise opens a web search for the family name in Safari — so it locates commercial, foundry, and self-hosted fonts too, not just Google's catalog.
- **Saved palette & font list** — running strips of everything you've grabbed. Click to copy, hover to delete, scroll the row with your mouse wheel.
- **Readable on any color** — the text ink switches between black and white by perceived brightness, so the hex stays legible on reds, blues, and dark tones where naive luminance gets it wrong.
- **Out of the way** — no dock icon, no window clutter, one menu-bar click away.
- **Zero dependencies** — a single Swift package.

## Requirements

- macOS 26 (Tahoe) or later — Liquid Glass and the loupe need the macOS 26 SDK
- Xcode 26 / Swift 6.2 to build
- **Grab Font** needs Accessibility permission (macOS prompts on first use)

## Build & run

```bash
git clone https://github.com/Entrepenulian/Picker.git
cd Picker
./build.sh            # compiles and assembles build/Picker.app
open build/Picker.app # launches the menu-bar agent
```

An eyedropper appears in your menu bar:

- **Left-click** it to open the panel.
- **Right-click** it to quit.

To make it Spotlight-launchable, drag `build/Picker.app` into `/Applications`.

> **Signing:** `build.sh` signs with a Developer ID identity when one is in your keychain (falling back to ad-hoc otherwise). A stable identity matters because the **Grab Font** Accessibility grant is keyed to the app's signing identity — sign stably and you grant it once, even across rebuilds; ad-hoc resets it every build.

## How it's built

Picker is a compact SwiftUI + AppKit app with no third-party code:

- **Shell** — a borderless, non-activating `NSPanel` anchored under an `NSStatusItem`, hosting SwiftUI through `NSHostingController`. Running its own panel instead of `MenuBarExtra` keeps the glass open *while* you sample.
- **Glass** — SwiftUI's `glassEffect` for the panel surface and the primary button.
- **Color sampling** — `NSColorSampler`, the same magnified loupe Apple's own color picker uses.
- **Font grabbing** — a full-screen, click-through, accessibility-invisible overlay plus a `CGEventTap` that *consumes* mouse events so the page underneath stays inert. A system-wide `AXUIElementCopyElementAtPosition` reads *through* the overlay and descends to the deepest `AXStaticText` leaf; the font comes from WebKit text-marker attributes, with a char-range fallback for native text.
- **Real faces & Find** — when a grabbed font isn't installed, `FontLoader` pulls it from the Google Fonts **css2** catalog (or Fontsource on jsDelivr) and registers it with `CTFontManagerRegisterFontsForURL`, which loads TTF/WOFF/WOFF2 by content. Variable fonts that register under a named-instance family are remapped via the font's own descriptor so the specimen still renders. **Find** deep-links Google-hosted fonts and web-searches everything else.
- **Contrast** — ink chosen by YIQ perceived brightness (`0.299·R + 0.587·G + 0.114·B`), which keeps white text on saturated and dark colors.
- **Persistence** — the palette and font list are JSON in `UserDefaults`.

```
Sources/Picker/
├── App.swift           # NSStatusItem + floating panel + sampling + font picking
├── PanelView.swift     # the whole UI: hero card, formats, palette, fonts section
├── Model.swift         # PickedColor, the color store, color math
├── Fonts.swift         # PickedFont and the font store
├── FontPicker.swift    # click-to-grab overlay (CGEventTap + accessibility reading)
├── FontLoader.swift    # downloads/registers real faces + Find URL routing
├── DesignSystem.swift  # tokens: ink, spacing, radii, motion
└── ColorSampler.swift  # NSColorSampler wrapper
```

## License

MIT — see [LICENSE](LICENSE).
