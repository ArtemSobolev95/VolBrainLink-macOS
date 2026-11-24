//
//  VBLExport.h — series → anonymous .nii.gz for volBrain; volBrain PDF report → DICOM in the database.
//

#import <Foundation/Foundation.h>

@class ViewerController;

@interface VBLExport : NSObject

// Copies the series shown in the viewer (current time frame), writes Jobs/<id>/vbl_<id>.nii.gz in the
// background and adds the job to the store. Main thread. completion runs on the main thread with
// the new job, or an error message; warning is set for series volBrain is unlikely to handle well.
+ (void)prepareJobFromViewer:(ViewerController *)viewer
                  completion:(void (^)(NSDictionary *job, NSString *error, NSString *warning))completion;

// Wraps Jobs/<id>/report.pdf as an Encapsulated PDF DICOM in the job's study and adds it to the
// database of the viewer. Main thread. Returns NO with a message on failure.
+ (BOOL)importReportForJob:(NSDictionary *)job error:(NSString **)error;

@end
