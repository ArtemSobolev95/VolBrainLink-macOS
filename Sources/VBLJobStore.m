//
//  VBLJobStore.m
//

#import "VBLJobStore.h"
#import <Security/Security.h>

NSString * const VBLJobsChangedNotification = @"VBLJobsChangedNotification";

NSString * const VBLJobID = @"id";
NSString * const VBLJobFileName = @"fileName";
NSString * const VBLJobState = @"state";
NSString * const VBLJobCreated = @"created";
NSString * const VBLJobAttached = @"attached";
NSString * const VBLJobFinished = @"finished";
NSString * const VBLJobImported = @"imported";
NSString * const VBLJobStatusText = @"statusText";
NSString * const VBLJobPipeline = @"pipeline";
NSString * const VBLJobReportURL = @"reportURL";
NSString * const VBLJobSeriesDescription = @"seriesDescription";
NSString * const VBLJobSeriesNumber = @"seriesNumber";
NSString * const VBLJobModality = @"modality";
NSString * const VBLJobVolumeInfo = @"volumeInfo";
NSString * const VBLJobAgeYears = @"ageYears";
NSString * const VBLJobPatientSex = @"patientSex";
NSString * const VBLJobPatientName = @"patientName";
NSString * const VBLJobPatientID = @"patientID";
NSString * const VBLJobBirthDate = @"birthDate";
NSString * const VBLJobStudyUID = @"studyInstanceUID";
NSString * const VBLJobStudyDate = @"studyDate";
NSString * const VBLJobStudyTime = @"studyTime";
NSString * const VBLJobStudyID = @"studyID";
NSString * const VBLJobAccession = @"accessionNumber";
NSString * const VBLJobReferring = @"referringPhysician";
NSString * const VBLJobStudyDescription = @"studyDescription";

NSString * const VBLStatePrepared = @"prepared";
NSString * const VBLStateAttached = @"attached";
NSString * const VBLStateRunning = @"running";
NSString * const VBLStateDone = @"done";
NSString * const VBLStateFailed = @"failed";
NSString * const VBLStateImported = @"imported";
NSString * const VBLStateGaveUp = @"gaveUp";

// Status checks: a job handed to the upload form is looked for on the Results page for this long
// (if it never shows up, it was probably not submitted); a job seen there is followed for 48 h.
static const NSTimeInterval VBLAttachedCheckWindow = 6 * 3600;
static const NSTimeInterval VBLRunningCheckWindow = 48 * 3600;

void VBLLog(NSString *format, ...)
{
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    static NSDateFormatter *formatter;
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        formatter = [[NSDateFormatter alloc] init];
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss";
        queue = dispatch_queue_create("VolBrainLink.log", DISPATCH_QUEUE_SERIAL);
    });
    NSString *line = [NSString stringWithFormat:@"%@  %@\n", [formatter stringFromDate:[NSDate date]], message];
    NSString *path = [[[VBLJobStore sharedStore] supportDirectory] stringByAppendingPathComponent:@"log.txt"];
    dispatch_async(queue, ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        NSDictionary *attributes = [fm attributesOfItemAtPath:path error:NULL];
        if ([attributes fileSize] > 500 * 1024) {
            NSString *old = [path stringByAppendingString:@".1"];
            [fm removeItemAtPath:old error:NULL];
            [fm moveItemAtPath:path toPath:old error:NULL];
        }
        if (![fm fileExistsAtPath:path]) [fm createFileAtPath:path contents:nil attributes:nil];
        NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
        [handle seekToEndOfFile];
        [handle writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [handle closeFile];
    });
}

@implementation VBLJobStore {
    NSMutableArray<NSMutableDictionary *> *_jobs;
    NSString *_supportDirectory;
}

+ (instancetype)sharedStore
{
    static VBLJobStore *store;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ store = [[VBLJobStore alloc] init]; });
    return store;
}

- (instancetype)init
{
    if ((self = [super init])) {
        NSString *base = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES) firstObject];
        _supportDirectory = [base stringByAppendingPathComponent:@"VolBrainLink"];
        [[NSFileManager defaultManager] createDirectoryAtPath:[_supportDirectory stringByAppendingPathComponent:@"Jobs"]
                                  withIntermediateDirectories:YES attributes:nil error:NULL];
        _jobs = [NSMutableArray array];
        NSArray *saved = [NSArray arrayWithContentsOfFile:[self plistPath]];
        for (NSDictionary *job in saved)
            if ([job isKindOfClass:[NSDictionary class]] && [job[VBLJobID] length])
                [_jobs addObject:[job mutableCopy]];
    }
    return self;
}

- (NSString *)supportDirectory { return _supportDirectory; }
- (NSString *)plistPath { return [_supportDirectory stringByAppendingPathComponent:@"jobs.plist"]; }

