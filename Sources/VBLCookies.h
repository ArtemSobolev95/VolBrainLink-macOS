//
//  VBLCookies.h — keeps the volBrain login across restarts of the viewer.
//
//  The web view's own cookie storage is written to disk only from time to time, so a login is often
//  lost when the viewer quits. The volbrain.net cookies are therefore also saved in the macOS
//  Keychain (as a password item of the viewer, "VolBrainLink volBrain login") after every page load,
//  and put back into the web views before the first page is loaded. No password is stored: only the
//  site's session cookies, which volBrain itself expires.
//

#import <Foundation/Foundation.h>

@interface VBLCookies : NSObject

+ (void)restoreThen:(void (^)(void))completion;   // once per launch; completion on the main thread
+ (void)save;                                     // after a page load; cheap, asynchronous
+ (void)forget;                                   // removes the saved login (e.g. after logging out)

@end
