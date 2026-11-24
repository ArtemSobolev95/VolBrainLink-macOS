//
//  VBLPoller.m
//

#import "VBLPoller.h"
#import "VBLJobStore.h"
#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>
#import <UserNotifications/UserNotifications.h>

NSString * const VBLPollerStatusChangedNotification = @"VBLPollerStatusChangedNotification";
NSString * const VBLReportReadyNotification = @"VBLReportReadyNotification";
NSString * const VBLOpenJobNotification = @"VBLOpenJobNotification";
NSString * const VBLDefaultsResultsURL = @"VolBrainLinkResultsURL";
NSString * const VBLDefaultsPollMinutes = @"VolBrainLinkPollMinutes";

// Pipelines listed on volbrain.net (longest names first, so "AssemblyNet-AD-FTD" wins over "AssemblyNet").
static NSArray<NSString *> *VBLPipelineNames(void)
{
    return @[ @"AssemblyNet-AD-FTD", @"AssemblyNet-AD", @"BrainStructureAges", @"DeepLesionBrain", @"DeepThalamus",
              @"cognitiveTree", @"AssemblyNet", @"lesionBrain", @"DeepCERES", @"motorTree", @"vol2Brain",
              @"petBrain", @"volBrain", @"pBrain", @"CERES", @"HIPS" ];
}

// Collects, for every file stem, the text and links of the row that shows it: the table row or list
// item, or else the largest block around the name that names no other uploaded file.
static NSString * const VBLScanScript =
@"(function(stems){"
"  function niiCount(n){ var t=n.innerText||'', a=t.match(/\\.nii/g), b=t.match(/vbl_[0-9a-f]{8}/g);"
"    return Math.max(a?a.length:0, b?b.length:0); }"
"  function rowOf(el){ var n=el, best=el;"
"    for(var i=0;i<12&&n&&n!==document.body;i++){"
"      if(n.matches&&n.matches('tr,li,[role=row]')) return n;"
"      if(niiCount(n)>1) break;"      /* stop before the block that also lists other jobs */
"      best=n; n=n.parentElement; }"
"    return best; }"
"  function linksOf(r){ var out=[]; r.querySelectorAll('a[href]').forEach(function(a){"
"      out.push({href:a.href, text:[a.innerText,a.title,a.getAttribute('aria-label'),a.getAttribute('download'),"
"        (a.querySelector('img')||{}).alt,(a.querySelector('i,svg,span')||{className:''}).className].join(' ')}); });"
"    return out; }"
"  var out={url:location.href, login:!!document.querySelector('input[type=password]'), length:(document.body&&document.body.innerText||'').length, jobs:{}};"
"  var w=document.createTreeWalker(document.body,NodeFilter.SHOW_TEXT), t;"
"  while((t=w.nextNode())){ for(var i=0;i<stems.length;i++){ var s=stems[i]; if(out.jobs[s]) continue;"
"      if(t.nodeValue.indexOf(s)>=0){ var r=rowOf(t.parentElement); out.jobs[s]={text:(r.innerText||'').slice(0,600), links:linksOf(r)}; } } }"
"  for(var i=0;i<stems.length;i++){ var s=stems[i]; if(out.jobs[s]) continue;"
"    var e=document.querySelector('[title*=\"'+s+'\"],[value*=\"'+s+'\"],[data-filename*=\"'+s+'\"]');"
"    if(e){ var r=rowOf(e); out.jobs[s]={text:(r.innerText||'').slice(0,600), links:linksOf(r)}; } }"
"  return JSON.stringify(out);"
"})(%@)";

@interface VBLPoller () <WKNavigationDelegate>
@end

// Without a delegate, macOS does not show notifications while the viewer is the front app.
// Installed only when the viewer has none of its own. A click on a notification opens the job.
@interface VBLNotificationPresenter : NSObject <UNUserNotificationCenterDelegate, NSUserNotificationCenterDelegate>
@end

