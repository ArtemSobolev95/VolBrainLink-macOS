//
//  VBLJobStore.h — the list of series prepared for volBrain and what happened to them.
//  Kept in ~/Library/Application Support/VolBrainLink/jobs.plist. Patient details stay on this Mac;
//  they are needed to file the report in the right study and are never sent anywhere.
//

#import <Foundation/Foundation.h>

extern NSString * const VBLJobsChangedNotification;

// Appends a line to ~/Library/Application Support/VolBrainLink/log.txt (kept under ~500 KB).
// No patient details go in it: jobs are named by their vbl_<id>.
void VBLLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);

// Job keys
extern NSString * const VBLJobID;            // "3fa2c91e"
extern NSString * const VBLJobFileName;      // "vbl_3fa2c91e.nii.gz" (the only name volBrain sees)
extern NSString * const VBLJobState;         // see VBLState*
extern NSString * const VBLJobCreated;       // NSDate
extern NSString * const VBLJobAttached;      // NSDate: file handed to the volBrain upload form
extern NSString * const VBLJobFinished;      // NSDate
extern NSString * const VBLJobImported;      // NSDate
extern NSString * const VBLJobStatusText;    // last text seen next to the file on the results page
extern NSString * const VBLJobPipeline;      // pipeline name read from the results page, if found
extern NSString * const VBLJobReportURL;     // link to the PDF report
extern NSString * const VBLJobSeriesDescription, * const VBLJobSeriesNumber, * const VBLJobModality;
extern NSString * const VBLJobVolumeInfo;    // "176×256×256, 1.0×1.0×1.0 mm"
extern NSString * const VBLJobAgeYears;      // NSNumber, age at the study date (helper for the form)
extern NSString * const VBLJobPatientSex;    // "M" / "F" / ""
// Study details, used only to file the report:
extern NSString * const VBLJobPatientName, * const VBLJobPatientID, * const VBLJobBirthDate,
                * const VBLJobStudyUID, * const VBLJobStudyDate, * const VBLJobStudyTime,
                * const VBLJobStudyID, * const VBLJobAccession, * const VBLJobReferring,
                * const VBLJobStudyDescription;

extern NSString * const VBLStatePrepared;    // file ready, not yet attached
extern NSString * const VBLStateAttached;    // given to the upload form; waiting to appear in Results
extern NSString * const VBLStateRunning;     // seen on the Results page, no report yet
extern NSString * const VBLStateDone;        // report link found
extern NSString * const VBLStateFailed;      // the Results page says it failed
extern NSString * const VBLStateImported;    // report filed in the viewer database
extern NSString * const VBLStateGaveUp;      // not finished after 48 h: status checks stopped

@interface VBLJobStore : NSObject

+ (instancetype)sharedStore;

@property (nonatomic, readonly) NSString *supportDirectory;  // ~/Library/Application Support/VolBrainLink
- (NSString *)directoryForJob:(NSDictionary *)job;           // .../Jobs/<id>
- (NSString *)niftiPathForJob:(NSDictionary *)job;
- (NSString *)reportPathForJob:(NSDictionary *)job;          // .../Jobs/<id>/report.pdf

- (NSArray<NSDictionary *> *)jobs;                           // newest first
- (NSDictionary *)jobWithID:(NSString *)jobID;
- (NSArray<NSDictionary *> *)jobsNeedingStatusChecks;        // attached or running, not too old
- (NSUInteger)uploadsInLast24Hours;

- (NSString *)newJobID;
- (void)addJob:(NSDictionary *)job;
- (void)updateJob:(NSString *)jobID with:(NSDictionary *)changes;  // NSNull value removes a key
- (void)removeJob:(NSString *)jobID;                             // also deletes its files

+ (NSString *)displayStateOf:(NSDictionary *)job;

@end
