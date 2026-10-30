// Notepad — native macOS plain-text notes app.
// Language: Objective-C++ (C++ with Cocoa). Single file.
// Build: ./build.sh   (needs Xcode Command Line Tools: xcode-select --install)
//
// - Plain text only, no formatting (NSTextView, monospace).
// - Every edit auto-saves to ~/.notepad-cpp/notes/<id>.txt
// - Open tabs + contents are restored on launch (unsaved notes survive restarts).
// - Cmd+N new tab, Cmd+W close tab.

#import <Cocoa/Cocoa.h>
#include <string>
#include <vector>
#include <fstream>
#include <sstream>
#include <filesystem>
#include <chrono>

namespace fs = std::filesystem;

// ---------------------------------------------------------------- storage
// C++ side: std::string throughout. ObjC side: NSString*. Convert at boundary.

static std::string dataDir() {
    const char* home = getenv("HOME");
    std::string d = std::string(home ? home : "/tmp") + "/.notepad-cpp/notes";
    fs::create_directories(d);
    return d;
}

static std::string statePath() {
    const char* home = getenv("HOME");
    std::string d = std::string(home ? home : "/tmp") + "/.notepad-cpp";
    fs::create_directories(d);
    return d + "/state.txt";  // line 1: active id, rest: open ids
}

struct Note {
    std::string nid;
    std::string content;
};

static std::string titleFor(const std::string& content) {
    auto nl = content.find('\n');
    std::string first = content.substr(0, nl == std::string::npos ? 40 : std::min<size_t>(nl, 40));
    size_t a = first.find_first_not_of(" \t\r");
    size_t b = first.find_last_not_of(" \t\r");
    if (a == std::string::npos) return "Untitled";
    return first.substr(a, b - a + 1);
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
    for (auto& p : fs::directory_iterator(dataDir(), ec)) {
        if (p.path().extension() != ".txt") continue;
        std::string nid = p.path().stem().string();
        if (!validId(nid)) continue;
        std::ifstream f(p.path());
        std::stringstream ss;
        ss << f.rdbuf();
        out.push_back({nid, ss.str()});
    }
    return out;
}

static void saveNote(const std::string& nid, const std::string& content) {
    if (!validId(nid)) return;
    std::string tmp = dataDir() + "/" + nid + ".txt.tmp";
    std::string dst = dataDir() + "/" + nid + ".txt";
    std::ofstream f(tmp, std::ios::trunc);
    f << content;
    f.close();
    std::error_code ec;
    fs::rename(tmp, dst, ec);
}

static void deleteNote(const std::string& nid) {
    if (!validId(nid)) return;
    std::error_code ec;
    fs::remove(dataDir() + "/" + nid + ".txt", ec);
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

// ---------------------------------------------------------------- app

@interface TabInfo : NSObject
@property (nonatomic, strong) NSTextView* textView;
@property (nonatomic, copy) NSString* nid;   // NSString, not std::string
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
    [self.window setTitle:@"Notepad"];
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
    [appMenu addItemWithTitle:@"Quit Notepad" action:@selector(terminate:) keyEquivalent:@"q"];
    NSMenuItem* fileItem = [[NSMenuItem alloc] initWithTitle:@"File" action:nil keyEquivalent:@""];
    [mainMenu addItem:fileItem];
    NSMenu* fileMenu = [[NSMenu alloc] initWithTitle:@"File"];
    [fileItem setSubmenu:fileMenu];
    [fileMenu addItemWithTitle:@"New Tab" action:@selector(newTab:) keyEquivalent:@"n"];
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
        saveNote(nid, "");
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

- (void)addTabWithId:(NSString*)nid select:(BOOL)select {
    std::string cnid = C(nid);
    std::string content;
    for (auto& n : loadAllNotes()) {
        if (n.nid == cnid) { content = n.content; break; }
    }

    NSTabViewItem* item = [[NSTabViewItem alloc] initWithIdentifier:nid];
    [item setLabel:S(titleFor(content))];

    NSScrollView* scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 900, 620)];
    [scroll setHasVerticalScroller:YES];
    [scroll setAutoresizingMask:(NSViewWidthSizable | NSViewHeightSizable)];

    NSTextView* tv = [[NSTextView alloc] initWithFrame:[scroll bounds]];
    [tv setAutoresizingMask:(NSViewWidthSizable | NSViewHeightSizable)];
    [tv setFont:[NSFont monospacedSystemFontOfSize:14 weight:NSFontWeightRegular]];
    [tv setString:S(content)];
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

// NSTextStorageDelegate — auto-save on every edit.
- (void)textStorageDidProcessEditing:(NSNotification*)notification {
    if (self.restoring) return;
    NSTextStorage* ts = [notification object];
    for (TabInfo* info in self.tabInfos) {
        NSTextStorage* tvStorage = [[info textView] textStorage];
        if (tvStorage == ts) {
            std::string content = C([info.textView string]);
            saveNote(C(info.nid), content);
            NSString* label = S(titleFor(content));
            for (NSTabViewItem* item in [self.tabs tabViewItems]) {
                if ([[item identifier] isEqualToString:info.nid]) {
                    [item setLabel:label];
                    break;
                }
            }
            break;
        }
    }
}

- (void)newTab:(id)sender {
    std::string nid = newId();
    saveNote(nid, "");
    [self addTabWithId:S(nid) select:YES];
    [self persistState];
}

- (void)closeTab:(id)sender {
    NSTabViewItem* item = [self.tabs selectedTabViewItem];
    if (!item || [[self.tabs tabViewItems] count] <= 1) return;
    NSString* nid = (NSString*)[item identifier];
    std::string cnid = C(nid);

    // Flush current text first.
    for (TabInfo* info in self.tabInfos) {
        if ([info.nid isEqualToString:nid]) {
            saveNote(cnid, C([info.textView string]));
            break;
        }
    }
    // Delete the note only if empty; non-empty notes survive (can be
    // reopened — though this simple version has no "reopen" UI, the
    // file stays on disk and restoreTabs will pick it up if listed).
    bool hasContent = false;
    for (auto& n : loadAllNotes()) {
        if (n.nid == cnid && !n.content.empty()) { hasContent = true; break; }
    }
    if (!hasContent) deleteNote(cnid);

    NSMutableArray* keep = [NSMutableArray array];
    for (TabInfo* info in self.tabInfos) {
        if (![info.nid isEqualToString:nid]) [keep addObject:info];
    }
    self.tabInfos = keep;
    [self.tabs removeTabViewItem:item];
    [self persistState];
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
