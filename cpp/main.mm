// Icecream Notepad — native macOS plain-text notes app.
// Language: Objective-C++ (C++ with Cocoa). Single file.
// Build: ./build.sh   (needs Xcode Command Line Tools: xcode-select --install)
//
// - Plain text only, no formatting (NSTextView, monospace).
// - Every edit auto-saves to ~/.icecream-notepad/notes/<id>.json
// - Tab title = filename (not first line). Unsaved tabs show "Untitled".
// - Cmd+S saves to the backing file; if none, acts as Save As.
// - Cmd+Shift+S / Save As… exports to ~/Documents/Notes/ (.txt default,
//   any extension allowed).
// - Open tabs + contents are restored on launch (unsaved notes survive restarts).
// - Cmd+N new tab, Cmd+W close tab.

#import <Cocoa/Cocoa.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <string>
#include <vector>
#include <fstream>
#include <sstream>
#include <filesystem>
#include <chrono>

namespace fs = std::filesystem;

// ---------------------------------------------------------------- storage
// C++ side: std::string throughout. ObjC side: NSString*. Convert at boundary.

static std::string baseDir() {
    const char* home = getenv("HOME");
    std::string d = std::string(home ? home : "/tmp") + "/.icecream-notepad";
    fs::create_directories(d);
    return d;
}

static std::string dataDir() {
    std::string d = baseDir() + "/notes";
    fs::create_directories(d);
    return d;
}

static std::string statePath() {
    return baseDir() + "/state.txt";  // line 1: active id, rest: open ids
}

struct Note {
    std::string nid;
    std::string content;
    std::string filepath;  // empty = unsaved (no file backing)
};

// Minimal JSON for note storage: {"content":"...","filepath":"..."}
// Content is stored with basic escaping (we control both sides).
static std::string jsonEscape(const std::string& s) {
    std::string out;
    for (char c : s) {
        switch (c) {
            case '"': out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\n': out += "\\n"; break;
            case '\r': out += "\\r"; break;
            case '\t': out += "\\t"; break;
            default: out += c;
        }
    }
    return out;
}

static std::string jsonUnescape(const std::string& s) {
    std::string out;
    for (size_t i = 0; i < s.size(); ++i) {
        if (s[i] == '\\' && i + 1 < s.size()) {
            char n = s[i + 1];
            if (n == '"') out += '"';
            else if (n == '\\') out += '\\';
            else if (n == 'n') out += '\n';
            else if (n == 'r') out += '\r';
            else if (n == 't') out += '\t';
            else { out += s[i]; out += n; }
            ++i;
        } else {
            out += s[i];
        }
    }
    return out;
}

// Extract "key":"value" (string value only) from a flat JSON object.
static std::string jsonGet(const std::string& json, const std::string& key) {
    std::string pat = "\"" + key + "\":\"";
    auto pos = json.find(pat);
    if (pos == std::string::npos) return "";
    pos += pat.size();
    std::string raw;
    while (pos < json.size()) {
        if (json[pos] == '\\' && pos + 1 < json.size()) {
            raw += json[pos]; raw += json[pos + 1]; pos += 2;
        } else if (json[pos] == '"') {
            break;
        } else {
            raw += json[pos]; ++pos;
        }
    }
    return jsonUnescape(raw);
}

static std::string basenameOf(const std::string& path) {
    auto pos = path.find_last_of("/\\");
    std::string b = (pos == std::string::npos) ? path : path.substr(pos + 1);
    return b.empty() ? "Untitled" : b;
}

static bool validId(const std::string& nid) {
    if (nid.empty() || nid.size() > 64) return false;
    for (char c : nid) {
        if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) return false;
    }
    return true;
}

static std::vector<Note> loadAllNotes() {
    std::vector<Note> out;
    std::error_code ec;
    // Migrate old .txt notes from the pre-JSON layout, once.
    std::string oldDir = std::string(getenv("HOME") ? getenv("HOME") : "/tmp")
                       + "/.notepad-cpp/notes";
    if (fs::exists(oldDir, ec)) {
        for (auto& p : fs::directory_iterator(oldDir, ec)) {
            if (p.path().extension() != ".txt") continue;
            std::string nid = p.path().stem().string();
            if (!validId(nid)) continue;
            // Skip if already migrated.
            if (fs::exists(dataDir() + "/" + nid + ".json", ec)) continue;
            std::ifstream f(p.path());
            std::stringstream ss;
            ss << f.rdbuf();
            std::string content = ss.str();
            std::string dst = dataDir() + "/" + nid + ".json";
            std::ofstream o(dst, std::ios::trunc);
            o << "{\"content\":\"" << jsonEscape(content) << "\",\"filepath\":\"\"}";
        }
    }
    for (auto& p : fs::directory_iterator(dataDir(), ec)) {
        if (p.path().extension() != ".json") continue;
        std::string nid = p.path().stem().string();
        if (!validId(nid)) continue;
        std::ifstream f(p.path());
        std::stringstream ss;
        ss << f.rdbuf();
        std::string json = ss.str();
        out.push_back({nid, jsonGet(json, "content"), jsonGet(json, "filepath")});
    }
    return out;
}

