//
//  VBLWindowController.m
//

#import "VBLWindowController.h"
#import "VBLJobStore.h"
#import "VBLExport.h"
#import "VBLPoller.h"
#import "VBLCookies.h"
#import <WebKit/WebKit.h>
#import <OsiriXAPI/ViewerController.h>

static NSString * const VBLHomeURL = @"https://volbrain.net/";

@interface VBLWindowController () <WKNavigationDelegate, WKUIDelegate, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate>
@end

@implementation VBLWindowController {
    WKWebView *_web;
    NSButton *_back, *_forward;
    NSTextField *_address;
    NSProgressIndicator *_spinner;
    NSTableView *_table;
    NSTextField *_helper, *_pollStatus;
    NSButton *_importButton, *_revealButton, *_removeButton;
    NSPopUpButton *_interval;
    NSArray<NSDictionary *> *_jobs;
    BOOL _showingPDF;
    BOOL _loadedOnce;
}

+ (instancetype)sharedController
{
    static VBLWindowController *controller;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ controller = [[VBLWindowController alloc] init]; });
    return controller;
}

#pragma mark - Building the window

static NSButton *VBLSymbolButton(NSString *symbol, NSString *label, id target, SEL action)
{
    NSImage *image = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:label];
    NSButton *b = image ? [NSButton buttonWithImage:image target:target action:action]
                        : [NSButton buttonWithTitle:label target:target action:action];
    b.bezelStyle = NSBezelStyleTexturedRounded;
    b.toolTip = label;
    return b;
}

static NSButton *VBLButton(NSString *title, id target, SEL action)
{
    NSButton *b = [NSButton buttonWithTitle:title target:target action:action];
    b.bezelStyle = NSBezelStyleRounded;
    return b;
}

