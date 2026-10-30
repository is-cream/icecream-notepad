# Notepad

A native macOS plain-text notes app, in the spirit of Windows Notepad. Written in C++ (Objective-C++ with Cocoa). No Python, no server, no browser — just a normal desktop app.

- **Plain text only** — no formatting, no rich text. Monospace, like the old Windows Notepad.
- **Auto-save** — every keystroke is written to disk (`~/.notepad-cpp/notes/`). There is no Save button because you never need one.
- **Survives restarts** — unsaved notes stay exactly as you left them, even when the machine is restarted. Open tabs and their content are restored on launch.
- **Tabs** — `Cmd+N` for a new tab, `Cmd+W` to close. Closing a tab with content keeps the note; empty notes are deleted.
- **Local only** — everything lives in `~/.notepad-cpp/` on your machine. No cloud, no account, no telemetry.

## Build

Requires Xcode Command Line Tools (`xcode-select --install`):

```bash
cd cpp
./build.sh
```

This produces `cpp/Notepad.app`. Install it:

```bash
cp -r cpp/Notepad.app /Applications/
xattr -cr /Applications/Notepad.app   # unsigned app, Gatekeeper bypass
open /Applications/Notepad.app
```

## Layout

- `cpp/main.mm` — the entire app, single file (~330 lines)
- `cpp/build.sh` — compile + bundle script
- `notepad.html` — server-free web fallback (double-click to open, uses localStorage)

## How it works

`main.mm` is Objective-C++: C++ for storage (`std::filesystem`, `std::fstream`) and Cocoa for UI (`NSWindow`, `NSTabView`, `NSTextView`). An `NSTextStorageDelegate` fires on every edit and writes the note to disk. Tab state (open ids + active id) is persisted to `~/.notepad-cpp/state.txt` on every change.
