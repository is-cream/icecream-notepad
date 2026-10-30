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
// Custom left-aligned tab bar (NSStackView) + single NSTextView.
// Tabs pack from the leading edge, exactly like Windows Notepad.

@interface AppDelegate : NSObject <NSApplicationDelegate, NSTextStorageDelegate>
@property (nonatomic, strong) NSWindow* window;
@property (nonatomic, strong) NSStackView* tabBar;
@property (nonatomic, strong) NSScrollView* scroll;
@property (nonatomic, strong) NSTextView* textView;
@property (nonatomic, strong) NSMutableArray<NSString*>* openIds;  // ordered
@property (nonatomic, copy) NSString* activeId;
@property (nonatomic) BOOL restoring;
@end

@implementation AppDelegate

static const CGFloat kTabBarHeight = 34.0;

- (void)applicationDidFinishLaunching:(NSNotification*)note {
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    self.openIds = [NSMutableArray array];

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

    NSView* content = [self.window contentView];
    NSRect cb = [content bounds];

    // Tab bar: horizontal stack, views pack from the LEADING edge (left).
    self.tabBar = [[NSStackView alloc] initWithFrame:
        NSMakeRect(0, cb.size.height - kTabBarHeight, cb.size.width, kTabBarHeight)];
    [self.tabBar setOrientation:NSUserInterfaceLayoutOrientationHorizontal];
    [self.tabBar setSpacing:2.0];
    [self.tabBar setAlignment:NSLayoutAttributeCenterY];
    [self.tabBar setDistribution:NSStackViewDistributionGravityAreas];
    [self.tabBar setAutoresizingMask:(NSViewWidthSizable | NSViewMinYMargin)];
    [content addSubview:self.tabBar];

    // Single text view below the tab bar.
    self.scroll = [[NSScrollView alloc] initWithFrame:
        NSMakeRect(0, 0, cb.size.width, cb.size.height - kTabBarHeight)];
    [self.scroll setHasVerticalScroller:YES];
    [self.scroll setAutoresizingMask:(NSViewWidthSizable | NSViewHeightSizable)];

    self.textView = [[NSTextView alloc] initWithFrame:[self.scroll bounds]];
    [self.textView setAutoresizingMask:(NSViewWidthSizable | NSViewHeightSizable)];
    [self.textView setFont:[NSFont monospacedSystemFontOfSize:14 weight:NSFontWeightRegular]];
    [self.textView setRichText:NO];
    [self.textView setImportsGraphics:NO];
    [[self.textView textStorage] setDelegate:self];
    [self.scroll setDocumentView:self.textView];
    [content addSubview:self.scroll];

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

// ---------------------------------------------------------------- notes

- (Note)noteForId:(NSString*)nid {
    std::string cnid = C(nid);
    for (auto& n : loadAllNotes()) {
        if (n.nid == cnid) return n;
    }
    return {cnid, "", ""};
}

- (NSString*)titleForId:(NSString*)nid {
    Note n = [self noteForId:nid];
    if (!n.filepath.empty()) return S(basenameOf(n.filepath));
    return @"Untitled";
}

- (void)flushActive {
    if (!self.activeId || self.restoring) return;
    Note n = [self noteForId:self.activeId];
    saveNote(C(self.activeId), C([self.textView string]), n.filepath);
}

// ---------------------------------------------------------------- tab bar

- (NSView*)tabViewForId:(NSString*)nid active:(BOOL)active {
    NSString* title = [self titleForId:nid];

    NSButton* label = [NSButton buttonWithTitle:title target:self
                                        action:@selector(tabClicked:)];
    [label setIdentifier:nid];
    [label setBordered:NO];
    [label setFont:active
        ? [NSFont boldSystemFontOfSize:13]
        : [NSFont systemFontOfSize:13]];

    NSButton* x = [NSButton buttonWithTitle:@"×" target:self
                                    action:@selector(tabCloseClicked:)];
    [x setIdentifier:nid];
    [x setBordered:NO];
    [x setFont:[NSFont systemFontOfSize:13]];

    NSStackView* tab = [[NSStackView alloc] init];
    [tab setOrientation:NSUserInterfaceLayoutOrientationHorizontal];
    [tab setSpacing:0];
    [tab setAlignment:NSLayoutAttributeCenterY];
    [tab addArrangedSubview:label];
    [tab addArrangedSubview:x];
    [tab setWantsLayer:YES];
    if (active) {
        [[tab layer] setBackgroundColor:[[NSColor controlBackgroundColor] CGColor]];
    }
    // Rounded tab look.
    [[tab layer] setCornerRadius:6.0];
    return tab;
}

- (void)rebuildTabBar {
    for (NSView* v in [[self.tabBar arrangedSubviews] copy]) {
        [self.tabBar removeArrangedSubview:v];
        [v removeFromSuperview];
    }
    for (NSString* nid in self.openIds) {
        [self.tabBar addArrangedSubview:
            [self tabViewForId:nid active:[nid isEqualToString:self.activeId]]];
    }
    NSButton* plus = [NSButton buttonWithTitle:@"+" target:self
                                       action:@selector(newTab:)];
    [plus setBordered:NO];
    [plus setFont:[NSFont systemFontOfSize:16]];
    [self.tabBar addArrangedSubview:plus];
}

- (void)selectTab:(NSString*)nid {
    if (!nid) return;
    [self flushActive];
    self.activeId = nid;
    Note n = [self noteForId:nid];
    self.restoring = YES;
    [self.textView setString:S(n.content)];
    self.restoring = NO;
    [self rebuildTabBar];
    [self persistState];
}

- (void)tabClicked:(NSButton*)sender {
    NSString* nid = [sender identifier];
    if (nid && ![nid isEqualToString:self.activeId]) [self selectTab:nid];
}

- (void)tabCloseClicked:(NSButton*)sender {
    NSString* nid = [sender identifier];
    if (!nid) return;
    if ([nid isEqualToString:self.activeId]) {
        [self closeTab:nil];
    } else {
        // Close a background tab: flush is unnecessary (it was flushed on switch).
        Note n = [self noteForId:nid];
        if (n.content.empty()) deleteNote(C(nid));
        [self.openIds removeObject:nid];
        [self rebuildTabBar];
        [self persistState];
    }
}

- (void)newTab:(id)sender {
    [self flushActive];
    std::string nid = newId();
    saveNote(nid, "", "");
    [self.openIds addObject:S(nid)];
    [self selectTab:S(nid)];
}

- (void)closeTab:(id)sender {
    if ([self.openIds count] <= 1) return;
    NSString* nid = self.activeId;
    [self flushActive];
    Note n = [self noteForId:nid];
    if (n.content.empty()) deleteNote(C(nid));
    NSUInteger idx = [self.openIds indexOfObject:nid];
    [self.openIds removeObject:nid];
    // Select a neighbor.
    NSUInteger next = idx < [self.openIds count] ? idx : [self.openIds count] - 1;
    [self selectTab:self.openIds[next]];
}

// ---------------------------------------------------------------- restore

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
    [self.openIds removeAllObjects];
    for (auto& nid : openIds) {
        for (auto& n : notes) {
            if (n.nid == nid) { [self.openIds addObject:S(nid)]; break; }
        }
    }
    if ([self.openIds count] == 0) {
        std::string nid = newId();
        saveNote(nid, "", "");
        [self.openIds addObject:S(nid)];
        activeId = nid;
    }
    NSString* activeNS = S(activeId);
    NSString* toSelect = [self.openIds containsObject:activeNS] ? activeNS : self.openIds[0];
    self.restoring = NO;
    [self selectTab:toSelect];
}