static void saveNote(const std::string& nid, const std::string& content,
                     const std::string& filepath) {
    if (!validId(nid)) return;
    std::string tmp = dataDir() + "/" + nid + ".json.tmp";
    std::string dst = dataDir() + "/" + nid + ".json";
    std::ofstream f(tmp, std::ios::trunc);
    f << "{\"content\":\"" << jsonEscape(content)
      << "\",\"filepath\":\"" << jsonEscape(filepath) << "\"}";
    f.close();
    std::error_code ec;
    fs::rename(tmp, dst, ec);
    // If the note has a backing file, write content there too.
    if (!filepath.empty()) {
        std::ofstream bf(filepath, std::ios::trunc);
        if (bf) bf << content;
    }
}

static void deleteNote(const std::string& nid) {
    if (!validId(nid)) return;
    std::error_code ec;
    fs::remove(dataDir() + "/" + nid + ".json", ec);
}

static std::string newId() {
    static uint64_t ctr = 0;
    auto now = std::chrono::steady_clock::now().time_since_epoch().count();
    char buf[40];
    snprintf(buf, sizeof(buf), "%llx%llx", (unsigned long long)now,
             (unsigned long long)(++ctr));
    return std::string(buf);
}

// NSString <-> std::string helpers
static inline NSString* S(const std::string& s) {
    return [NSString stringWithUTF8String:s.c_str()];
}
static inline std::string C(NSString* s) {
    return s ? [s UTF8String] : std::string();
}

// Default Save As folder: ~/Documents/Notes
static std::string defaultSaveDir() {
    const char* home = getenv("HOME");
    std::string d = std::string(home ? home : "/tmp") + "/Documents/Notes";
    std::error_code ec;
    fs::create_directories(d, ec);
    return d;
}

// ---------------------------------------------------------------- app

@interface TabInfo : NSObject
@property (nonatomic, strong) NSTextView* textView;
@property (nonatomic, copy) NSString* nid;
@end
@implementation TabInfo
@end

@interface AppDelegate : NSObject <NSApplicationDelegate, NSTextStorageDelegate, NSTabViewDelegate>
@property (nonatomic, strong) NSWindow* window;
@property (nonatomic, strong) NSTabView* tabs;
@property (nonatomic, strong) NSMutableArray<TabInfo*>* tabInfos;
@property (nonatomic) BOOL restoring;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification*)note {
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    self.tabInfos = [NSMutableArray array];

    NSRect frame = NSMakeRect(0, 0, 900, 650);
    self.window = [[NSWindow alloc]
        initWithContentRect:frame
                  styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                             NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable)
                    backing:NSBackingStoreBuffered
                      defer:NO];
    [self.window center];
    [self.window setTitle:@"Icecream Notepad"];
    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];

    self.tabs = [[NSTabView alloc] initWithFrame:[[self.window contentView] bounds]];
    [self.tabs setAutoresizingMask:(NSViewWidthSizable | NSViewHeightSizable)];
    [self.tabs setDelegate:self];
    [[self.window contentView] addSubview:self.tabs];

    [self setupMenu];
    [self restoreTabs];
}

- (void)setupMenu {
    NSMenu* mainMenu = [[NSMenu alloc] init];
    NSMenuItem* appItem = [[NSMenuItem alloc] init];
    [mainMenu addItem:appItem];
    NSMenu* appMenu = [[NSMenu alloc] init];
    [appItem setSubmenu:appMenu];
    [appMenu addItemWithTitle:@"Quit Icecream Notepad"
                      action:@selector(terminate:) keyEquivalent:@"q"];
    NSMenuItem* fileItem = [[NSMenuItem alloc] initWithTitle:@"File" action:nil keyEquivalent:@""];
    [mainMenu addItem:fileItem];
    NSMenu* fileMenu = [[NSMenu alloc] initWithTitle:@"File"];
    [fileItem setSubmenu:fileMenu];
    [fileMenu addItemWithTitle:@"New Tab" action:@selector(newTab:) keyEquivalent:@"n"];
    [fileMenu addItemWithTitle:@"Save" action:@selector(save:) keyEquivalent:@"s"];
    NSMenuItem* saveAs = [fileMenu addItemWithTitle:@"Save As…"
                                             action:@selector(saveAs:)
                                      keyEquivalent:@"S"];
    [saveAs setKeyEquivalentModifierMask:(NSEventModifierFlagCommand | NSEventModifierFlagShift)];
    [fileMenu addItemWithTitle:@"Close Tab" action:@selector(closeTab:) keyEquivalent:@"w"];
    [NSApp setMainMenu:mainMenu];
}

