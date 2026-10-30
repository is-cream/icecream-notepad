// Notepad — native macOS plain-text notes app.
// Language: Objective-C++ (C++ with Cocoa). Single file.
// Build: ./build.sh   (needs Xcode Command Line Tools: xcode-select --install)
//
// - Plain text only, no formatting (NSTextView, monospace).
// - Every edit auto-saves to ~/.notepad/notes/<id>.txt
// - Open tabs + contents are restored on launch (unsaved notes survive restarts).
// - Cmd+N new tab, Cmd+W close tab, Cmd+S is a no-op (always saved).

#import <Cocoa/Cocoa.h>
#include <string>
#include <vector>
#include <fstream>
#include <sstream>
#include <filesystem>
#include <chrono>

namespace fs = std::filesystem;

// ---------------------------------------------------------------- storage

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
    return d + "/state.txt";  // lines: active_id, then one open id per line
}

struct Note {
    std::string nid;
    std::string content;
};

static std::string titleFor(const std::string& content) {
    auto nl = content.find('\n');
    std::string first = content.substr(0, nl == std::string::npos ? 40 : std::min<size_t>(nl, 40));
    // trim
    size_t a = first.find_first_not_of(" \t\r");
    size_t b = first.find_last_not_of(" \t\r");
    if (a == std::string::npos) return "Untitled";
    return first.substr(a, b - a + 1);
}

static std::vector<Note> loadAllNotes() {
    std::vector<Note> out;
    for (auto& p : fs::directory_iterator(dataDir())) {
        if (p.path().extension() != ".txt") continue;
        std::ifstream f(p.path());
        std::stringstream ss;
        ss << f.rdbuf();
        out.push_back({p.path().stem().string(), ss.str()});
    }
    return out;
}

static void saveNote(const std::string& nid, const std::string& content) {
    // Validate id (hex only) to block path traversal.
    for (char c : nid) {
        if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) return;
    }
    std::string tmp = dataDir() + "/" + nid + ".txt.tmp";
    std::string dst = dataDir() + "/" + nid + ".txt";
    std::ofstream f(tmp, std::ios::trunc);
    f << content;
    f.close();
    fs::rename(tmp, dst);
}

static void deleteNote(const std::string& nid) {
    for (char c : nid) {
        if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) return;
    }
    std::error_code ec;
    fs::remove(dataDir() + "/" + nid + ".txt", ec);
}

static std::string newId() {
    static uint64_t ctr = 0;
    auto now = std::chrono::steady_clock::now().time_since_epoch().count();
    char buf[32];
    snprintf(buf, sizeof(buf), "%llx%llx", (unsigned long long)now,
             (unsigned long long)(++ctr));
    return std::string(buf);
}

// ---------------------------------------------------------------- app

@interface TabInfo : NSObject
@property (nonatomic, strong) NSTextView* textView;
@property (nonatomic) std::string nid;
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

    self.tabs = [[NSTabView alloc] initWithFrame:[self.window.contentView bounds]];
    [self.tabs setAutoresizingMask:(NSViewWidthSizable | NSViewHeightSizable)];
    [self.tabs setDelegate:self];
    [self.window.contentView addSubview:self.tabs];

    // Restore or create first note.
    self.restoring = YES;
    std::vector<std::string> openIds;
    std::string activeId;
    {
        std::ifstream f(statePath());
        std::string line;
        bool first = true;
        while (std::getline(f, line)) {
            if (first) { activeId = line; first = false; }
            else if (!line.empty()) openIds.push_back(line);
        }
    }
    auto notes = loadAllNotes();
    // Keep only ids that still exist.
    std::vector<std::string> valid;
    for (auto& nid : openIds) {
        for (auto& n : notes) if (n.nid == nid) { valid.push_back(nid); break; }
    }
    if (valid.empty()) {
        std::string nid = newId();
        saveNote(nid, "");
        valid.push_back(nid);
        activeId = nid;
    }
    for (auto& nid : valid) [self addTabWithId:nid select:(nid == activeId)];
    if ([self.tabs numberOfTabViewItems] > 0 && activeId.empty())
        [self.tabs selectFirstTabViewItem:nil];
    self.restoring = NO;
    [self persistState];

    // Menu: Cmd+N new tab, Cmd+W close tab.
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

