//
//  VolBrainLinkFilter.m — plugin entry point.
//
//  Menu items (image filters menu, and toolbar buttons):
//    "volBrain: Send Series"   converts the series of the viewer and opens the volBrain window
//    "volBrain: Window"        opens the volBrain window and the list of jobs
//

#import "VolBrainLinkFilter.h"
#import "VBLWindowController.h"
#import "VBLPoller.h"
#import <OsiriXAPI/ViewerController.h>

static NSString * const VBLMenuSend = @"volBrain: Send Series";
static NSString * const VBLMenuWindow = @"volBrain: Window";

@implementation VolBrainLinkFilter

// Image-filter menu items work only while a 2D viewer is the active window. The volBrain window
// should open from anywhere (the database window, a PDF series), so it also gets its own item at
// the end of the Plugins menu (or the Window menu if there is no Plugins menu).
+ (void)installAppMenuItem
{
    static BOOL installed;
    if (installed) return;
    NSMenu *target = nil;
    for (NSMenuItem *item in [[NSApp mainMenu] itemArray])
        if ([item.title isEqualToString:@"Plugins"] && item.submenu) target = item.submenu;
    if (!target) target = [NSApp windowsMenu];
    if (!target) return;
    installed = YES;
    NSMenuItem *open = [[NSMenuItem alloc] initWithTitle:@"volBrain Window" action:@selector(openVolBrainWindow:) keyEquivalent:@""];
    open.target = self;
    [target addItem:[NSMenuItem separatorItem]];
    [target addItem:open];
}

+ (void)openVolBrainWindow:(id)sender
{
    [[VBLWindowController sharedController] showWindowAndSelectJob:nil];
}

- (void)initPlugin
{
    // Resume the status checks of jobs uploaded before the viewer was restarted.
    dispatch_async(dispatch_get_main_queue(), ^{
        [[VBLPoller sharedPoller] startIfNeeded];
        [VolBrainLinkFilter installAppMenuItem];
    });
    // The menu bar may be rebuilt after the plugins load: look again a little later.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [VolBrainLinkFilter installAppMenuItem];
    });
    // A finished job brings the volBrain window up with it selected; so does a click on its notification.
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    void (^show)(NSNotification *) = ^(NSNotification *note) {
        [[VBLWindowController sharedController] showWindowAndSelectJob:note.userInfo[@"jobID"]];
    };
    [center addObserverForName:VBLReportReadyNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:show];
    [center addObserverForName:VBLOpenJobNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:show];
}

- (long)filterImage:(NSString *)menuName
{
    VBLWindowController *window = [VBLWindowController sharedController];
    if ([menuName isEqualToString:VBLMenuWindow]) {
        [window showWindowAndSelectJob:nil];
        return 0;
    }
    [window prepareSeriesFromViewer:viewerController];
    return 0;
}

// Both menu items can be toolbar buttons, with the same icon.
+ (NSImage *)toolbarImage
{
    NSString *path = [[NSBundle bundleForClass:self] pathForImageResource:@"VolBrainLink-toolbar"];
    NSImage *image = path ? [[NSImage alloc] initWithContentsOfFile:path] : nil;
    return image ?: [NSImage imageWithSystemSymbolName:@"brain" accessibilityDescription:@"volBrain"];
}

- (NSToolbarItem *)toolbarItemForItemIdentifier:(NSString *)identifier forViewer:(id)controller
{
    // The viewer asks every plugin about every toolbar item, its own included: answer only for ours.
    BOOL window = [identifier isEqualToString:VBLMenuWindow];
    if (!window && ![identifier isEqualToString:VBLMenuSend]) return nil;
    if (!controller || ![controller respondsToSelector:@selector(executeFilterFromToolbar:)]) return nil;
    NSImage *image = [VolBrainLinkFilter toolbarImage];
    if (!image) return nil;
    NSToolbarItem *item = [[NSToolbarItem alloc] initWithItemIdentifier:identifier];
    // The viewer finds the plugin to run from the button's label: it must be the menu title.
    item.label = identifier;
    item.paletteLabel = identifier;
    item.toolTip = window ? @"Open the volBrain window and the list of jobs" : @"Send this series to volBrain (anonymous .nii.gz)";
    item.image = image;
    item.target = controller;
    item.action = @selector(executeFilterFromToolbar:);
    return item;
}

@end