- (void)restoreTabs {
    self.restoring = YES;

    std::vector<std::string> openIds;
    std::string activeId;
    {
        std::ifstream f(statePath());
        std::string line;
        bool first = true;
        while (std::getline(f, line)) {
            if (first) { activeId = line; first = false; }
            else if (!line.empty() && validId(line)) openIds.push_back(line);
        }
    }
    auto notes = loadAllNotes();
    std::vector<std::string> valid;
    for (auto& nid : openIds) {
        for (auto& n : notes) {
            if (n.nid == nid) { valid.push_back(nid); break; }
        }
    }
    if (valid.empty()) {
        std::string nid = newId();
        saveNote(nid, "", "");
        valid.push_back(nid);
        activeId = nid;
    }
    NSString* activeNS = S(activeId);
    for (auto& nid : valid) {
        [self addTabWithId:S(nid) select:[S(nid) isEqualToString:activeNS]];
    }
    self.restoring = NO;
    [self persistState];
}

- (NSString*)tabTitleForNote:(const Note&)n {
    if (!n.filepath.empty()) return S(basenameOf(n.filepath));
    return @"Untitled";
}

- (void)addTabWithId:(NSString*)nid select:(BOOL)select {
    std::string cnid = C(nid);
    Note found{"", "", ""};
    for (auto& n : loadAllNotes()) {
        if (n.nid == cnid) { found = n; break; }
    }

    NSTabViewItem* item = [[NSTabViewItem alloc] initWithIdentifier:nid];
    [item setLabel:[self tabTitleForNote:found]];

    NSScrollView* scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 900, 620)];
    [scroll setHasVerticalScroller:YES];
    [scroll setAutoresizingMask:(NSViewWidthSizable | NSViewHeightSizable)];

    NSTextView* tv = [[NSTextView alloc] initWithFrame:[scroll bounds]];
    [tv setAutoresizingMask:(NSViewWidthSizable | NSViewHeightSizable)];
    [tv setFont:[NSFont monospacedSystemFontOfSize:14 weight:NSFontWeightRegular]];
    [tv setString:S(found.content)];
    [tv setRichText:NO];
    [tv setImportsGraphics:NO];
    [[tv textStorage] setDelegate:self];
    [scroll setDocumentView:tv];

    TabInfo* info = [[TabInfo alloc] init];
    info.textView = tv;
    info.nid = nid;
    [self.tabInfos addObject:info];

    [item setView:scroll];
    [self.tabs addTabViewItem:item];
    if (select) [self.tabs selectTabViewItem:item];
}

- (TabInfo*)infoForId:(NSString*)nid {
    for (TabInfo* info in self.tabInfos) {
        if ([info.nid isEqualToString:nid]) return info;
    }
    return nil;
}

- (Note)noteForId:(const std::string&)nid {
    for (auto& n : loadAllNotes()) {
        if (n.nid == nid) return n;
    }
    return {nid, "", ""};
}

// NSTextStorageDelegate — auto-save on every edit.
- (void)textStorageDidProcessEditing:(NSNotification*)notification {
    if (self.restoring) return;
    NSTextStorage* ts = [notification object];
    for (TabInfo* info in self.tabInfos) {
        NSTextStorage* tvStorage = [[info textView] textStorage];
        if (tvStorage == ts) {
            std::string cnid = C(info.nid);
            std::string content = C([[info textView] string]);
            Note n = [self noteForId:cnid];
            saveNote(cnid, content, n.filepath);
            // Title is filename-based; no update needed on content change.
            break;
        }
    }
}

- (void)newTab:(id)sender {
    std::string nid = newId();
    saveNote(nid, "", "");
    [self addTabWithId:S(nid) select:YES];
    [self persistState];
}