@implementation VBLNotificationPresenter
- (void)userNotificationCenter:(UNUserNotificationCenter *)center willPresentNotification:(UNNotification *)notification
         withCompletionHandler:(void (^)(UNNotificationPresentationOptions options))completionHandler
{
    completionHandler(UNNotificationPresentationOptionBanner | UNNotificationPresentationOptionList | UNNotificationPresentationOptionSound);
}
- (void)userNotificationCenter:(UNUserNotificationCenter *)center didReceiveNotificationResponse:(UNNotificationResponse *)response
         withCompletionHandler:(void (^)(void))completionHandler
{
    NSString *jobID = response.notification.request.content.userInfo[@"jobID"];
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSApp activateIgnoringOtherApps:YES];
        [[NSNotificationCenter defaultCenter] postNotificationName:VBLOpenJobNotification object:nil userInfo:jobID ? @{ @"jobID": jobID } : nil];
    });
    completionHandler();
}
- (BOOL)userNotificationCenter:(NSUserNotificationCenter *)center shouldPresentNotification:(NSUserNotification *)notification { return YES; }
- (void)userNotificationCenter:(NSUserNotificationCenter *)center didActivateNotification:(NSUserNotification *)notification
{
    NSString *jobID = notification.userInfo[@"jobID"];
    [NSApp activateIgnoringOtherApps:YES];
    [[NSNotificationCenter defaultCenter] postNotificationName:VBLOpenJobNotification object:nil userInfo:jobID ? @{ @"jobID": jobID } : nil];
}
@end

@implementation VBLPoller {
    NSTimer *_timer;
    WKWebView *_webView;
    NSWindow *_hiddenWindow;
    NSTimer *_timeout;
    NSArray<NSDictionary *> *_checking;
    NSInteger _scanAttempts;
    BOOL _loginNotified;
    NSString *_statusText;
    NSDate *_lastCheck;
    BOOL _needsLogin;
    void (^_completion)(NSString *summary);
}

+ (instancetype)sharedPoller
{
    static VBLPoller *poller;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ poller = [[VBLPoller alloc] init]; });
    return poller;
}

- (NSString *)statusText { return _statusText ?: @""; }
- (NSDate *)lastCheck { return _lastCheck; }
- (BOOL)needsLogin { return _needsLogin; }

- (void)setStatus:(NSString *)text
{
    _statusText = [text copy];
    [[NSNotificationCenter defaultCenter] postNotificationName:VBLPollerStatusChangedNotification object:self];
}

#pragma mark - Settings

+ (NSURL *)resultsURL
{
    NSString *s = [[NSUserDefaults standardUserDefaults] stringForKey:VBLDefaultsResultsURL];
    return [s length] ? [NSURL URLWithString:s] : nil;
}

+ (void)setResultsURL:(NSURL *)url
{
    [[NSUserDefaults standardUserDefaults] setObject:[url absoluteString] forKey:VBLDefaultsResultsURL];
    [[VBLPoller sharedPoller] startIfNeeded];
}

+ (NSInteger)pollMinutes
{
    NSInteger m = [[NSUserDefaults standardUserDefaults] integerForKey:VBLDefaultsPollMinutes];
    if (m == 0) m = 10;
    return MIN(60, MAX(5, m));
}

+ (void)setPollMinutes:(NSInteger)minutes
{
    [[NSUserDefaults standardUserDefaults] setInteger:MIN(60, MAX(5, minutes)) forKey:VBLDefaultsPollMinutes];
    VBLPoller *poller = [VBLPoller sharedPoller];
    [poller->_timer invalidate];
    poller->_timer = nil;
    [poller startIfNeeded];
}

#pragma mark - Scheduling

- (void)startIfNeeded
{
    NSAssert([NSThread isMainThread], @"main thread");
    // Jobs seen on volBrain but without a result after 48 h are no longer followed.
    for (NSDictionary *job in [[VBLJobStore sharedStore] jobs]) {
        NSDate *attached = job[VBLJobAttached];
        if ([job[VBLJobState] isEqualToString:VBLStateRunning] && attached && -[attached timeIntervalSinceNow] > 48 * 3600)
            [[VBLJobStore sharedStore] updateJob:job[VBLJobID] with:@{ VBLJobState: VBLStateGaveUp }];
    }
    NSArray *waiting = [[VBLJobStore sharedStore] jobsNeedingStatusChecks];
    if ([waiting count] == 0) {
        [_timer invalidate];
        _timer = nil;
        [self setStatus:@"No jobs waiting: status checks are off."];
        return;
    }
    [VBLPoller requestNotificationPermission];   // also installs the presenter after a restart
    if (![VBLPoller resultsURL]) {
        [self setStatus:@"Open the volBrain RESULTS page once (or click “Check this page”), so the plugin knows where to look."];
    }
    if (!_timer) {
        NSTimeInterval interval = [VBLPoller pollMinutes] * 60.0;
        _timer = [NSTimer scheduledTimerWithTimeInterval:interval target:self selector:@selector(timerFired:) userInfo:nil repeats:YES];
        _timer.tolerance = 30;
        if ([VBLPoller resultsURL]) [self setStatus:[self nextCheckText]];
    }
}