- (instancetype)init
{
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1200, 920)
                                                   styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
                                                     backing:NSBackingStoreBuffered defer:NO];
    if (!(self = [super initWithWindow:window])) return nil;
    window.title = @"volBrain";
    window.releasedWhenClosed = NO;
    window.minSize = NSMakeSize(820, 600);
    window.delegate = self;
    [window center];
    [window setFrameAutosaveName:@"VolBrainLinkWindow"];

    // Web part
    WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
    config.websiteDataStore = [WKWebsiteDataStore defaultDataStore];   // the login is remembered
    config.applicationNameForUserAgent = @"Version/18.0 Safari/605.1.15";
    _web = [[WKWebView alloc] initWithFrame:NSZeroRect configuration:config];
    _web.navigationDelegate = self;
    _web.UIDelegate = self;
    _web.allowsBackForwardNavigationGestures = YES;
    _web.translatesAutoresizingMaskIntoConstraints = NO;

    _back = VBLSymbolButton(@"chevron.left", @"Back", self, @selector(goBack:));
    _forward = VBLSymbolButton(@"chevron.right", @"Forward", self, @selector(goForward:));
    NSButton *reload = VBLSymbolButton(@"arrow.clockwise", @"Reload", self, @selector(reload:));
    NSButton *home = VBLSymbolButton(@"house", @"volBrain home page", self, @selector(goHome:));
    NSButton *results = VBLButton(@"Results", self, @selector(goResults:));
    results.toolTip = @"Open the page the plugin checks for finished jobs";
    NSButton *usePage = VBLButton(@"Check this page", self, @selector(useThisPage:));
    usePage.toolTip = @"Use the page shown now (your volBrain RESULTS list) for the status checks";
    _address = [NSTextField labelWithString:@""];
    _address.lineBreakMode = NSLineBreakByTruncatingMiddle;
    _address.textColor = [NSColor secondaryLabelColor];
    [_address setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    _spinner = [[NSProgressIndicator alloc] init];
    _spinner.style = NSProgressIndicatorStyleSpinning;
    _spinner.controlSize = NSControlSizeSmall;
    _spinner.displayedWhenStopped = NO;

    NSStackView *bar = [NSStackView stackViewWithViews:@[ _back, _forward, reload, home, results, usePage, _spinner, _address ]];
    bar.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    bar.spacing = 6;
    bar.translatesAutoresizingMaskIntoConstraints = NO;

    NSView *top = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 1200, 680)];
    [top addSubview:bar];
    [top addSubview:_web];
    [NSLayoutConstraint activateConstraints:@[
        [bar.topAnchor constraintEqualToAnchor:top.topAnchor constant:6],
        [bar.leadingAnchor constraintEqualToAnchor:top.leadingAnchor constant:8],
        [bar.trailingAnchor constraintLessThanOrEqualToAnchor:top.trailingAnchor constant:-8],
        [_web.topAnchor constraintEqualToAnchor:bar.bottomAnchor constant:6],
        [_web.leadingAnchor constraintEqualToAnchor:top.leadingAnchor],
        [_web.trailingAnchor constraintEqualToAnchor:top.trailingAnchor],
        [_web.bottomAnchor constraintEqualToAnchor:top.bottomAnchor],
    ]];

    // Jobs part
    NSTextField *title = [NSTextField labelWithString:@"Series prepared for volBrain"];
    title.font = [NSFont boldSystemFontOfSize:[NSFont systemFontSize]];
    _helper = [NSTextField wrappingLabelWithString:@""];
    _helper.textColor = [NSColor secondaryLabelColor];
    [_helper setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSStackView *titleRow = [NSStackView stackViewWithViews:@[ title, _helper ]];
    titleRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    titleRow.alignment = NSLayoutAttributeFirstBaseline;
    titleRow.spacing = 12;
    titleRow.translatesAutoresizingMaskIntoConstraints = NO;

    _table = [[NSTableView alloc] initWithFrame:NSZeroRect];
    NSArray *columns = @[ @[ @"file", @"Uploaded as", @150 ], @[ @"series", @"Series", @220 ], @[ @"patient", @"Patient (stays on this Mac)", @200 ],
                          @[ @"age", @"Age / sex", @80 ], @[ @"state", @"Status", @420 ] ];
    for (NSArray *c in columns) {
        NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:c[0]];
        column.title = c[1];
        column.width = [c[2] doubleValue];
        column.minWidth = 60;
        [_table addTableColumn:column];
    }
    _table.dataSource = self;
    _table.delegate = self;
    _table.usesAlternatingRowBackgroundColors = YES;
    _table.allowsMultipleSelection = NO;
    _table.columnAutoresizingStyle = NSTableViewLastColumnOnlyAutoresizingStyle;
    _table.doubleAction = @selector(importSelected:);
    _table.target = self;
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    scroll.documentView = _table;
    scroll.hasVerticalScroller = YES;
    scroll.borderType = NSBezelBorder;
    scroll.translatesAutoresizingMaskIntoConstraints = NO;

    NSButton *prepare = VBLButton(@"Prepare Front Series", self, @selector(prepareFrontSeries:));
    prepare.toolTip = @"Convert the series in the front viewer to an anonymous .nii.gz";
    _importButton = VBLButton(@"Import Report into Viewer", self, @selector(importSelected:));
    _importButton.toolTip = @"Adds the report to the study: the PDF shown above if one is open, otherwise the downloaded report of the selected series";
    _importButton.keyEquivalent = @"\r";
    _revealButton = VBLButton(@"Show in Finder", self, @selector(revealSelected:));
    _removeButton = VBLButton(@"Remove", self, @selector(removeSelected:));
    NSButton *checkNow = VBLButton(@"Check Now", self, @selector(checkNow:));
    checkNow.toolTip = @"Look at the volBrain Results page now";
    _interval = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    for (NSNumber *m in @[ @5, @10, @15, @30, @60 ]) {
        [_interval addItemWithTitle:[NSString stringWithFormat:@"Every %@ min", m]];
        _interval.lastItem.tag = [m integerValue];
    }
    [_interval selectItemWithTag:[VBLPoller pollMinutes]];
    _interval.target = self;
    _interval.action = @selector(intervalChanged:);
    _interval.toolTip = @"How often the plugin looks at the Results page while a job is waiting";
    _pollStatus = [NSTextField labelWithString:@""];
    _pollStatus.textColor = [NSColor secondaryLabelColor];
    _pollStatus.lineBreakMode = NSLineBreakByTruncatingTail;
    [_pollStatus setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSStackView *buttons = [NSStackView stackViewWithViews:@[ prepare, _importButton, _revealButton, _removeButton, checkNow, _interval, _pollStatus ]];
    buttons.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    buttons.spacing = 8;
    buttons.translatesAutoresizingMaskIntoConstraints = NO;

    NSView *bottom = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 1200, 240)];
    [bottom addSubview:titleRow];
    [bottom addSubview:scroll];
    [bottom addSubview:buttons];
    [NSLayoutConstraint activateConstraints:@[
        [titleRow.topAnchor constraintEqualToAnchor:bottom.topAnchor constant:8],
        [titleRow.leadingAnchor constraintEqualToAnchor:bottom.leadingAnchor constant:10],
        [titleRow.trailingAnchor constraintLessThanOrEqualToAnchor:bottom.trailingAnchor constant:-10],
        [scroll.topAnchor constraintEqualToAnchor:titleRow.bottomAnchor constant:6],
        [scroll.leadingAnchor constraintEqualToAnchor:bottom.leadingAnchor constant:10],
        [scroll.trailingAnchor constraintEqualToAnchor:bottom.trailingAnchor constant:-10],
        [scroll.heightAnchor constraintGreaterThanOrEqualToConstant:70],
        [buttons.topAnchor constraintEqualToAnchor:scroll.bottomAnchor constant:8],
        [buttons.leadingAnchor constraintEqualToAnchor:bottom.leadingAnchor constant:10],
        [buttons.trailingAnchor constraintLessThanOrEqualToAnchor:bottom.trailingAnchor constant:-10],
        [buttons.bottomAnchor constraintEqualToAnchor:bottom.bottomAnchor constant:-10],
    ]];

    NSSplitView *split = [[NSSplitView alloc] initWithFrame:NSMakeRect(0, 0, 1200, 920)];
    split.vertical = NO;
    split.dividerStyle = NSSplitViewDividerStyleThin;
    [split addArrangedSubview:top];
    [split addArrangedSubview:bottom];
    [split setHoldingPriority:NSLayoutPriorityDefaultLow - 1 forSubviewAtIndex:0];
    [split setHoldingPriority:NSLayoutPriorityDefaultLow + 1 forSubviewAtIndex:1];
    window.contentView = split;

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(jobsChanged:) name:VBLJobsChangedNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(pollerChanged:) name:VBLPollerStatusChangedNotification object:nil];
    [self reloadJobs];
    [self pollerChanged:nil];
    [self updateNavigationButtons];
    return self;
}