- (NSString *)directoryForJob:(NSDictionary *)job
{
    return [[_supportDirectory stringByAppendingPathComponent:@"Jobs"] stringByAppendingPathComponent:job[VBLJobID]];
}

- (NSString *)niftiPathForJob:(NSDictionary *)job
{
    return [[self directoryForJob:job] stringByAppendingPathComponent:job[VBLJobFileName]];
}

- (NSString *)reportPathForJob:(NSDictionary *)job
{
    return [[self directoryForJob:job] stringByAppendingPathComponent:@"report.pdf"];
}

- (void)save
{
    [_jobs writeToFile:[self plistPath] atomically:YES];
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:VBLJobsChangedNotification object:self];
    });
}

- (NSArray<NSDictionary *> *)jobs
{
    @synchronized (self) {
        NSMutableArray *copy = [NSMutableArray arrayWithCapacity:_jobs.count];
        for (NSDictionary *job in _jobs) [copy addObject:[job copy]];
        [copy sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            return [b[VBLJobCreated] compare:a[VBLJobCreated]];
        }];
        return copy;
    }
}

- (NSMutableDictionary *)mutableJobWithID:(NSString *)jobID
{
    for (NSMutableDictionary *job in _jobs) if ([job[VBLJobID] isEqualToString:jobID]) return job;
    return nil;
}

- (NSDictionary *)jobWithID:(NSString *)jobID
{
    @synchronized (self) { return [[self mutableJobWithID:jobID] copy]; }
}

- (NSArray<NSDictionary *> *)jobsNeedingStatusChecks
{
    NSMutableArray *result = [NSMutableArray array];
    NSDate *now = [NSDate date];
    for (NSDictionary *job in [self jobs]) {
        NSString *state = job[VBLJobState];
        NSDate *attached = job[VBLJobAttached];
        if (!attached) continue;
        NSTimeInterval age = [now timeIntervalSinceDate:attached];
        if ([state isEqualToString:VBLStateAttached] && age < VBLAttachedCheckWindow) [result addObject:job];
        else if ([state isEqualToString:VBLStateRunning] && age < VBLRunningCheckWindow) [result addObject:job];
    }
    return result;
}

- (NSUInteger)uploadsInLast24Hours
{
    NSUInteger n = 0;
    NSDate *now = [NSDate date];
    for (NSDictionary *job in [self jobs]) {
        NSDate *attached = job[VBLJobAttached];
        if (attached && [now timeIntervalSinceDate:attached] < 24 * 3600) n++;
    }
    return n;
}

- (NSString *)newJobID
{
    uint8_t bytes[4];
    if (SecRandomCopyBytes(kSecRandomDefault, sizeof bytes, bytes) != errSecSuccess)
        arc4random_buf(bytes, sizeof bytes);
    NSString *jobID = [NSString stringWithFormat:@"%02x%02x%02x%02x", bytes[0], bytes[1], bytes[2], bytes[3]];
    @synchronized (self) {
        if ([self mutableJobWithID:jobID]) return [self newJobID];
    }
    return jobID;
}

- (void)addJob:(NSDictionary *)job
{
    @synchronized (self) {
        [_jobs addObject:[job mutableCopy]];
        [self save];
    }
}

- (void)updateJob:(NSString *)jobID with:(NSDictionary *)changes
{
    @synchronized (self) {
        NSMutableDictionary *job = [self mutableJobWithID:jobID];
        if (!job) return;
        [changes enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
            if (value == [NSNull null]) [job removeObjectForKey:key];
            else job[key] = value;
        }];
        [self save];
    }
}

- (void)removeJob:(NSString *)jobID
{
    @synchronized (self) {
        NSMutableDictionary *job = [self mutableJobWithID:jobID];
        if (!job) return;
        [[NSFileManager defaultManager] removeItemAtPath:[self directoryForJob:job] error:NULL];
        [_jobs removeObject:job];
        [self save];
    }
}

+ (NSString *)displayStateOf:(NSDictionary *)job
{
    NSString *state = job[VBLJobState];
    if ([state isEqualToString:VBLStatePrepared]) return @"Ready to upload";
    if ([state isEqualToString:VBLStateAttached]) {
        NSDate *attached = job[VBLJobAttached];
        if (attached && [[NSDate date] timeIntervalSinceDate:attached] >= VBLAttachedCheckWindow)
            return @"Not found on Results (submitted?)";
        return @"Uploaded — waiting for volBrain";
    }
    if ([state isEqualToString:VBLStateRunning]) return @"Processing on volBrain";
    if ([state isEqualToString:VBLStateDone]) return @"Report ready — click Import";
    if ([state isEqualToString:VBLStateFailed]) return @"Failed on volBrain";
    if ([state isEqualToString:VBLStateImported]) return @"Report imported";
    if ([state isEqualToString:VBLStateGaveUp]) return @"No result after 48 h";
    return state ?: @"";
}

@end