- (NSString *)nextCheckText
{
    if (!_timer) return @"";
    NSDateFormatter *f = [[NSDateFormatter alloc] init];
    f.timeStyle = NSDateFormatterShortStyle;
    f.dateStyle = NSDateFormatterNoStyle;
    return [NSString stringWithFormat:@"Next status check at %@ (every %ld min).", [f stringFromDate:_timer.fireDate], (long)[VBLPoller pollMinutes]];
}

- (void)timerFired:(NSTimer *)timer { [self checkNow]; }

- (void)checkNow { [self checkNowWithCompletion:nil]; }

- (void)checkNowWithCompletion:(void (^)(NSString *summary))completion
{
    if (_webView) {   // a check is running: report its result too
        if (completion) {
            void (^previous)(NSString *) = _completion;
            _completion = ^(NSString *summary) { if (previous) previous(summary); completion(summary); };
        }
        return;
    }
    NSArray *jobs = [[VBLJobStore sharedStore] jobsNeedingStatusChecks];
    if ([jobs count] == 0) {
        [self startIfNeeded];
        if (completion) completion(@"No uploaded job is waiting for a result.");
        return;
    }
    NSURL *url = [VBLPoller resultsURL];
    if (!url) {
        [self startIfNeeded];
        if (completion) completion(@"The Results page is not known yet: open it in the volBrain window and click “Check this page”.");
        return;
    }
    _completion = completion;
    VBLLog(@"Check: %@, %lu job(s): %@", url.absoluteString, (unsigned long)[jobs count], [[jobs valueForKey:VBLJobFileName] componentsJoinedByString:@", "]);

    _checking = jobs;
    _scanAttempts = 0;
    WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
    config.websiteDataStore = [WKWebsiteDataStore defaultDataStore];   // same login as the volBrain window
    config.applicationNameForUserAgent = @"Version/18.0 Safari/605.1.15";
    _webView = [[WKWebView alloc] initWithFrame:NSMakeRect(0, 0, 1280, 900) configuration:config];
    _webView.navigationDelegate = self;
    _hiddenWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(-10000, -10000, 1280, 900)
                                                styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:YES];
    _hiddenWindow.releasedWhenClosed = NO;
    _hiddenWindow.contentView = _webView;
    [self setStatus:@"Checking volBrain…"];
    [_webView loadRequest:[NSURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:60]];
    _timeout = [NSTimer scheduledTimerWithTimeInterval:120 target:self selector:@selector(checkTimedOut:) userInfo:nil repeats:NO];
}

- (void)finishCheckWithStatus:(NSString *)status
{
    [_timeout invalidate];
    _timeout = nil;
    [_webView stopLoading];
    _webView.navigationDelegate = nil;
    _webView = nil;
    [_hiddenWindow close];
    _hiddenWindow = nil;
    _checking = nil;
    _lastCheck = [NSDate date];
    [self startIfNeeded];
    NSDateFormatter *f = [[NSDateFormatter alloc] init];
    f.timeStyle = NSDateFormatterShortStyle;
    NSString *text = [NSString stringWithFormat:@"%@ (checked %@). %@", status, [f stringFromDate:_lastCheck], [self nextCheckText]];
    if ([[[VBLJobStore sharedStore] jobsNeedingStatusChecks] count] == 0) text = [NSString stringWithFormat:@"%@. No jobs waiting.", status];
    [self setStatus:text];
    VBLLog(@"Check result: %@", status);
    void (^completion)(NSString *) = _completion;
    _completion = nil;
    if (completion) completion(status);
}

