#import "AppDelegate.h"
#import "EqualizerWindowController.h"

@interface AppDelegate ()

@property (strong) IBOutlet NSWindow *window;
@property (strong) NSStatusItem *statusItem;
@property (strong) EqualizerWindowController *equalizerController;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSSquareStatusItemLength];
    NSImage *image = [[NSImage alloc] initWithSize:NSMakeSize(18, 18)];
    [image lockFocus];
    [[NSColor blackColor] setFill];
    for (NSInteger bar = 0; bar < 3; ++bar) {
        NSRectFill(NSMakeRect(3 + bar * 5, 2, 2, 14));
        NSRectFill(NSMakeRect(1 + bar * 5, bar == 1 ? 5 : 10, 6, 3));
    }
    [image unlockFocus];
    [image setTemplate:YES];
    self.statusItem.button.image = image;
    self.statusItem.button.toolTip = NSLocalizedString(@"Proxy Audio Device", nil);
    self.statusItem.button.accessibilityLabel = NSLocalizedString(@"Proxy Audio Device", nil);

    NSMenu *menu = [[NSMenu alloc] initWithTitle:NSLocalizedString(@"Proxy Audio Device", nil)];
    NSMenuItem *equalizer = [menu addItemWithTitle:NSLocalizedString(@"Equalizer", nil)
                                         action:@selector(showEqualizer:) keyEquivalent:@""];
    equalizer.target = self;
    NSMenuItem *settings = [menu addItemWithTitle:NSLocalizedString(@"Settings...", nil)
                                        action:@selector(showSettings:) keyEquivalent:@","];
    settings.target = self;
    [menu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *quit = [menu addItemWithTitle:NSLocalizedString(@"Quit Proxy Audio Device", nil)
                                    action:@selector(terminate:) keyEquivalent:@"q"];
    quit.target = NSApp;
    self.statusItem.menu = menu;
    [self.window orderOut:nil];
}

- (void)showEqualizer:(id)sender {
    if (!self.equalizerController)
        self.equalizerController = [[EqualizerWindowController alloc] init];
    [NSApp activateIgnoringOtherApps:YES];
    [self.equalizerController showWindow:sender];
    [self.equalizerController.window makeKeyAndOrderFront:sender];
}

- (void)showSettings:(id)sender {
    [NSApp activateIgnoringOtherApps:YES];
    [self.window makeKeyAndOrderFront:sender];
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    [self.equalizerController flushSettings];
    [[NSStatusBar systemStatusBar] removeStatusItem:self.statusItem];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
#pragma unused(sender)
    return NO;
}

@end