// NSTextStorageDelegate — auto-save on every edit.
- (void)textStorageDidProcessEditing:(NSNotification*)notification {
    [self flushActive];
}

- (void)persistState {
    if (self.restoring) return;
    std::ofstream f(statePath(), std::ios::trunc);
    f << C(self.activeId) << "\n";
    for (NSString* nid in self.openIds) {
        f << C(nid) << "\n";
    }
}

// ---------------------------------------------------------------- save

// Cmd+S — save to backing file; if none, behaves as Save As.
- (void)save:(id)sender {
    if (!self.activeId) return;
    Note n = [self noteForId:self.activeId];
    if (n.filepath.empty()) {
        [self saveAs:sender];
        return;
    }
    [self flushActive];
    [self persistState];
}

// Cmd+Shift+S — Save As… (default ~/Documents/Notes/, .txt or any extension).
- (void)saveAs:(id)sender {
    if (!self.activeId) return;
    NSString* content = [self.textView string] ?: @"";
    NSString* nid = self.activeId;

    NSSavePanel* panel = [NSSavePanel savePanel];
    [panel setCanCreateDirectories:YES];
    [panel setAllowsOtherFileTypes:YES];
    UTType* txtType = [UTType typeWithFilenameExtension:@"txt"];
    if (txtType) [panel setAllowedContentTypes:@[txtType]];
    [panel setDirectoryURL:[NSURL fileURLWithPath:S(defaultSaveDir())]];

    Note n = [self noteForId:nid];
    NSString* defaultName = n.filepath.empty()
        ? @"Untitled.txt"
        : S(basenameOf(n.filepath));
    [panel setNameFieldStringValue:defaultName];

    __weak AppDelegate* weakSelf = self;
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSInteger result) {
        if (result != NSModalResponseOK) return;
        NSURL* url = [panel URL];
        if (!url) return;
        std::string path = C([[url path] stringByStandardizingPath]);
        AppDelegate* strongSelf = weakSelf;
        if (!strongSelf) return;

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
        // Bind the note to this file and refresh the tab title.
        saveNote(C(nid), C(content), path);
        [strongSelf rebuildTabBar];
        [strongSelf persistState];
    }];
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