- (void)checkTimedOut:(NSTimer *)timer { [self finishCheckWithStatus:@"volBrain did not answer"]; }

#pragma mark - WKNavigationDelegate

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation
{
    if (webView != _webView) return;
    // The list may be filled in by scripts after the page has loaded.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self scan]; });
}

- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error
{
    if (webView == _webView) [self finishCheckWithStatus:[NSString stringWithFormat:@"Could not load the Results page (%@)", error.localizedDescription]];
}

- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error
{
    if (webView == _webView) [self finishCheckWithStatus:[NSString stringWithFormat:@"Could not reach volBrain (%@)", error.localizedDescription]];
}

#pragma mark - Reading the Results page

- (void)scan
{
    if (!_webView) return;
    NSMutableArray *stems = [NSMutableArray array];
    for (NSDictionary *job in _checking) [stems addObject:[@"vbl_" stringByAppendingString:job[VBLJobID]]];
    NSData *json = [NSJSONSerialization dataWithJSONObject:stems options:0 error:NULL];
    NSString *script = [NSString stringWithFormat:VBLScanScript, [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding]];
    _scanAttempts++;
    [_webView evaluateJavaScript:script completionHandler:^(id result, NSError *error) {
        if (!self->_webView) return;
        NSDictionary *page = nil;
        if ([result isKindOfClass:[NSString class]])
            page = [NSJSONSerialization JSONObjectWithData:[result dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL];
        if (![page isKindOfClass:[NSDictionary class]]) { [self finishCheckWithStatus:@"Could not read the Results page"]; return; }
        NSDictionary *found = page[@"jobs"];
        if ([found count] < [self->_checking count] && self->_scanAttempts < 3 && ![page[@"login"] boolValue]) {
            // Slow page: look again a little later before concluding the job is not listed.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self scan]; });
            return;
        }
        [self handlePage:page];
    }];
}

- (void)handlePage:(NSDictionary *)page
{
    VBLJobStore *store = [VBLJobStore sharedStore];
    NSDictionary *found = [page[@"jobs"] isKindOfClass:[NSDictionary class]] ? page[@"jobs"] : @{};
    VBLLog(@"Page %@: login form %@, %@ characters, %lu of %lu job(s) found",
           page[@"url"], [page[@"login"] boolValue] ? @"yes" : @"no", page[@"length"], (unsigned long)[found count], (unsigned long)[_checking count]);
    [found enumerateKeysAndObjectsUsingBlock:^(NSString *stem, NSDictionary *row, BOOL *stop) {
        if (![row isKindOfClass:[NSDictionary class]]) return;
        NSMutableArray *links = [NSMutableArray array];
        for (NSDictionary *link in row[@"links"]) if ([link isKindOfClass:[NSDictionary class]]) [links addObject:[NSString stringWithFormat:@"%@ [%@]", link[@"href"], link[@"text"]]];
        VBLLog(@"  %@: \"%@\" links: %@", stem, row[@"text"], [links count] ? [links componentsJoinedByString:@" | "] : @"none");
    }];
    if ([page[@"login"] boolValue] && [found count] == 0) {
        _needsLogin = YES;
        if (!_loginNotified) {
            _loginNotified = YES;
            [VBLPoller notifyWithTitle:@"volBrain: please log in again"
                                  body:@"The plugin cannot see your Results page. Open the volBrain window in the viewer and log in."];
        }
        [self finishCheckWithStatus:@"Log in to volBrain in the volBrain window"];
        return;
    }
    _needsLogin = NO;
    _loginNotified = NO;

    NSUInteger running = 0, finished = 0;
    for (NSDictionary *job in _checking) {
        NSString *stem = [@"vbl_" stringByAppendingString:job[VBLJobID]];
        NSDictionary *row = found[stem];
        if (![row isKindOfClass:[NSDictionary class]]) continue;   // not listed (yet)
        NSString *text = [row[@"text"] isKindOfClass:[NSString class]] ? row[@"text"] : @"";
        NSString *compact = [[text componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]
                             componentsJoinedByString:@" "];
        while ([compact rangeOfString:@"  "].location != NSNotFound)
            compact = [compact stringByReplacingOccurrencesOfString:@"  " withString:@" "];
        NSMutableDictionary *changes = [NSMutableDictionary dictionaryWithObject:compact forKey:VBLJobStatusText];
        for (NSString *name in VBLPipelineNames())
            if ([text rangeOfString:name].location != NSNotFound) { changes[VBLJobPipeline] = name; break; }

        NSURL *report = [self reportLinkIn:row[@"links"]];
        NSString *lower = [compact lowercaseString];
        BOOL failed = [lower rangeOfString:@"fail"].location != NSNotFound || [lower rangeOfString:@"error"].location != NSNotFound;
        BOOL looksFinished = NO;
        for (NSString *word in @[ @"finished", @"completed", @"complete", @"success", @"done", @"ready" ])
            if ([lower rangeOfString:word].location != NSNotFound) looksFinished = YES;
        for (NSString *word in @[ @"queue", @"running", @"processing", @"pending", @"waiting" ])
            if ([lower rangeOfString:word].location != NSNotFound) looksFinished = NO;
        if (report) {
            changes[VBLJobState] = VBLStateDone;
            changes[VBLJobReportURL] = [report absoluteString];
            changes[VBLJobFinished] = [NSDate date];
            finished++;
            [store updateJob:job[VBLJobID] with:changes];
            [self downloadReportForJob:[store jobWithID:job[VBLJobID]]];
        } else if (failed) {
            changes[VBLJobState] = VBLStateFailed;
            changes[VBLJobFinished] = [NSDate date];
            [store updateJob:job[VBLJobID] with:changes];
            [VBLPoller notifyWithTitle:@"volBrain job failed"
                                  body:[NSString stringWithFormat:@"%@ — see the Results page for details.", job[VBLJobSeriesDescription] ?: job[VBLJobFileName]]
                                 jobID:job[VBLJobID]];
        } else if (looksFinished) {
            // Finished, but the report is behind a button rather than a link: the PDF is imported
            // from the Results page instead (open it in the volBrain window, then Import).
            changes[VBLJobState] = VBLStateDone;
            changes[VBLJobFinished] = [NSDate date];
            finished++;
            [store updateJob:job[VBLJobID] with:changes];
            NSString *pipeline = [changes[VBLJobPipeline] length] ? [changes[VBLJobPipeline] stringByAppendingString:@" "] : @"";
            [VBLPoller notifyWithTitle:[NSString stringWithFormat:@"volBrain %@job finished", pipeline]
                                  body:[NSString stringWithFormat:@"%@ — open the report on the Results page in the volBrain window, then click Import.", job[VBLJobSeriesDescription] ?: job[VBLJobFileName]]
                                 jobID:job[VBLJobID]];
            [[NSNotificationCenter defaultCenter] postNotificationName:VBLReportReadyNotification object:self userInfo:@{ @"jobID": job[VBLJobID] }];
        } else {
            changes[VBLJobState] = VBLStateRunning;
            running++;
            [store updateJob:job[VBLJobID] with:changes];
        }
    }
    NSString *summary = [NSString stringWithFormat:@"%lu processing, %lu finished", (unsigned long)running, (unsigned long)finished];
    [self finishCheckWithStatus:summary];
}

// The PDF report among the links of a row: a .pdf file first, then a link that says PDF or report.
- (NSURL *)reportLinkIn:(NSArray *)links
{
    if (![links isKindOfClass:[NSArray class]]) return nil;
    NSURL *best = nil;
    NSInteger bestScore = 0;
    for (NSDictionary *link in links) {
        if (![link isKindOfClass:[NSDictionary class]]) continue;
        NSString *href = [link[@"href"] isKindOfClass:[NSString class]] ? link[@"href"] : @"";
        NSURL *url = [NSURL URLWithString:href];
        if (!url || !([url.scheme isEqualToString:@"https"] || [url.scheme isEqualToString:@"http"])) continue;
        NSString *path = [[url path] lowercaseString];
        NSString *label = [[NSString stringWithFormat:@"%@ %@", link[@"text"] ?: @"", href] lowercaseString];
        if ([path hasSuffix:@".csv"] || [path hasSuffix:@".zip"] || [path hasSuffix:@".nii.gz"] || [path hasSuffix:@".gz"]) continue;
        NSInteger score = 0;
        if ([path hasSuffix:@".pdf"]) score = 3;
        else if ([label rangeOfString:@"pdf"].location != NSNotFound) score = 2;
        else if ([label rangeOfString:@"report"].location != NSNotFound && [label rangeOfString:@"csv"].location == NSNotFound) score = 1;
        if (score > bestScore) { bestScore = score; best = url; }
    }
    return best;
}

- (void)downloadReportForJob:(NSDictionary *)job
{
    NSURL *url = [NSURL URLWithString:job[VBLJobReportURL] ?: @""];
    if (!url) return;
    NSString *what = [job[VBLJobSeriesDescription] length] ? job[VBLJobSeriesDescription] : job[VBLJobFileName];
    NSString *pipeline = [job[VBLJobPipeline] length] ? [job[VBLJobPipeline] stringByAppendingString:@" "] : @"";
    [VBLPoller downloadPDF:url toPath:[[VBLJobStore sharedStore] reportPathForJob:job] completion:^(NSString *error) {
        if (error) {
            [[VBLJobStore sharedStore] updateJob:job[VBLJobID] with:@{ VBLJobStatusText: [NSString stringWithFormat:@"Finished, but the report could not be downloaded automatically (%@). Open it on the Results page in the volBrain window and click Import.", error] }];
            VBLLog(@"Report download failed for vbl_%@: %@", job[VBLJobID], error);
            [VBLPoller notifyWithTitle:@"volBrain job finished"
                                  body:[NSString stringWithFormat:@"%@: open the %@report on the Results page in the volBrain window, then click Import.", what, pipeline]
                                 jobID:job[VBLJobID]];
        } else {
            VBLLog(@"Report downloaded for vbl_%@", job[VBLJobID]);
            [VBLPoller notifyWithTitle:[NSString stringWithFormat:@"volBrain %@report ready", pipeline]
                                  body:[NSString stringWithFormat:@"%@ — click to open, then Import adds it to the study.", what]
                                 jobID:job[VBLJobID]];
        }
        [[NSNotificationCenter defaultCenter] postNotificationName:VBLReportReadyNotification object:self userInfo:@{ @"jobID": job[VBLJobID] }];
    }];
}

#pragma mark - Download

+ (void)downloadURL:(NSURL *)url completion:(void (^)(NSData *data, NSString *suggestedName, NSString *error))completion
{
    WKHTTPCookieStore *cookieStore = [WKWebsiteDataStore defaultDataStore].httpCookieStore;
    [cookieStore getAllCookies:^(NSArray<NSHTTPCookie *> *cookies) {
        NSMutableArray *matching = [NSMutableArray array];
        NSString *host = [[url host] lowercaseString];
        for (NSHTTPCookie *cookie in cookies) {
            NSString *domain = [[cookie domain] lowercaseString];
            if ([domain hasPrefix:@"."]) domain = [domain substringFromIndex:1];
            if ([host isEqualToString:domain] || [host hasSuffix:[@"." stringByAppendingString:domain]]) [matching addObject:cookie];
        }
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:300];
        [[NSHTTPCookie requestHeaderFieldsWithCookies:matching] enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *value, BOOL *stop) {
            [request setValue:value forHTTPHeaderField:key];
        }];
        [request setValue:@"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15" forHTTPHeaderField:@"User-Agent"];
        NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        config.HTTPShouldSetCookies = NO;
        NSURLSession *session = [NSURLSession sessionWithConfiguration:config];
        [[session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            NSString *problem = nil;
            NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]] ? [(NSHTTPURLResponse *)response statusCode] : 200;
            if (error) problem = error.localizedDescription;
            else if (status >= 400) problem = [NSString stringWithFormat:@"HTTP %ld", (long)status];
            NSString *name = [response suggestedFilename] ?: [url lastPathComponent];
            [session finishTasksAndInvalidate];
            dispatch_async(dispatch_get_main_queue(), ^{ completion(problem ? nil : data, name, problem); });
        }] resume];
    }];
}