- (void)showWindowAndSelectJob:(NSString *)jobID
{
    if (!_loadedOnce) {
        _loadedOnce = YES;
        // Put the saved volBrain login back before the first page is requested.
        [VBLCookies restoreThen:^{
            [self->_web loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:VBLHomeURL]]];
        }];
        [self showWindow:nil];
        // The job list gets about 230 points; the site gets the rest.
        NSSplitView *split = (NSSplitView *)self.window.contentView;
        [split layoutSubtreeIfNeeded];
        [split setPosition:MAX(300.0, NSHeight(split.bounds) - 230.0) ofDividerAtIndex:0];
    }
    [self showWindow:nil];
    [self.window makeKeyAndOrderFront:nil];
    if (jobID) [self selectJob:jobID];
}

#pragma mark - Jobs list

- (void)reloadJobs
{
    NSString *selected = [self selectedJob][VBLJobID];
    _jobs = [[VBLJobStore sharedStore] jobs];
    [_table reloadData];
    if (selected) [self selectJob:selected];
    [self updateJobControls];
}

- (void)jobsChanged:(NSNotification *)note { [self reloadJobs]; }

- (void)pollerChanged:(NSNotification *)note
{
    VBLPoller *poller = [VBLPoller sharedPoller];
    NSUInteger today = [[VBLJobStore sharedStore] uploadsInLast24Hours];
    _pollStatus.stringValue = [NSString stringWithFormat:@"%@  Uploads in the last 24 h: %lu of 10.", poller.statusText, (unsigned long)today];
    _pollStatus.toolTip = _pollStatus.stringValue;
}

- (void)selectJob:(NSString *)jobID
{
    for (NSUInteger i = 0; i < [_jobs count]; i++)
        if ([_jobs[i][VBLJobID] isEqualToString:jobID]) {
            [_table selectRowIndexes:[NSIndexSet indexSetWithIndex:i] byExtendingSelection:NO];
            [_table scrollRowToVisible:(NSInteger)i];
            break;
        }
    [self updateJobControls];
}

- (NSDictionary *)selectedJob
{
    NSInteger row = _table.selectedRow;
    return (row >= 0 && row < (NSInteger)[_jobs count]) ? _jobs[(NSUInteger)row] : nil;
}

