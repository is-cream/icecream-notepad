#!/usr/bin/env python3
"""
Notepad — a plain-text notes app for Mac, in the spirit of Windows Notepad.

- Plain text only, no formatting.
- Every keystroke auto-saves to disk (~/.notepad/).
- Unsaved notes survive restarts: open tabs and their content are
  restored on launch, just like modern Windows Notepad.
- Tabs for multiple notes.

Run: python3 notepad.py  (serves on http://127.0.0.1:8421)
"""

import http.server
import json
import os
import socketserver
import threading
import time
import urllib.parse
import uuid
import webbrowser

VERSION = "1.0.0"
PORT = 8421

HOME = os.path.expanduser("~")
DATA_DIR = os.path.join(HOME, ".notepad")
NOTES_DIR = os.path.join(DATA_DIR, "notes")
STATE_PATH = os.path.join(DATA_DIR, "state.json")


def ensure_dirs():
    os.makedirs(NOTES_DIR, exist_ok=True)


def note_path(nid):
    # nid is a hex uuid we generated; guard against path traversal.
    if not nid or not all(c in "0123456789abcdef" for c in nid):
        raise ValueError("bad note id")
    return os.path.join(NOTES_DIR, nid + ".json")


def load_note(nid):
    with open(note_path(nid), encoding="utf-8") as f:
        return json.load(f)


def save_note(nid, title=None, content=None):
    ensure_dirs()
    try:
        note = load_note(nid)
    except (OSError, ValueError):
        note = {"id": nid, "title": "Untitled",
                "content": "", "created": time.time()}
    if title is not None:
        note["title"] = title[:120] or "Untitled"
    if content is not None:
        note["content"] = content
    note["updated"] = time.time()
    tmp = note_path(nid) + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(note, f, ensure_ascii=False)
    os.replace(tmp, note_path(nid))
    return note


def list_notes():
    ensure_dirs()
    out = []
    for fn in os.listdir(NOTES_DIR):
        if not fn.endswith(".json"):
            continue
        nid = fn[:-5]
        try:
            n = load_note(nid)
        except (OSError, ValueError):
            continue
        out.append({"id": nid, "title": n.get("title", "Untitled"),
                    "updated": n.get("updated", 0),
                    "preview": (n.get("content") or "")[:80]})
    out.sort(key=lambda x: x["updated"], reverse=True)
    return out


def delete_note(nid):
    try:
        os.remove(note_path(nid))
    except OSError:
        pass


def load_state():
    try:
        with open(STATE_PATH, encoding="utf-8") as f:
            s = json.load(f)
        if isinstance(s.get("open"), list):
            return s
    except (OSError, ValueError):
        pass
    return {"open": [], "active": None}


def save_state(open_ids, active):
    ensure_dirs()
    # Only keep ids that still exist.
    existing = {n["id"] for n in list_notes()}
    open_ids = [i for i in open_ids if i in existing]
    if active not in existing:
        active = open_ids[0] if open_ids else None
    s = {"open": open_ids, "active": active}
    tmp = STATE_PATH + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(s, f)
    os.replace(tmp, STATE_PATH)
    return s