- (void)closeTab:(id)sender {
    NSTabViewItem* item = [self.tabs selectedTabViewItem];
    if (!item || [[self.tabs tabViewItems] count] <= 1) return;
    NSString* nid = (NSString*)[item identifier];
    std::string cnid = C(nid);

    TabInfo* info = [self infoForId:nid];
    std::string content = info ? C([[info textView] string]) : "";
    Note n = [self noteForId:cnid];
    saveNote(cnid, content, n.filepath);

    bool hasContent = !content.empty();
    if (!hasContent) deleteNote(cnid);

    NSMutableArray* keep = [NSMutableArray array];
    for (TabInfo* i in self.tabInfos) {
        if (![i.nid isEqualToString:nid]) [keep addObject:i];
    }
    self.tabInfos = keep;
    [self.tabs removeTabViewItem:item];
    [self persistState];
}

- (NSString*)currentContent {
    NSTabViewItem* item = [self.tabs selectedTabViewItem];
    if (!item) return @"";
    TabInfo* info = [self infoForId:(NSString*)[item identifier]];
    return info ? ([[info textView] string] ?: @"") : @"";
}

- (NSString*)currentNid {
    NSTabViewItem* item = [self.tabs selectedTabViewItem];
    return item ? (NSString*)[item identifier] : nil;
}

// Cmd+S — save to backing file; if none, behaves as Save As.
- (void)save:(id)sender {
    NSString* nid = [self currentNid];
    if (!nid) return;
    std::string cnid = C(nid);
    Note n = [self noteForId:cnid];
    std::string content = C([self currentContent]);
    if (n.filepath.empty()) {
        [self saveAs:sender];
        return;
    }
    saveNote(cnid, content, n.filepath);
    [self persistState];
}

// Cmd+Shift+S — Save As… (default ~/Documents/Notes/, .txt or any extension).
- (void)saveAs:(id)sender {
    NSString* nid = [self currentNid];
    if (!nid) return;
    NSString* content = [self currentContent];

    NSSavePanel* panel = [NSSavePanel savePanel];
    [panel setCanCreateDirectories:YES];
    [panel setAllowsOtherFileTypes:YES];
    UTType* txtType = [UTType typeWithFilenameExtension:@"txt"];
    if (txtType) [panel setAllowedContentTypes:@[txtType]];
    [panel setDirectoryURL:[NSURL fileURLWithPath:S(defaultSaveDir())]];

    // Default name: existing filename, or Untitled.txt
    std::string cnid = C(nid);
    Note n = [self noteForId:cnid];
    NSString* defaultName;
    if (!n.filepath.empty()) {
        defaultName = S(basenameOf(n.filepath));
    } else {
        defaultName = @"Untitled.txt";
    }
    [panel setNameFieldStringValue:defaultName];

    // Capture values for the completion block (avoid self cycle issues).
    __weak AppDelegate* weakSelf = self;
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSInteger result) {
        if (result != NSModalResponseOK) return;
        NSURL* url = [panel URL];
        if (!url) return;
        std::string path = C([[url path] stringByStandardizingPath]);
        AppDelegate* strongSelf = weakSelf;
        if (!strongSelf) return;

        // Write the file.
        NSError* err = nil;
        BOOL ok = [content writeToURL:url atomically:YES
                             encoding:NSUTF8StringEncoding error:&err];
        if (!ok) {
            NSAlert* alert = [[NSAlert alloc] init];
            [alert setMessageText:@"Could not save file"];
            [alert setInformativeText:[err localizedDescription] ?: @"Unknown error"];
            [alert runModal];
            return;
        }
        // Bind the note to this file; update tab title to the filename.
        std::string cur = C([strongSelf currentContent]);
        saveNote(cnid, cur, path);
        [strongSelf persistState];
        NSTabViewItem* item = [strongSelf.tabs selectedTabViewItem];
        if (item) [item setLabel:S(basenameOf(path))];
    }];
}

- (void)persistState {
    if (self.restoring) return;
    NSTabViewItem* sel = [self.tabs selectedTabViewItem];
    NSString* active = sel ? (NSString*)[sel identifier] : nil;
    std::ofstream f(statePath(), std::ios::trunc);
    f << C(active) << "\n";
    for (NSTabViewItem* item in [self.tabs tabViewItems]) {
        NSString* nid = (NSString*)[item identifier];
        if (nid) f << C(nid) << "\n";
    }
}

- (void)tabView:(NSTabView*)tv didSelectTabViewItem:(NSTabViewItem*)item {
    [self persistState];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication*)app {
    return YES;
}

@end

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        NSApplication* app = [NSApplication sharedApplication];
        AppDelegate* delegate = [[AppDelegate alloc] init];
        [app setDelegate:delegate];
        [app run];
        return 0;
    }
}