static NSString *VBLAgeSex(NSDictionary *job)
{
    NSString *age = job[VBLJobAgeYears] ? [job[VBLJobAgeYears] stringValue] : @"?";
    NSString *sex = [job[VBLJobPatientSex] length] ? job[VBLJobPatientSex] : @"?";
    return [NSString stringWithFormat:@"%@ / %@", age, sex];
}

- (void)updateJobControls
{
    NSDictionary *job = [self selectedJob];
    NSString *state = job[VBLJobState];
    BOOL hasReport = job && [[NSFileManager defaultManager] fileExistsAtPath:[[VBLJobStore sharedStore] reportPathForJob:job]];
    _importButton.enabled = _showingPDF || hasReport || ([state isEqualToString:VBLStateDone] && [job[VBLJobReportURL] length]);
    _revealButton.enabled = job != nil;
    _removeButton.enabled = job != nil;
    if (!job) {
        _helper.stringValue = [_jobs count] ? @"Select a series to see its details." :
            @"Open a 3D series in a viewer and choose Plugins › volBrain: Send Series (or click “Prepare Front Series”).";
        return;
    }
    if ([state isEqualToString:VBLStatePrepared])
        _helper.stringValue = [NSString stringWithFormat:@"%@ is ready. On volBrain choose the pipeline, enter age %@ and sex %@, then click the upload box: the plugin offers this file.",
                               job[VBLJobFileName], job[VBLJobAgeYears] ?: @"(unknown)", [job[VBLJobPatientSex] length] ? job[VBLJobPatientSex] : @"(unknown)"];
    else
        _helper.stringValue = [NSString stringWithFormat:@"%@ · %@ · age/sex %@", job[VBLJobFileName], job[VBLJobVolumeInfo] ?: @"", VBLAgeSex(job)];
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView { return (NSInteger)[_jobs count]; }

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)column row:(NSInteger)row
{
    NSTextField *cell = [tableView makeViewWithIdentifier:@"VBLCell" owner:self];
    if (!cell) {
        cell = [NSTextField labelWithString:@""];
        cell.identifier = @"VBLCell";
        cell.lineBreakMode = NSLineBreakByTruncatingTail;
    }
    NSDictionary *job = _jobs[(NSUInteger)row];
    NSString *key = column.identifier, *text = @"";
    if ([key isEqualToString:@"file"]) text = job[VBLJobFileName];
    else if ([key isEqualToString:@"series"]) {
        text = job[VBLJobSeriesDescription] ?: @"";
        if ([job[VBLJobPipeline] length]) text = [NSString stringWithFormat:@"%@ → %@", text, job[VBLJobPipeline]];
    }
    else if ([key isEqualToString:@"patient"]) text = [job[VBLJobPatientName] stringByReplacingOccurrencesOfString:@"^" withString:@" "] ?: @"";
    else if ([key isEqualToString:@"age"]) text = VBLAgeSex(job);
    else if ([key isEqualToString:@"state"]) {
        text = [VBLJobStore displayStateOf:job];
        if ([job[VBLJobStatusText] length] && ![job[VBLJobState] isEqualToString:VBLStateImported])
            text = [text stringByAppendingFormat:@" — %@", job[VBLJobStatusText]];
    }
    cell.stringValue = text ?: @"";
    cell.toolTip = cell.stringValue;
    return cell;
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification { [self updateJobControls]; }

#pragma mark - Actions: jobs

- (void)prepareSeriesFromViewer:(ViewerController *)viewer
{
    [self showWindowAndSelectJob:nil];
    if (!viewer) { [self alert:@"No series open" info:@"Open the 3D series (for example the T1 MPRAGE) in a viewer window first."]; return; }
    [VBLPoller requestNotificationPermission];
    [_spinner startAnimation:nil];
    _helper.stringValue = @"Converting the series to NIfTI…";
    [VBLExport prepareJobFromViewer:viewer completion:^(NSDictionary *job, NSString *error, NSString *warning) {
        [self->_spinner stopAnimation:nil];
        if (error) { [self alert:@"The series could not be prepared" info:error]; [self updateJobControls]; return; }
        [self reloadJobs];
        [self selectJob:job[VBLJobID]];
        if (warning) [self alert:@"Check the series" info:warning];
    }];
}

- (IBAction)prepareFrontSeries:(id)sender
{
    [self prepareSeriesFromViewer:[ViewerController frontMostDisplayed2DViewer]];
}

- (void)importJob:(NSDictionary *)job
{
    NSString *error = nil;
    if ([VBLExport importReportForJob:job error:&error]) {
        NSString *where = [job[VBLJobPatientName] stringByReplacingOccurrencesOfString:@"^" withString:@" "];
        [self alert:@"Report imported"
               info:[NSString stringWithFormat:@"The volBrain report is now series 9900 in the study of %@ (one image per page). Research use only: volBrain results are not validated for diagnosis.", where]];
    } else {
        [self alert:@"The report could not be imported" info:error];
    }
}

// One Import for every case: the PDF open in the web view if there is one, otherwise the report of
// the selected series (downloaded by the status check, or fetched now from its link).
- (IBAction)importSelected:(id)sender
{
    if (_showingPDF && _web.URL) { [self importShownPDF:sender]; return; }
    NSDictionary *job = [self selectedJob];
    if (!job) {
        [self alert:@"Which report?" info:@"Select the series in the list, or open its PDF report on the volBrain Results page above, then click Import."];
        return;
    }
    NSString *reportPath = [[VBLJobStore sharedStore] reportPathForJob:job];
    if ([[NSFileManager defaultManager] fileExistsAtPath:reportPath]) { [self importJob:job]; return; }
    NSURL *url = [job[VBLJobReportURL] length] ? [NSURL URLWithString:job[VBLJobReportURL]] : nil;
    if (!url) {
        [self alert:@"Open the report first" info:@"Open the PDF report of this series on the volBrain Results page above (the PDF icon in its row), then click Import Report into Viewer."];
        return;
    }
    [_spinner startAnimation:nil];
    [VBLPoller downloadPDF:url toPath:reportPath completion:^(NSString *error) {
        [self->_spinner stopAnimation:nil];
        if (error) [self alert:@"The report could not be downloaded" info:[NSString stringWithFormat:@"%@. Open it on the Results page above, then click Import again.", error]];
        else [self importJob:[[VBLJobStore sharedStore] jobWithID:job[VBLJobID]]];
    }];
}

- (IBAction)revealSelected:(id)sender
{
    NSDictionary *job = [self selectedJob];
    if (!job) return;
    VBLJobStore *store = [VBLJobStore sharedStore];
    NSString *path = [store niftiPathForJob:job];
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) path = [store directoryForJob:job];
    [[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:@[ [NSURL fileURLWithPath:path] ]];
}

- (IBAction)removeSelected:(id)sender
{
    NSDictionary *job = [self selectedJob];
    if (!job) return;
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = [NSString stringWithFormat:@"Remove %@ from the list?", job[VBLJobFileName]];
    alert.informativeText = @"Its .nii.gz file and downloaded report are deleted from this Mac. Nothing changes on volBrain or in the viewer database.";
    [alert addButtonWithTitle:@"Remove"];
    [alert addButtonWithTitle:@"Cancel"];
    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        if (response == NSAlertFirstButtonReturn) [[VBLJobStore sharedStore] removeJob:job[VBLJobID]];
    }];
}

