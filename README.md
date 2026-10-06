# WindowUP! — Always-on-Top Windows for macOS (M2 Max)

A native macOS (arm64) app that lets you **pin web tabs above other windows**:

while browsing in Chrome/Safari, you can keep **WhatsApp as a small, movable, resizable square** on screen — and do the same with Gmail, Calendar, YouTube, ChatGPT, and more.

The app is **already compiled and running**: `WindowUP.app` is located in this folder.

## Usage (30 seconds)

1. The app opens with the **Manager** window + a sample **400×400 WhatsApp** window already pinned.
2. Log in to WhatsApp Web using the QR code **once**: your session remains stored using a persistent WKWebView.
3. Drag the panel **from the title bar** to move it, and drag **the corners** to resize it.
4. In the Manager (**Websites** tab):

   * **Quick Presets**: WhatsApp, Telegram, Gmail, Calendar, YouTube, ChatGPT, Spotify, Google.
   * **Active Apps**: a box showing apps currently open on your Mac (OpenCode, Sublime Text, Packet Tracer, etc.). Click an app to bring it to the front; the "keep in front" watchdog brings it back above other windows every second (experimental, requires Accessibility permissions).
   * **New Pinned Window**: paste any URL + choose a size (Square/Small/Medium/Large).
   * For each window: Show/Hide, opacity, width/height, `Extra Above`, `All Spaces`.
5. Command menu:

   * `⌘N` — New Window
   * `⇧⌘M` — Show All
   * `⇧⌘H` — Hide All

### Useful Details

* **Always on top**: uses the `.floating` window level by default; enable `Extra Above (Fullscreen)` to use `.screenSaver` level (stays above even fullscreen apps).
* **Spaces**: `Visible in All Spaces` makes the window follow you across desktops. Disable it to attach the window to a specific Space.
* **Panel Toolbar**: every panel includes back/forward/reload controls, an address bar, and ⚙️ settings with opacity + quick size options.
* **Persistence**: windows are saved and automatically reopened after restarting the app.
* **Login sessions**: cookies/localStorage are persisted through `WKWebsiteDataStore.default`, so services such as Gmail and WhatsApp remain logged in.

---

# Native Apps: Terminal, VS Code, etc. (App & Windows tab)

In addition to websites, WindowUP! can manage **real application windows** using the same general approach as Floaty:

* **Active Apps** (Websites tab): a box showing apps currently open on your Mac. Clicking an app brings it to the front and creates a **live, always-on-top sticker** (~15 FPS using ScreenCaptureKit). Clicking the sticker takes you back to the real window.
* **Live Sticker**: floating panels showing the live video stream of an application window (works even when the original window is covered), with opacity, click-through, and `Extra Above` controls. From the panel, use **Go to Window** to interact with the original application.
* **Open App**: quick buttons for Terminal, VS Code, Notes, Activity Monitor + `Choose App…` + `Activate`.

> **Honest limitation:** macOS 15/26 blocks true interactive cross-process always-on-top behavior (verified: `CGSSetWindowLevel` on another application's windows is effectively a no-op). A live ScreenCaptureKit preview inside WindowUP!'s own panel is the stable approach without disabling SIP. To interact with the original application, use the `Go to Window` button.

### Required Permissions

WindowUP! indicates the required permissions directly in the tab:

* **Screen Recording** (Privacy & Security): required for window titles and live previews. Without it, the app list still appears, but window titles are unavailable and previews remain blank.
* **Accessibility** (recommended): required to bring other applications to the front using `Activate`.

---

# Technical Verdict — Tested on This Mac, Not Just in Theory

* `CGSSetWindowLevel` on another application's window: returns success, but **the pixels remain identical before and after** (verified using screenshots + hashes). It does nothing.
* `AXRaise`: accepted, but produces no visible effect.
* `CGSOrderWindow`: returns an error.
* Floaty and similar applications use **ScreenCaptureKit mirroring**, not true pinning.
* True interactive pinning is only possible using **yabai + reduced SIP protections** (guide available in the App & Windows tab).

For security reasons, macOS does **not allow another native application's window** to be interactively embedded inside your own window (for example, the WhatsApp app from the Mac App Store), nor can you force another application's native window to remain always on top using public APIs.

For this reason, WindowUP! uses the **web versions** (`web.whatsapp.com`, `web.telegram.org`, `mail.google.com`, etc.), which are fully interactive and complete.

This is the correct and stable approach.

For native applications such as Terminal or VS Code, the **App & Windows** tab provides:

* **Integrated Terminal** — real, interactive, always on top.
* **Live Stickers** — Floaty-style live previews.
* **Window previews**.
* **Go to Window** — instantly return to the real application window.

---

# Stable Installation

```bash
# Copy to Applications (recommended)
cp -R "WindowUP.app" /Applications/
open /Applications/WindowUP.app
```

On the first launch, if macOS blocks the app because it is ad-hoc signed:

**Right-click `WindowUP.app` → Open → Open**

---

# Rebuilding / Modifying the App

Xcode is required.

Tested with **Xcode 26.2**, macOS on an **M2 Max**, with a **macOS 13+ deployment target**.

```bash
cd "/Users/liamdimarzio/Documents/programmi/WindowUP!"

# Debug
xcodebuild -project WindowUP.xcodeproj -scheme WindowUP -configuration Debug build

# Release + fresh copy
xcodebuild -project WindowUP.xcodeproj -scheme WindowUP -configuration Release build

cp -R ~/Library/Developer/Xcode/DerivedData/WindowUP-*/Build/Products/Release/WindowUP.app ./WindowUP.app
```

Alternatively, open `WindowUP.xcodeproj` in Xcode and press `⌘R`.

## Project Structure

The main source files are:

* `WindowUPApp.swift` — entry point + AppDelegate (session restoration)
* `ContentView.swift` — tabbed Manager: Websites + App & Windows + Settings
* `PanelManager.swift` — creates/manages/saves web `NSPanel`s
* `WindowPinning.swift` — lists other application windows (`CGWindowList`), launches/activates apps, handles permissions
* `MirrorManager.swift` — live previews of native apps using ScreenCaptureKit
* `AppWindowsView.swift` — App & Windows tab (launch apps, previews, permissions)
* `FloatingPanel.swift` — always-on-top, movable/resizable `NSPanel`
* `FloatingWebView.swift` — `WKWebView` with Safari User-Agent + toolbar
* `Models.swift` — `PinnedItem`, presets, and size definitions

---

# Troubleshooting

### WhatsApp says "browser not supported"

This is handled by using a **desktop Safari User-Agent**.

If the problem occurs again, reload the page using the `⟳` button in the panel.

### The window does not stay above a fullscreen app

Enable **`Extra Above`** in the panel settings.

### WhatsApp/Gmail asks for the QR code or login again after restarting

You may have deleted the system web data or changed the `WKWebsiteDataStore`.

Normally, this should **not happen**, because WindowUP! uses:

`WKWebsiteDataStore.default`

for persistent cookies and local storage.

### App signing

The current build uses **ad-hoc signing**:

* `CODE_SIGN_IDENTITY = -`
* App Sandbox disabled
* Only `network.client` entitlement enabled

For distribution, configure a proper **Apple Developer Team** in Xcode.
