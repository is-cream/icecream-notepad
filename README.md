# Notepad

A plain-text notes app for Mac, in the spirit of Windows Notepad.

- **Plain text only** — no formatting, no rich text, just like the old Windows Notepad.
- **Auto-save** — every keystroke is written to disk. There is no Save button because you never need one.
- **Survives restarts** — unsaved notes stay exactly as you left them, even when the machine is restarted. Open tabs and their content are restored on launch, like modern Windows Notepad.
- **Tabs** — multiple notes open at once. `+` for a new note, `×` to close (empty notes are deleted, notes with content are kept).
- **Local only** — everything lives in `~/.notepad/` on your machine. No cloud, no account, no telemetry.

## Run

```bash
python3 notepad.py
```

Opens http://127.0.0.1:8421 in your browser.

## Install as a Mac app

Unzip `Notepad-mac.zip`, move `Notepad.app` to `/Applications`, then:

```bash
xattr -cr /Applications/Notepad.app
```

Double-click to launch (macOS will ask once since the app is unsigned).

## How it works

Single Python 3 file, stdlib only. An HTTP server on localhost serves the UI and a small JSON API:

- `GET /api/notes` — list notes
- `POST /api/notes` — create note
- `GET /api/notes/<id>` — read note
- `PUT /api/notes/<id>` — save note (title + content)
- `DELETE /api/notes/<id>` — delete note
- `GET/PUT /api/state` — open tabs + active tab

Notes are stored as JSON files in `~/.notepad/notes/`; UI state in `~/.notepad/state.json`.