- (IBAction)checkNow:(id)sender
{
    [_spinner startAnimation:nil];
    _pollStatus.stringValue = @"Checking volBrain…";
    [[VBLPoller sharedPoller] checkNowWithCompletion:^(NSString *summary) {
        [self->_spinner stopAnimation:nil];
        [self alert:@"volBrain checked" info:summary];
    }];
}

- (IBAction)intervalChanged:(id)sender { [VBLPoller setPollMinutes:_interval.selectedTag]; }

#pragma mark - Actions: web

- (IBAction)goBack:(id)sender { [_web goBack]; }
- (IBAction)goForward:(id)sender { [_web goForward]; }
- (IBAction)reload:(id)sender { [_web reload]; }
- (IBAction)goHome:(id)sender { [_web loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:VBLHomeURL]]]; }

- (IBAction)goResults:(id)sender
{
    NSURL *url = [VBLPoller resultsURL];
    if (url) [_web loadRequest:[NSURLRequest requestWithURL:url]];
    else [self alert:@"Results page not known yet" info:@"Click RESULTS on the volBrain site once; the plugin remembers that page. You can also open it and click “Check this page”."];
}

- (IBAction)useThisPage:(id)sender
{
    NSURL *url = _web.URL;
    if (!url || ![[url host] length]) return;
    [VBLPoller setResultsURL:url];
    [self alert:@"Status page set" info:[NSString stringWithFormat:@"While a job is waiting, the plugin looks at %@ every %ld minutes.", url.absoluteString, (long)[VBLPoller pollMinutes]]];
}