- (NSTabViewItem*)addTabWithId:(const std::string&)nid select:(BOOL)select {
    std::string content;
    for (auto& n : loadAllNotes()) if (n.nid == nid) { content = n.content; break; }

    NSTabViewItem* item = [[NSTabViewItem alloc] initWithIdentifier:@(nid.c_str())];
    [item setLabel:@(titleFor(content).c_str())];

    NSScrollView* scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 900, 620)];
    [scroll setHasVerticalScroller:YES];
    [scroll setAutoresizingMask:(NSViewWidthSizable | NSViewHeightSizable)];

    NSTextView* tv = [[NSTextView alloc] initWithFrame:[scroll bounds]];
    [tv setAutoresizingMask:(NSViewWidthSizable | NSViewHeightSizable)];
    [tv setFont:[NSFont monospacedSystemFontOfSize:14 weight:NSFontWeightRegular]];
    [tv setString:@(content.c_str())];
    [tv setRichText:NO];
    [tv setImportsGraphics:NO];
    [[tv textStorage] setDelegate:self];
    [scroll setDocumentView:tv];

    TabInfo* info = [[TabInfo alloc] init];
    info.textView = tv;
    info.nid = nid;
    [self.tabInfos addObject:info];
    // Tag the text view so the delegate can find its note id.
    [tv setIdentifier:@(nid.c_str())];

    [item setView:scroll];
    [self.tabs addTabViewItem:item];
    if (select) [self.tabs selectTabViewItem:item];
    return item;
}

- (TabInfo*)infoForTextView:(NSTextView*)tv {
    NSString* ident = [tv identifier];
    for (TabInfo* info in self.tabInfos) {
        if ([@(info.nid.c_str()) isEqualToString:ident]) return info;
    }
    return nil;
}

// NSTextStorageDelegate — auto-save on every edit.
- (void)textStorageDidProcessEditing:(NSNotification*)notification {
    if (self.restoring) return;
    NSTextStorage* ts = [notification object];
    // Find the owning text view via its layout manager.
    for (TabInfo* info in self.tabInfos) {
        NSTextView* tv = info.textView;
        if ([tv textStorage] == ts) {
            std::string content = [[tv string] UTF8String] ?: "";
            saveNote(info.nid, content);
            // Update tab label from first line.
            NSString* label = @(titleFor(content).c_str());
            for (NSTabViewItem* item in [self.tabs tabViewItems]) {
                if ([[item identifier] isEqualToString:@(info.nid.c_str())]) {
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
    [self addTabWithId:nid select:YES];
    [self persistState];
}

- (void)closeTab:(id)sender {
    NSTabViewItem* item = [self.tabs selectedTabViewItem];
    if (!item || [self.tabs numberOfTabViewItems] <= 1) return;
    std::string nid = [[item identifier] UTF8String] ?: "";
    // Flush current text first.
    for (TabInfo* info in self.tabInfos) {
        if (info.nid == nid) {
            std::string content = [[info.textView string] UTF8String] ?: "";
            saveNote(nid, content);
            break;
        }
    }
    // Delete the note only if it is empty (unsaved notes survive).
    bool hasContent = false;
    for (auto& n : loadAllNotes())
        if (n.nid == nid && !n.content.empty()) { hasContent = true; break; }
    if (!hasContent) deleteNote(nid);
    [self.tabInfos filterUsingPredicate:
        [NSPredicate predicateWithBlock:^BOOL(TabInfo* info, NSDictionary* b) {
            return info.nid != nid;
        }]];
    [self.tabs removeTabViewItem:item];
    [self persistState];
}

- (void)persistState {
    if (self.restoring) return;
    NSTabViewItem* sel = [self.tabs selectedTabViewItem];
    std::string active = sel ? ([[sel identifier] UTF8String] ?: "") : "";
    std::ofstream f(statePath(), std::ios::trunc);
    f << active << "\n";
    for (NSTabViewItem* item in [self.tabs tabViewItems]) {
        std::string nid = [[item identifier] UTF8String] ?: "";
        if (!nid.empty()) f << nid << "\n";
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
