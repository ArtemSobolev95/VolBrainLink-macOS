//
//  VBLExport.m
//

#import "VBLExport.h"
#import "VBLJobStore.h"
#import "VBLNifti.h"
#import "VBLPdfDicom.h"
#import "VBLPDFRaster.h"
#import <Cocoa/Cocoa.h>
#import <OsiriXAPI/ViewerController.h>
#import <OsiriXAPI/DCMPix.h>
#include <math.h>

// The database API is declared here instead of importing DicomDatabase.h, whose dependencies differ
// between IsiX and Horos. Every call is checked with -respondsToSelector: first.
@interface NSObject (VBLDicomDatabase)
+ (id)activeLocalDatabase;
- (NSArray *)addFilesAtPaths:(NSArray *)paths postNotifications:(BOOL)postNotifications dicomOnly:(BOOL)dicomOnly
         rereadExistingItems:(BOOL)rereadExistingItems generatedByOsiriX:(BOOL)generatedByOsiriX;
- (NSArray *)addFilesAtPaths:(NSArray *)paths;
- (NSString *)incomingDirPath;
- (const char *)incomingDirPathC;
- (NSInteger)importFilesFromIncomingDir;
@end

static NSString *VBLString(id value)
{
    if ([value isKindOfClass:[NSString class]]) return value;
    if ([value isKindOfClass:[NSNumber class]]) return [value stringValue];
    return @"";
}

static id VBLValue(id object, NSString *key)
{
    @try { return [object valueForKey:key]; }
    @catch (NSException *e) { return nil; }
}

// Patient Name exactly as stored in the source file (the database shows it with spaces instead of ^),
// so the report lands under the same patient. nil when it cannot be read.
@interface NSObject (VBLDCMObject)
+ (id)objectWithContentsOfFile:(NSString *)file decodingPixelData:(BOOL)decodePixelData;
- (id)attributeValueWithName:(NSString *)name;
@end

static NSString *VBLPatientNameFromFile(NSString *path)
{
    Class dcmObject = NSClassFromString(@"DCMObject");
    if (![path length] || ![dcmObject respondsToSelector:@selector(objectWithContentsOfFile:decodingPixelData:)]) return nil;
    @try {
        id object = [dcmObject objectWithContentsOfFile:path decodingPixelData:NO];
        id name = [object respondsToSelector:@selector(attributeValueWithName:)] ? [object attributeValueWithName:@"PatientsName"] : nil;
        return [name isKindOfClass:[NSString class]] && [name length] ? name : nil;
    }
    @catch (NSException *e) { return nil; }
}

static NSString *VBLFormatDate(NSDate *date, NSString *format)
{
    if (![date isKindOfClass:[NSDate class]]) return @"";
    NSDateFormatter *f = [[NSDateFormatter alloc] init];
    f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    f.dateFormat = format;
    return [f stringFromDate:date];
}

@implementation VBLExport