INDEX_HTML = r"""<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Notepad</title>
<style>
  * { box-sizing: border-box; margin: 0; padding: 0; }
  html, body { height: 100%; }
  body { font-family: -apple-system, "SF Pro Text", Helvetica, Arial, sans-serif;
         background: #1e1e1e; color: #d4d4d4; display: flex; flex-direction: column;
         overflow: hidden; }
  #tabbar { display: flex; align-items: center; background: #252526;
            border-bottom: 1px solid #3c3c3c; min-height: 38px; padding: 0 8px;
            gap: 4px; overflow-x: auto; flex-shrink: 0; }
  .tab { display: flex; align-items: center; gap: 8px; padding: 8px 10px;
         background: transparent; border: none; border-radius: 6px 6px 0 0;
         color: #969696; font-size: 13px; cursor: pointer; white-space: nowrap;
         max-width: 200px; }
  .tab .t { overflow: hidden; text-overflow: ellipsis; }
  .tab.active { background: #1e1e1e; color: #fff; }
  .tab .x { opacity: 0; border: none; background: none; color: inherit;
            font-size: 14px; cursor: pointer; padding: 0 4px; border-radius: 4px; }
  .tab:hover .x, .tab.active .x { opacity: 0.7; }
  .tab .x:hover { opacity: 1; background: #3c3c3c; }
  .tab .dot { width: 7px; height: 7px; border-radius: 50%; background: #e5c07b;
              display: none; flex-shrink: 0; }
  .tab.dirty .dot { display: inline-block; }
  .tab.dirty .x { display: none; }
  #newtab { border: none; background: none; color: #969696; font-size: 18px;
            cursor: pointer; padding: 4px 10px; border-radius: 6px; }
  #newtab:hover { background: #2d2d2d; color: #fff; }
  #editor { flex: 1; border: none; outline: none; resize: none;
            background: #1e1e1e; color: #d4d4d4; padding: 16px 20px;
            font-family: Consolas, "SF Mono", Menlo, monospace; font-size: 14px;
            line-height: 1.6; }
  #statusbar { flex-shrink: 0; display: flex; justify-content: space-between;
               padding: 5px 14px; font-size: 12px; color: #969696;
               background: #252526; border-top: 1px solid #3c3c3c; }
</style>
</head>
<body>
<div id="tabbar"><button id="newtab" title="New note">+</button></div>
<textarea id="editor" spellcheck="false" placeholder="Start typing…"></textarea>
<div id="statusbar"><span id="savestate">Saved</span><span id="count"></span></div>
<script>
const $ = id => document.getElementById(id);
const api = async (path, opts={}) => {
  const r = await fetch(path, opts);
  if (!r.ok) throw new Error('HTTP ' + r.status);
  return r.json();
};

let openTabs = [];   // [{id, title}]
let activeId = null;
let dirty = false;
let saveTimer = null;

function titleFor(content) {
  const line = (content || '').split('\n')[0].trim().slice(0, 40);
  return line || 'Untitled';
}

async function refreshState() {
  const s = await api('/api/state');
  openTabs = [];
  for (const id of (s.open || [])) {
    try {
      const n = await api('/api/notes/' + id);
      openTabs.push({id, title: n.title || 'Untitled'});
    } catch(e) { /* note was deleted elsewhere */ }
  }
  activeId = s.active;
  if (!openTabs.length) await newNote(false);
  if (!openTabs.find(t => t.id === activeId)) activeId = openTabs[0].id;
  renderTabs();
  await openNote(activeId);
}

async function newNote(switchTo=true) {
  const n = await api('/api/notes', {method: 'POST'});
  openTabs.push({id: n.id, title: 'Untitled'});
  await saveOpenState();
  if (switchTo) { renderTabs(); await openNote(n.id); }
  return n.id;
}

async function openNote(id) {
  activeId = id;
  const n = await api('/api/notes/' + id);
  const t = openTabs.find(t => t.id === id);
  if (t) t.title = n.title || 'Untitled';
  $('editor').value = n.content || '';
  dirty = false;
  updateDirty();
  renderTabs();
  updateCount();
  await saveOpenState();
  $('editor').focus();
}

async function saveOpenState() {
  try {
    await api('/api/state', {method: 'PUT', headers: {'Content-Type': 'application/json'},
      body: JSON.stringify({open: openTabs.map(t => t.id), active: activeId})});
  } catch(e) {}
}

function renderTabs() {
  const bar = $('tabbar');
  bar.querySelectorAll('.tab').forEach(el => el.remove());
  const plus = $('newtab');
  for (const t of openTabs) {
    const el = document.createElement('div');
    el.className = 'tab' + (t.id === activeId ? ' active' : '') + ((t.id === activeId && dirty) ? ' dirty' : '');
    el.innerHTML = '<span class="dot"></span><span class="t"></span><button class="x" title="Close">×</button>';
    el.querySelector('.t').textContent = t.title;
    el.querySelector('.t').onclick = () => { if (t.id !== activeId) openNote(t.id); };
    el.querySelector('.x').onclick = async (e) => {
      e.stopPropagation();
      await closeTab(t.id);
    };
    bar.insertBefore(el, plus);
  }
}

async function closeTab(id) {
  const idx = openTabs.findIndex(t => t.id === id);
  if (idx < 0) return;
  const n = await api('/api/notes/' + id).catch(() => null);
  const hasContent = n && (n.content || '').trim();
  // Closing a tab with content keeps the note; empty notes are deleted.
  // (Matches "unsaved notes survive" — nothing is lost on close.)
  if (!hasContent) {
    try { await api('/api/notes/' + id, {method: 'DELETE'}); } catch(e) {}
  }
  // If closing the active tab, flush its content first.
  if (id === activeId) await flushSave();
  openTabs.splice(idx, 1);
  if (!openTabs.length) { await newNote(false); }
  if (activeId === id) activeId = openTabs[Math.min(idx, openTabs.length-1)].id;
  renderTabs();
  await openNote(activeId);
}

function updateDirty() {
  document.querySelectorAll('.tab').forEach((el, i) => {
    const t = openTabs[i];
    if (t && t.id === activeId) el.classList.toggle('dirty', dirty);
  });
  $('savestate').textContent = dirty ? 'Saving…' : 'Saved';
}

function updateCount() {
  const v = $('editor').value;
  const words = v.trim() ? v.trim().split(/\s+/).length : 0;
  $('count').textContent = v.length + ' chars · ' + words + ' words';
}

async function flushSave() {
  if (!activeId) return;
  const content = $('editor').value;
  const title = titleFor(content);
  const t = openTabs.find(t => t.id === activeId);
  try {
    await api('/api/notes/' + activeId, {method: 'PUT',
      headers: {'Content-Type': 'application/json'},
      body: JSON.stringify({title, content})});
    if (t && t.title !== title) { t.title = title; renderTabs(); }
    dirty = false;
    updateDirty();
  } catch(e) {
    $('savestate').textContent = 'Save failed';
  }
}

$('editor').addEventListener('input', () => {
  dirty = true;
  updateDirty();
  updateCount();
  clearTimeout(saveTimer);
  saveTimer = setTimeout(flushSave, 400);
});

$('newtab').onclick = () => newNote(true);

// Flush on unload so nothing is lost.
window.addEventListener('beforeunload', () => {
  if (activeId && dirty) {
    navigator.sendBeacon('/api/notes/' + activeId,
      new Blob([JSON.stringify({title: titleFor($('editor').value), content: $('editor').value})],
      {type: 'application/json'}));
  }
  navigator.sendBeacon('/api/state',
    new Blob([JSON.stringify({open: openTabs.map(t => t.id), active: activeId})],
    {type: 'application/json'}));
});

refreshState();
</script>
</body>
</html>
"""


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, code, body, ctype="application/json"):
        data = body.encode("utf-8") if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _json(self, obj, code=200):
        self._send(code, json.dumps(obj))

    def _read_json(self):
        try:
            n = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            n = 0
        if n <= 0:
            return {}
        try:
            return json.loads(self.rfile.read(n).decode("utf-8"))
        except ValueError:
            return {}

    def do_GET(self):
        path = urllib.parse.urlparse(self.path).path
        if path == "/" or path == "/index.html":
            self._send(200, INDEX_HTML, "text/html; charset=utf-8")
            return
        if path == "/api/notes":
            self._json(list_notes())
            return
        if path == "/api/state":
            self._json(load_state())
            return
        m = path.startswith("/api/notes/")
        if m:
            nid = path[len("/api/notes/"):]
            try:
                self._json(load_note(nid))
            except (OSError, ValueError):
                self._json({"error": "not found"}, 404)
            return
        self._json({"error": "not found"}, 404)

    def do_POST(self):
        path = urllib.parse.urlparse(self.path).path
        if path == "/api/notes":
            nid = uuid.uuid4().hex
            note = save_note(nid, title="Untitled", content="")
            # Auto-open it.
            st = load_state()
            if nid not in st["open"]:
                st["open"].append(nid)
            st["active"] = nid
            save_state(st["open"], st["active"])
            self._json({"id": nid})
            return
        self._json({"error": "not found"}, 404)

    def do_PUT(self):
        path = urllib.parse.urlparse(self.path).path
        body = self._read_json()
        if path == "/api/state":
            s = save_state(body.get("open") or [], body.get("active"))
            self._json(s)
            return
        if path.startswith("/api/notes/"):
            nid = path[len("/api/notes/"):]
            try:
                note = save_note(nid, title=body.get("title"),
                                 content=body.get("content"))
                self._json({"id": nid, "updated": note["updated"]})
            except ValueError:
                self._json({"error": "bad id"}, 400)
            return
        self._json({"error": "not found"}, 404)

    def do_DELETE(self):
        path = urllib.parse.urlparse(self.path).path
        if path.startswith("/api/notes/"):
            nid = path[len("/api/notes/"):]
            try:
                delete_note(nid)
                st = load_state()
                st["open"] = [i for i in st["open"] if i != nid]
                save_state(st["open"], st["active"])
                self._json({"ok": True})
            except ValueError:
                self._json({"error": "bad id"}, 400)
            return
        self._json({"error": "not found"}, 404)


class Server(socketserver.TCPServer):
    allow_reuse_address = True


def main():
    ensure_dirs()
    # Ensure at least one note exists on first launch.
    if not list_notes():
        nid = uuid.uuid4().hex
        save_note(nid, title="Untitled", content="")
        save_state([nid], nid)
    url = f"http://127.0.0.1:{PORT}"
    # Open the UI in the default browser shortly after startup.
    threading.Timer(0.8, lambda: webbrowser.open(url)).start()
    with Server(("127.0.0.1", PORT), Handler) as httpd:
        print(f"Notepad v{VERSION} on {url}", flush=True)
        httpd.serve_forever()


if __name__ == "__main__":
    main()