- (void)updateNavigationButtons
{
    _back.enabled = _web.canGoBack;
    _forward.enabled = _web.canGoForward;
    [self updateJobControls];
    _address.stringValue = _web.URL.absoluteString ?: @"";
}

// Asks which study a report belongs to. completion gets the chosen job (nil: cancelled).
- (void)chooseJobForReport:(void (^)(NSDictionary *job))completion
{
    NSMutableArray *candidates = [NSMutableArray array];
    for (NSDictionary *job in _jobs) if (![job[VBLJobState] isEqualToString:VBLStatePrepared]) [candidates addObject:job];
    if ([candidates count] == 0) {
        [self alert:@"No uploaded series" info:@"Reports are filed in the study of a series sent from the viewer with this plugin."];
        completion(nil);
        return;
    }
    NSPopUpButton *popup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 520, 26) pullsDown:NO];
    NSString *guess = nil;
    // The shown page may name the file; otherwise prefer the selected job.
    NSString *url = _web.URL.absoluteString ?: @"";
    for (NSDictionary *job in candidates) {
        NSString *label = [NSString stringWithFormat:@"%@ — %@ — %@", job[VBLJobFileName], job[VBLJobSeriesDescription] ?: @"",
                           [job[VBLJobPatientName] stringByReplacingOccurrencesOfString:@"^" withString:@" "] ?: @""];
        [popup addItemWithTitle:label];
        popup.lastItem.representedObject = job;
        if (!guess && [url rangeOfString:job[VBLJobID]].location != NSNotFound) guess = label;
    }
    NSDictionary *selected = [self selectedJob];
    if (guess) [popup selectItemWithTitle:guess];
    else if (selected) for (NSMenuItem *item in popup.itemArray) if ([((NSDictionary *)item.representedObject)[VBLJobID] isEqual:selected[VBLJobID]]) [popup selectItem:item];

    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Add this PDF to which study?";
    alert.informativeText = @"Choose the series that was uploaded for this report. The PDF becomes a new series in that study.";
    alert.accessoryView = popup;
    [alert addButtonWithTitle:@"Import"];
    [alert addButtonWithTitle:@"Cancel"];
    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        completion(response == NSAlertFirstButtonReturn ? popup.selectedItem.representedObject : nil);
    }];
}

- (IBAction)importShownPDF:(id)sender
{
    NSURL *url = _web.URL;
    if (!url || !_showingPDF) return;
    [self chooseJobForReport:^(NSDictionary *job) {
        if (!job) return;
        [self->_spinner startAnimation:nil];
        [VBLPoller downloadPDF:url toPath:[[VBLJobStore sharedStore] reportPathForJob:job] completion:^(NSString *error) {
            [self->_spinner stopAnimation:nil];
            if (error) { [self alert:@"The PDF could not be downloaded" info:error]; return; }
            NSMutableDictionary *changes = [NSMutableDictionary dictionaryWithObject:url.absoluteString forKey:VBLJobReportURL];
            if (![job[VBLJobState] isEqualToString:VBLStateImported]) {
                changes[VBLJobState] = VBLStateDone;
                changes[VBLJobFinished] = [NSDate date];
            }
            [[VBLJobStore sharedStore] updateJob:job[VBLJobID] with:changes];
            [self importJob:[[VBLJobStore sharedStore] jobWithID:job[VBLJobID]]];
        }];
    }];
}

#pragma mark - WKUIDelegate: the upload box