+ (void)prepareJobFromViewer:(ViewerController *)viewer
                  completion:(void (^)(NSDictionary *job, NSString *error, NSString *warning))completion
{
    NSArray *pixList = [viewer pixList];
    if ([pixList count] < 2) { completion(nil, @"Open a 3D series (a T1 volume, for example): this one has a single image.", nil); return; }

    DCMPix *first = [pixList objectAtIndex:0];
    if ([VBLValue(first, @"isRGB") boolValue]) { completion(nil, @"This is a colour series. volBrain needs a greyscale MR volume.", nil); return; }
    long nx = [first pwidth], ny = [first pheight];
    double o[9];
    [first orientationDouble:o];
    double normal[3] = { o[1] * o[5] - o[2] * o[4], o[2] * o[3] - o[0] * o[5], o[0] * o[4] - o[1] * o[3] };

    // Images in order along the slice normal, whatever order the viewer shows them in.
    NSMutableArray *sorted = [NSMutableArray arrayWithCapacity:[pixList count]];
    for (DCMPix *pix in pixList) {
        if ([pix pwidth] != nx || [pix pheight] != ny) { completion(nil, @"The images of this series do not all have the same size. Open a single 3D series.", nil); return; }
        double p[9];
        [pix orientationDouble:p];
        double dot = p[0] * o[0] + p[1] * o[1] + p[2] * o[2] + p[3] * o[3] + p[4] * o[4] + p[5] * o[5];
        if (dot < 1.98) { completion(nil, @"The images of this series do not all have the same orientation (a localizer or a mixed series?).", nil); return; }
        if (![pix fImage]) { completion(nil, @"The images are not loaded yet. Wait until the series has fully loaded, then try again.", nil); return; }
        [sorted addObject:pix];
    }
    const double n0 = normal[0], n1 = normal[1], n2 = normal[2];   // blocks cannot capture C arrays
    [sorted sortUsingComparator:^NSComparisonResult(DCMPix *a, DCMPix *b) {
        double pa = a.originX * n0 + a.originY * n1 + a.originZ * n2;
        double pb = b.originX * n0 + b.originY * n1 + b.originZ * n2;
        return pa < pb ? NSOrderedAscending : (pa > pb ? NSOrderedDescending : NSOrderedSame);
    }];

    long nz = (long)[sorted count];
    double minStep = INFINITY, maxStep = 0, total = 0;
    for (long k = 1; k < nz; k++) {
        DCMPix *a = sorted[k - 1], *b = sorted[k];
        double step = (b.originX - a.originX) * normal[0] + (b.originY - a.originY) * normal[1] + (b.originZ - a.originZ) * normal[2];
        minStep = MIN(minStep, step); maxStep = MAX(maxStep, step); total += step;
    }
    double meanStep = total / (nz - 1);
    if (minStep < 1e-3)
        { completion(nil, @"Several images are at the same position: this looks like a multi-echo, 4D or combined series. Open the single 3D volume.", nil); return; }
    if (maxStep - minStep > 0.1 * meanStep + 0.01)
        { completion(nil, [NSString stringWithFormat:@"The slices are not evenly spaced (%.2f–%.2f mm): images are missing or several series are mixed.", minStep, maxStep], nil); return; }

    DCMPix *bottom = sorted[0];
    double firstOrigin[3] = { bottom.originX, bottom.originY, bottom.originZ };
    DCMPix *last = [sorted lastObject];
    double lastOrigin[3] = { last.originX, last.originY, last.originZ };
    VBLNiftiGeometry geometry;
    char err[256];
    if (vbl_nifti_geometry_from_dicom(&geometry, (int)nx, (int)ny, (int)nz, firstOrigin, lastOrigin, o, o + 3,
                                      [first pixelSpacingX], [first pixelSpacingY], [first sliceThickness], err, sizeof err) != 0) {
        completion(nil, [NSString stringWithUTF8String:err], nil);
        return;
    }

    // Copy the pixels now (main thread); compress in the background.
    size_t sliceSize = (size_t)nx * (size_t)ny;
    NSMutableData *volume = [NSMutableData dataWithLength:sliceSize * (size_t)nz * sizeof(float)];
    if (!volume) { completion(nil, @"Not enough memory to copy the series.", nil); return; }
    float *dst = (float *)[volume mutableBytes];
    for (long k = 0; k < nz; k++) {
        DCMPix *pix = sorted[(NSUInteger)k];
        memcpy(dst + k * sliceSize, [pix fImage], sliceSize * sizeof(float));
    }

    // Study details, kept on this Mac to file the report later.
    id study = [viewer currentStudy];
    id series = [viewer currentSeries];
    NSDate *studyDate = VBLValue(study, @"date");
    NSDate *birth = VBLValue(study, @"dateOfBirth");
    NSString *sex = [VBLString(VBLValue(study, @"patientSex")) uppercaseString];
    if ([sex length] > 1) sex = [sex substringToIndex:1];
    NSNumber *age = nil;
    if ([birth isKindOfClass:[NSDate class]] && [studyDate isKindOfClass:[NSDate class]]) {
        NSDateComponents *c = [[NSCalendar currentCalendar] components:NSCalendarUnitYear fromDate:birth toDate:studyDate options:0];
        if (c.year >= 0 && c.year < 130) age = @(c.year);
    }
    NSString *studyUID = VBLString(VBLValue(study, @"studyInstanceUID"));
    if (![studyUID length]) { completion(nil, @"The study has no Study Instance UID, so the report could not be filed in it.", nil); return; }

    NSString *warning = nil;
    NSString *modality = VBLString(VBLValue(series, @"modality"));
    if ([modality length] && ![modality isEqualToString:@"MR"])
        warning = [NSString stringWithFormat:@"This is a %@ series. volBrain pipelines expect MRI (petBrain also takes PET).", modality];
    else if (nz < 100 || geometry.dz > 1.6 || MAX(geometry.dx, geometry.dy) > 1.6)
        warning = [NSString stringWithFormat:@"This series has %ld slices of %.1f mm (pixels %.1f×%.1f mm). volBrain expects a whole-brain 3D scan with about 1 mm voxels; results from thicker 2D slices are unreliable.",
                   nz, geometry.dz, geometry.dx, geometry.dy];

    VBLJobStore *store = [VBLJobStore sharedStore];
    NSString *jobID = [store newJobID];
    NSMutableDictionary *job = [NSMutableDictionary dictionary];
    job[VBLJobID] = jobID;
    job[VBLJobFileName] = [NSString stringWithFormat:@"vbl_%@.nii.gz", jobID];
    job[VBLJobState] = VBLStatePrepared;
    job[VBLJobCreated] = [NSDate date];
    job[VBLJobSeriesDescription] = VBLString(VBLValue(series, @"name"));
    job[VBLJobSeriesNumber] = VBLString(VBLValue(series, @"id"));
    job[VBLJobModality] = modality;
    job[VBLJobVolumeInfo] = [NSString stringWithFormat:@"%ld×%ld×%ld, %.2f×%.2f×%.2f mm", nx, ny, nz, geometry.dx, geometry.dy, geometry.dz];
    if (age) job[VBLJobAgeYears] = age;
    job[VBLJobPatientSex] = sex;
    NSString *fileName = VBLPatientNameFromFile(VBLString(VBLValue(first, @"srcFile")));
    job[VBLJobPatientName] = fileName ?: [VBLString(VBLValue(study, @"name")) stringByReplacingOccurrencesOfString:@" " withString:@"^"];
    job[VBLJobPatientID] = VBLString(VBLValue(study, @"patientID"));
    job[VBLJobBirthDate] = VBLFormatDate(birth, @"yyyyMMdd");
    job[VBLJobStudyUID] = studyUID;
    job[VBLJobStudyDate] = VBLFormatDate(studyDate, @"yyyyMMdd");
    job[VBLJobStudyTime] = VBLFormatDate(studyDate, @"HHmmss");
    job[VBLJobStudyID] = VBLString(VBLValue(study, @"id"));
    job[VBLJobAccession] = VBLString(VBLValue(study, @"accessionNumber"));
    job[VBLJobReferring] = VBLString(VBLValue(study, @"referringPhysician"));
    job[VBLJobStudyDescription] = VBLString(VBLValue(study, @"studyName"));

    NSString *dir = [store directoryForJob:job];
    NSString *path = [store niftiPathForJob:job];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        char werr[256] = "";
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
        int rc = vbl_write_nifti_gz([path fileSystemRepresentation], (const float *)[volume bytes], &geometry, werr, sizeof werr);
        NSString *writeError = rc != 0 ? [NSString stringWithUTF8String:werr] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (rc != 0) {
                [[NSFileManager defaultManager] removeItemAtPath:dir error:NULL];
                completion(nil, writeError, nil);
                return;
            }
            [store addJob:job];
            completion([job copy], nil, warning);
        });
    });
}

