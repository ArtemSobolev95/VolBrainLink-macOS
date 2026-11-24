//
//  VBLWindowController.h — the volBrain window: the real volbrain.net site in a web view (you log in,
//  choose the pipeline, type age and sex, and submit yourself) above the list of prepared series.
//

#import <Cocoa/Cocoa.h>

@class ViewerController;

@interface VBLWindowController : NSWindowController

+ (instancetype)sharedController;

- (void)showWindowAndSelectJob:(NSString *)jobID;
- (void)prepareSeriesFromViewer:(ViewerController *)viewer;   // exports, then shows the window

@end