// The volBrain upload box asks for a file: offer the series prepared in the viewer.
- (void)webView:(WKWebView *)webView runOpenPanelWithParameters:(WKOpenPanelParameters *)parameters
        initiatedByFrame:(WKFrameInfo *)frame completionHandler:(void (^)(NSArray<NSURL *> *URLs))completionHandler
{
    VBLJobStore *store = [VBLJobStore sharedStore];
    NSMutableArray *ready = [NSMutableArray array];
    for (NSDictionary *job in _jobs)
        if ([[NSFileManager defaultManager] fileExistsAtPath:[store niftiPathForJob:job]]) [ready addObject:job];

    if ([ready count] == 0) { [self chooseOtherFile:parameters completion:completionHandler]; return; }

    NSPopUpButton *popup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 560, 26) pullsDown:NO];
    NSDictionary *preferred = [self selectedJob];
    if (![ready containsObject:preferred]) preferred = nil;
    for (NSDictionary *job in ready) {
        NSString *state = [job[VBLJobState] isEqualToString:VBLStatePrepared] ? @"" : @"  (uploaded before)";
        [popup addItemWithTitle:[NSString stringWithFormat:@"%@ — %@ — age %@, sex %@%@", job[VBLJobFileName], job[VBLJobSeriesDescription] ?: @"",
                                 job[VBLJobAgeYears] ?: @"?", [job[VBLJobPatientSex] length] ? job[VBLJobPatientSex] : @"?", state]];
        popup.lastItem.representedObject = job;
        if (!preferred && [job[VBLJobState] isEqualToString:VBLStatePrepared]) preferred = job;
    }
    for (NSMenuItem *item in popup.itemArray) if (item.representedObject == preferred) [popup selectItem:item];

    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Upload a series prepared in the viewer?";
    NSString *info = @"Only the anonymous file is sent: the image volume, named vbl_<random>.nii.gz, with no patient details. Enter age and sex in the volBrain form yourself if you want normative ranges.";
    if ([store uploadsInLast24Hours] >= 10) info = [info stringByAppendingString:@"\n\nvolBrain accepts 10 cases a day per user; you have uploaded 10 in the last 24 hours."];
    alert.informativeText = info;
    alert.accessoryView = popup;
    [alert addButtonWithTitle:@"Upload This File"];
    [alert addButtonWithTitle:@"Choose Another File…"];
    [alert addButtonWithTitle:@"Cancel"];
    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        if (response == NSAlertFirstButtonReturn) {
            NSDictionary *job = popup.selectedItem.representedObject;
            completionHandler(@[ [NSURL fileURLWithPath:[store niftiPathForJob:job]] ]);
            NSMutableDictionary *changes = [NSMutableDictionary dictionaryWithObject:[NSDate date] forKey:VBLJobAttached];
            NSString *state = job[VBLJobState];
            if ([state isEqualToString:VBLStatePrepared] || [state isEqualToString:VBLStateAttached] || [state isEqualToString:VBLStateGaveUp]) {
                changes[VBLJobState] = VBLStateAttached;
                changes[VBLJobStatusText] = [NSNull null];
            }
            [store updateJob:job[VBLJobID] with:changes];
            [self selectJob:job[VBLJobID]];
            [[VBLPoller sharedPoller] startIfNeeded];
        } else if (response == NSAlertSecondButtonReturn) {
            [self chooseOtherFile:parameters completion:completionHandler];
        } else {
            completionHandler(nil);
        }
    }];
}

- (void)chooseOtherFile:(WKOpenPanelParameters *)parameters completion:(void (^)(NSArray<NSURL *> *URLs))completionHandler
{
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.allowsMultipleSelection = parameters.allowsMultipleSelection;
    panel.canChooseDirectories = parameters.allowsDirectories;
    panel.canChooseFiles = YES;
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
        completionHandler(result == NSModalResponseOK ? panel.URLs : nil);
    }];
}

// Links that open a new window or tab are shown here.
- (WKWebView *)webView:(WKWebView *)webView createWebViewWithConfiguration:(WKWebViewConfiguration *)configuration
   forNavigationAction:(WKNavigationAction *)navigationAction windowFeatures:(WKWindowFeatures *)windowFeatures
{
    if (navigationAction.request.URL) [webView loadRequest:navigationAction.request];
    return nil;
}

- (void)webView:(WKWebView *)webView runJavaScriptAlertPanelWithMessage:(NSString *)message
        initiatedByFrame:(WKFrameInfo *)frame completionHandler:(void (^)(void))completionHandler
{
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"volBrain";
    alert.informativeText = message ?: @"";
    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse r) { completionHandler(); }];
}

- (void)webView:(WKWebView *)webView runJavaScriptConfirmPanelWithMessage:(NSString *)message
        initiatedByFrame:(WKFrameInfo *)frame completionHandler:(void (^)(BOOL result))completionHandler
{
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"volBrain";
    alert.informativeText = message ?: @"";
    [alert addButtonWithTitle:@"OK"];
    [alert addButtonWithTitle:@"Cancel"];
    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse r) { completionHandler(r == NSAlertFirstButtonReturn); }];
}