+ (NSString *)newUID
{
    uuid_t bytes;
    [[NSUUID UUID] getUUIDBytes:bytes];
    char uid[64];
    vbl_uid_from_uuid_bytes(bytes, uid);
    return [NSString stringWithUTF8String:uid];
}

+ (BOOL)importReportForJob:(NSDictionary *)job error:(NSString **)error
{
    VBLJobStore *store = [VBLJobStore sharedStore];
    NSData *pdf = [NSData dataWithContentsOfFile:[store reportPathForJob:job]];
    if ([pdf length] < 5) { if (error) *error = @"The report has not been downloaded yet."; return NO; }
    // The pages are filed as ordinary colour images (Secondary Capture), not as a PDF: in Dark Mode the
    // viewer inverts the colours of PDF pages, and images are shown exactly as they are.
    NSString *rasterProblem = nil;
    NSArray<NSDictionary *> *pages = VBLPDFPagesAsRGB(pdf, 150.0, &rasterProblem);
    if (!pages) VBLLog(@"Report of vbl_%@ filed as PDF, the pages could not be rendered: %@", job[VBLJobID], rasterProblem);

    NSString *pipeline = [job[VBLJobPipeline] length] ? job[VBLJobPipeline] : @"";
    NSString *title = [pipeline length] ? [NSString stringWithFormat:@"volBrain %@ report", pipeline] : @"volBrain report";
    if ([job[VBLJobSeriesDescription] length])
        title = [title stringByAppendingFormat:@" (%@)", job[VBLJobSeriesDescription]];
    NSString *seriesUID = [self newUID], *sopUID = [self newUID];
    NSDate *now = [NSDate date];
    NSString *name = job[VBLJobPatientName];
    NSString *contentDate = VBLFormatDate(now, @"yyyyMMdd"), *contentTime = VBLFormatDate(now, @"HHmmss");

    VBLPdfDicomInfo info = {
        .patientName = [name UTF8String],
        .patientID = [job[VBLJobPatientID] UTF8String],
        .patientBirthDate = [job[VBLJobBirthDate] UTF8String],
        .patientSex = [job[VBLJobPatientSex] UTF8String],
        .studyInstanceUID = [job[VBLJobStudyUID] UTF8String],
        .studyDate = [job[VBLJobStudyDate] UTF8String],
        .studyTime = [job[VBLJobStudyTime] UTF8String],
        .studyID = [job[VBLJobStudyID] UTF8String],
        .accessionNumber = [job[VBLJobAccession] UTF8String],
        .referringPhysician = [job[VBLJobReferring] UTF8String],
        .seriesInstanceUID = [seriesUID UTF8String],
        .sopInstanceUID = [sopUID UTF8String],
        .seriesNumber = 9900,
        .seriesDescription = [title UTF8String],
        .documentTitle = [title UTF8String],
        .contentDate = [contentDate UTF8String],
        .contentTime = [contentTime UTF8String],
    };

    // Written to the database's INCOMING folder when the viewer exposes it (the viewer then copies
    // it into its database); otherwise kept with the job and added in place.
    Class databaseClass = NSClassFromString(@"DicomDatabase");
    id database = [databaseClass respondsToSelector:@selector(activeLocalDatabase)] ? [databaseClass activeLocalDatabase] : nil;
    if (!database) { if (error) *error = @"The viewer database is not available."; return NO; }

    NSString *incoming = nil;
    if ([database respondsToSelector:@selector(incomingDirPath)]) incoming = [database incomingDirPath];
    else if ([database respondsToSelector:@selector(incomingDirPathC)]) {
        const char *c = [database incomingDirPathC];
        if (c && *c) incoming = [NSString stringWithUTF8String:c];
    }

    // One file per page (or one PDF), kept with the job.
    NSString *stamp = VBLFormatDate(now, @"yyyyMMdd-HHmmss");
    NSMutableArray<NSString *> *kept = [NSMutableArray array];
    char err[256] = "";
    if (pages) {
        NSInteger number = 1;
        for (NSDictionary *page in pages) {
            NSString *pageUID = number == 1 ? sopUID : [self newUID];
            info.sopInstanceUID = [pageUID UTF8String];
            NSString *path = [[store directoryForJob:job] stringByAppendingPathComponent:
                              [NSString stringWithFormat:@"volBrain_%@_%@_p%ld.dcm", job[VBLJobID], stamp, (long)number]];
            NSData *rgb = page[@"rgb"];
            if (vbl_write_sc_dicom([path fileSystemRepresentation], [rgb bytes], [page[@"width"] intValue], [page[@"height"] intValue],
                                   (int)number, &info, err, sizeof err) != 0) {
                if (error) *error = [NSString stringWithUTF8String:err];
                return NO;
            }
            [kept addObject:path];
            number++;
        }
    } else {
        NSString *path = [[store directoryForJob:job] stringByAppendingPathComponent:
                          [NSString stringWithFormat:@"volBrain_%@_%@.dcm", job[VBLJobID], stamp]];
        if (vbl_write_pdf_dicom([path fileSystemRepresentation], [pdf bytes], [pdf length], &info, err, sizeof err) != 0) {
            if (error) *error = [NSString stringWithUTF8String:err];
            return NO;
        }
        [kept addObject:path];
    }

    BOOL added = NO;
    if ([incoming length] && [[NSFileManager defaultManager] fileExistsAtPath:incoming]) {
        // Copied under a temporary name first so the viewer never picks up a half-written file.
        added = YES;
        for (NSString *path in kept) {
            NSString *fileName = [path lastPathComponent];
            NSString *tmp = [incoming stringByAppendingPathComponent:[@"." stringByAppendingString:fileName]];
            NSString *final = [incoming stringByAppendingPathComponent:fileName];
            [[NSFileManager defaultManager] removeItemAtPath:tmp error:NULL];
            if (!([[NSFileManager defaultManager] copyItemAtPath:path toPath:tmp error:NULL]
                  && [[NSFileManager defaultManager] moveItemAtPath:tmp toPath:final error:NULL])) added = NO;
        }
        if (added && [database respondsToSelector:@selector(importFilesFromIncomingDir)]) (void)[database importFilesFromIncomingDir];
    }
    if (!added) {
        if ([database respondsToSelector:@selector(addFilesAtPaths:postNotifications:dicomOnly:rereadExistingItems:generatedByOsiriX:)])
            (void)[database addFilesAtPaths:kept postNotifications:YES dicomOnly:YES rereadExistingItems:YES generatedByOsiriX:YES];
        else if ([database respondsToSelector:@selector(addFilesAtPaths:)])
            (void)[database addFilesAtPaths:kept];
        else { if (error) *error = @"This viewer version offers no way to add files to its database."; return NO; }
    }
    VBLLog(@"Report of vbl_%@ imported: %lu %@", job[VBLJobID], (unsigned long)[kept count], pages ? @"page image(s)" : @"PDF");

    [store updateJob:job[VBLJobID] with:@{ VBLJobState: VBLStateImported, VBLJobImported: now }];
    return YES;
}

@end
