//
//  VBLPoller.h — infrequent status checks of the volBrain Results page, report download, notifications.
//
//  Every few minutes (10 by default, never less than 5), and only while a job is waiting, the
//  Results page is loaded once in a hidden web view that shares the login of the volBrain window.
//  The row that shows the job's file name (vbl_<id>.nii.gz) is read: no row yet = waiting, a row
//  without a report = processing, a PDF/report link = done (the PDF is then downloaded once).
//

#import <Foundation/Foundation.h>

extern NSString * const VBLPollerStatusChangedNotification;
extern NSString * const VBLReportReadyNotification;   // userInfo: @"jobID"
extern NSString * const VBLOpenJobNotification;       // a notification was clicked; userInfo: @"jobID"
extern NSString * const VBLDefaultsResultsURL;   // NSUserDefaults key: the page with the list of jobs
extern NSString * const VBLDefaultsPollMinutes;  // NSUserDefaults key: minutes between checks

@interface VBLPoller : NSObject

+ (instancetype)sharedPoller;

@property (nonatomic, readonly) NSString *statusText;   // "Next check 14:32", "Log in to volBrain", ...
@property (nonatomic, readonly) NSDate *lastCheck;
@property (nonatomic, readonly) BOOL needsLogin;

+ (NSURL *)resultsURL;                    // nil until known
+ (void)setResultsURL:(NSURL *)url;       // also restarts the checks
+ (NSInteger)pollMinutes;                 // 5...60, default 10
+ (void)setPollMinutes:(NSInteger)minutes;

- (void)startIfNeeded;                    // schedules checks while jobs are waiting
- (void)checkNow;
// Checks now even between scheduled checks; completion (main thread) gets a one-line summary.
- (void)checkNowWithCompletion:(void (^)(NSString *summary))completion;

// Downloads url with the volBrain login (cookies of the web views) into path; must be a PDF.
// completion on the main thread, error nil on success.
+ (void)downloadURL:(NSURL *)url completion:(void (^)(NSData *data, NSString *suggestedName, NSString *error))completion;
+ (void)downloadPDF:(NSURL *)url toPath:(NSString *)path completion:(void (^)(NSString *error))completion;

+ (void)requestNotificationPermission;
+ (void)notifyWithTitle:(NSString *)title body:(NSString *)body;
+ (void)notifyWithTitle:(NSString *)title body:(NSString *)body jobID:(NSString *)jobID;

@end