+ (void)downloadPDF:(NSURL *)url toPath:(NSString *)path completion:(void (^)(NSString *error))completion
{
    [self downloadURL:url completion:^(NSData *data, NSString *suggestedName, NSString *error) {
        if (error) { completion(error); return; }
        if ([data length] < 5 || memcmp([data bytes], "%PDF", 4) != 0) { completion(@"the link did not return a PDF"); return; }
        if (![data writeToFile:path atomically:YES]) { completion(@"could not save the file"); return; }
        completion(nil);
    }];
}

#pragma mark - Notifications

static VBLNotificationPresenter *VBLPresenter(void)
{
    static VBLNotificationPresenter *presenter;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ presenter = [[VBLNotificationPresenter alloc] init]; });
    return presenter;
}

+ (void)requestNotificationPermission
{
    if (![[NSBundle mainBundle] bundleIdentifier]) return;
    UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
    if (!center.delegate) center.delegate = VBLPresenter();
    NSUserNotificationCenter *legacy = [NSUserNotificationCenter defaultUserNotificationCenter];
    if (!legacy.delegate) legacy.delegate = VBLPresenter();
    [center requestAuthorizationWithOptions:(UNAuthorizationOptionAlert | UNAuthorizationOptionSound)
                          completionHandler:^(BOOL granted, NSError *error) {
        VBLLog(@"Notification permission: %@%@", granted ? @"granted" : @"not granted",
               error ? [@" — " stringByAppendingString:error.localizedDescription] : @"");
    }];
}