#pragma mark - WKNavigationDelegate

- (void)webView:(WKWebView *)webView decidePolicyForNavigationResponse:(WKNavigationResponse *)navigationResponse
        decisionHandler:(void (^)(WKNavigationResponsePolicy))decisionHandler
{
    NSURLResponse *response = navigationResponse.response;
    if (navigationResponse.isForMainFrame)
        _showingPDF = [[response.MIMEType lowercaseString] isEqualToString:@"application/pdf"];
    if (navigationResponse.canShowMIMEType) { decisionHandler(WKNavigationResponsePolicyAllow); return; }

    // Files the web view cannot show (CSV, archives of segmentations): save them to Downloads.
    decisionHandler(WKNavigationResponsePolicyCancel);
    NSURL *url = response.URL;
    if (!url) return;
    [_spinner startAnimation:nil];
    [VBLPoller downloadURL:url completion:^(NSData *data, NSString *name, NSString *error) {
        [self->_spinner stopAnimation:nil];
        if (error) { [self alert:@"Download failed" info:error]; return; }
        NSString *downloads = [NSSearchPathForDirectoriesInDomains(NSDownloadsDirectory, NSUserDomainMask, YES) firstObject];
        NSString *base = [name length] ? [name lastPathComponent] : @"volBrain-download";
        NSString *path = [downloads stringByAppendingPathComponent:base];
        for (int i = 2; [[NSFileManager defaultManager] fileExistsAtPath:path]; i++)
            path = [downloads stringByAppendingPathComponent:[NSString stringWithFormat:@"%@ %d.%@", [base stringByDeletingPathExtension], i, [base pathExtension]]];
        if ([data writeToFile:path atomically:YES])
            [[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:@[ [NSURL fileURLWithPath:path] ]];
        else
            [self alert:@"Download failed" info:@"The file could not be saved in Downloads."];
    }];
}

- (void)webView:(WKWebView *)webView didStartProvisionalNavigation:(WKNavigation *)navigation
{
    [_spinner startAnimation:nil];
}

- (void)webView:(WKWebView *)webView didCommitNavigation:(WKNavigation *)navigation { [self updateNavigationButtons]; }

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation
{
    [_spinner stopAnimation:nil];
    [self updateNavigationButtons];
    NSURL *url = webView.URL;
    NSString *path = [[url path] lowercaseString];
    BOOL onVolBrain = [[[url host] lowercaseString] hasSuffix:@"volbrain.net"];
    BOOL loginPage = onVolBrain && ([path hasPrefix:@"/auth"] || [path rangeOfString:@"login"].location != NSNotFound);
    [VBLPoller sharedPoller].visiblePageIsLogin = loginPage;
    if (onVolBrain) {
        [VBLCookies save];
        if (!loginPage) [[VBLPoller sharedPoller] userMayHaveLoggedIn];
        else _helper.stringValue = @"Log in to volBrain. Tick “Remember Me” so that you stay logged in; the plugin also keeps the login in your Keychain.";
    }
    // Learn the Results page the first time it is opened, unless one was set by hand.
    if (![VBLPoller resultsURL] && [[url host] hasSuffix:@"volbrain.net"]
        && ([path rangeOfString:@"result"].location != NSNotFound || [path rangeOfString:@"job"].location != NSNotFound)) {
        [VBLPoller setResultsURL:url];
        _helper.stringValue = [NSString stringWithFormat:@"Status checks will use this page: %@", url.absoluteString];
    }
}

- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error
{
    [_spinner stopAnimation:nil];
    [self updateNavigationButtons];
}

- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error
{
    [_spinner stopAnimation:nil];
    [self updateNavigationButtons];
    if ([error.domain isEqualToString:NSURLErrorDomain] && error.code != NSURLErrorCancelled)
        [self alert:@"volBrain could not be reached" info:error.localizedDescription];
}

#pragma mark - Helpers

- (void)alert:(NSString *)title info:(NSString *)info
{
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = title ?: @"";
    alert.informativeText = info ?: @"";
    if (self.window.isVisible && !self.window.attachedSheet)
        [alert beginSheetModalForWindow:self.window completionHandler:nil];
    else
        [alert runModal];
}

@end