+ (void)notifyWithTitle:(NSString *)title body:(NSString *)body { [self notifyWithTitle:title body:body jobID:nil]; }

// The older notification API, which also works for viewers that macOS does not allow to use the
// current one (an app without a full code signature, as the GitHub build of IsiX may be).
+ (void)deliverLegacyNotificationWithTitle:(NSString *)title body:(NSString *)body jobID:(NSString *)jobID
{
    NSUserNotificationCenter *center = [NSUserNotificationCenter defaultUserNotificationCenter];
    if (!center.delegate) center.delegate = VBLPresenter();
    NSUserNotification *note = [[NSUserNotification alloc] init];
    note.title = title;
    note.informativeText = body ?: @"";
    note.soundName = NSUserNotificationDefaultSoundName;
    if (jobID) note.userInfo = @{ @"jobID": jobID };
    [center deliverNotification:note];
    VBLLog(@"Notification delivered (legacy API): %@", title);
}

+ (void)notifyWithTitle:(NSString *)title body:(NSString *)body jobID:(NSString *)jobID
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSApp requestUserAttention:NSInformationalRequest];
        if (![[NSBundle mainBundle] bundleIdentifier]) { [self deliverLegacyNotificationWithTitle:title body:body jobID:jobID]; return; }
        UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
        if (!center.delegate) center.delegate = VBLPresenter();
        [center getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings *settings) {
            BOOL allowed = settings.authorizationStatus == UNAuthorizationStatusAuthorized
                        || settings.authorizationStatus == UNAuthorizationStatusProvisional;
            if (!allowed) {
                VBLLog(@"Notifications not authorised (status %ld): using the legacy API", (long)settings.authorizationStatus);
                dispatch_async(dispatch_get_main_queue(), ^{ [self deliverLegacyNotificationWithTitle:title body:body jobID:jobID]; });
                return;
            }
            UNMutableNotificationContent *content = [[UNMutableNotificationContent alloc] init];
            content.title = title;
            content.body = body ?: @"";
            content.sound = [UNNotificationSound defaultSound];
            if (jobID) content.userInfo = @{ @"jobID": jobID };
            UNNotificationRequest *request = [UNNotificationRequest requestWithIdentifier:[[NSUUID UUID] UUIDString] content:content trigger:nil];
            [center addNotificationRequest:request withCompletionHandler:^(NSError *error) {
                if (error) {
                    VBLLog(@"Notification failed (%@): using the legacy API", error.localizedDescription);
                    dispatch_async(dispatch_get_main_queue(), ^{ [self deliverLegacyNotificationWithTitle:title body:body jobID:jobID]; });
                } else {
                    VBLLog(@"Notification delivered: %@", title);
                }
            }];
        }];
    });
}

@end
