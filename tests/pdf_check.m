//
//  pdf_check.m — checks the Dark Mode fix on this Mac. Takes the newest downloaded volBrain report,
//  converts it the way the plugin does, and writes into tests/out/:
//    original_page1.png      page 1 of the report drawn with no background (transparent = checkerboard)
//    pictures.pdf            the converted report (pages as pictures)
//    pictures_page1.png      page 1 of the converted report
//    result.txt              what happened
//  Run: double-click "Check PDF conversion.command".
//
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import "VBLPDFRaster.h"
#import "VBLPdfDicom.h"

static NSMutableString *report;

static void note(NSString *format, ...)
{
    va_list args; va_start(args, format);
    NSString *line = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    printf("%s\n", line.UTF8String);
    [report appendFormat:@"%@\n", line];
}

// Page 1 as PNG; checker = draw a grey checkerboard first, so transparent areas are visible.
static BOOL savePage1(NSData *pdf, NSString *path, BOOL checker)
{
    CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)pdf);
    CGPDFDocumentRef doc = CGPDFDocumentCreateWithProvider(provider);
    CGDataProviderRelease(provider);
    if (!doc || CGPDFDocumentGetNumberOfPages(doc) < 1) return NO;
    CGPDFPageRef page = CGPDFDocumentGetPage(doc, 1);
    CGRect box = CGPDFPageGetBoxRect(page, kCGPDFCropBox);
    size_t w = (size_t)(box.size.width * 1.5), h = (size_t)(box.size.height * 1.5);
    CGColorSpaceRef rgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef ctx = CGBitmapContextCreate(NULL, w, h, 8, 0, rgb, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    if (checker)
        for (size_t y = 0; y < h; y += 16)
            for (size_t x = 0; x < w; x += 16) {
                CGFloat g = ((x / 16 + y / 16) % 2) ? 0.55 : 0.75;
                CGContextSetRGBFillColor(ctx, g, g, g, 1);
                CGContextFillRect(ctx, CGRectMake(x, y, 16, 16));
            }
    CGContextScaleCTM(ctx, 1.5, 1.5);
    CGContextConcatCTM(ctx, CGPDFPageGetDrawingTransform(page, kCGPDFCropBox, CGRectMake(0, 0, box.size.width, box.size.height), 0, true));
    CGContextDrawPDFPage(ctx, page);
    CGImageRef image = CGBitmapContextCreateImage(ctx);
    CGImageDestinationRef dest = CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], CFSTR("public.png"), 1, NULL);
    CGImageDestinationAddImage(dest, image, NULL);
    BOOL ok = CGImageDestinationFinalize(dest);
    CFRelease(dest); CGImageRelease(image); CGContextRelease(ctx); CGColorSpaceRelease(rgb); CGPDFDocumentRelease(doc);
    return ok;
}

int main(int argc, const char **argv)
{
    @autoreleasepool {
        report = [NSMutableString string];
        NSString *outDir = [NSString stringWithUTF8String:argv[1]];
        [[NSFileManager defaultManager] createDirectoryAtPath:outDir withIntermediateDirectories:YES attributes:nil error:NULL];
        NSString *jobs = [@"~/Library/Application Support/VolBrainLink/Jobs" stringByExpandingTildeInPath];
        NSString *newest = nil; NSDate *newestDate = nil;
        for (NSString *job in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:jobs error:NULL]) {
            NSString *p = [[jobs stringByAppendingPathComponent:job] stringByAppendingPathComponent:@"report.pdf"];
            NSDate *d = [[NSFileManager defaultManager] attributesOfItemAtPath:p error:NULL].fileModificationDate;
            if (d && (!newestDate || [d compare:newestDate] == NSOrderedDescending)) { newest = p; newestDate = d; }
        }
        if (!newest) { note(@"No downloaded report found in %@", jobs); }
        else {
            NSData *pdf = [NSData dataWithContentsOfFile:newest];
            note(@"Report: %@ (%lu bytes)", [[newest stringByDeletingLastPathComponent] lastPathComponent], (unsigned long)pdf.length);
            note(@"original_page1.png: %@", savePage1(pdf, [outDir stringByAppendingPathComponent:@"original_page1.png"], YES) ? @"ok" : @"FAILED");
            NSString *problem = nil;
            NSData *pictures = VBLPDFAsImages(pdf, &problem);
            if (!pictures) note(@"Conversion FAILED: %@", problem);
            else {
                [pictures writeToFile:[outDir stringByAppendingPathComponent:@"pictures.pdf"] atomically:YES];
                note(@"Conversion ok: %lu bytes", (unsigned long)pictures.length);
                note(@"pictures_page1.png: %@", savePage1(pictures, [outDir stringByAppendingPathComponent:@"pictures_page1.png"], YES) ? @"ok" : @"FAILED");
            }
            // The way the plugin files the report now: one Secondary Capture image per page.
            NSArray *pages = VBLPDFPagesAsRGB(pdf, 150.0, &problem);
            if (!pages) note(@"Page images FAILED: %@", problem);
            else {
                NSDictionary *p1 = pages[0];
                VBLPdfDicomInfo info = { .patientName = "TEST^REPORT", .studyInstanceUID = "1.2.3.4", .seriesInstanceUID = "1.2.3.5",
                                         .sopInstanceUID = "1.2.3.6", .seriesNumber = 9900, .seriesDescription = "volBrain report test" };
                char err[200] = "";
                int rc = vbl_write_sc_dicom([[outDir stringByAppendingPathComponent:@"page1_sc.dcm"] fileSystemRepresentation],
                                            [p1[@"rgb"] bytes], [p1[@"width"] intValue], [p1[@"height"] intValue], 1, &info, err, sizeof err);
                note(@"%lu page image(s), page 1 %@×%@; page1_sc.dcm: %s", (unsigned long)pages.count, p1[@"width"], p1[@"height"], rc == 0 ? "ok" : err);
            }
            // The DICOM files the plugin wrote for this job: is the PDF inside the converted one?
            NSString *jobDir = [newest stringByDeletingLastPathComponent];
            for (NSString *f in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:jobDir error:NULL]) {
                if (![f hasSuffix:@".dcm"]) continue;
                NSData *dcm = [NSData dataWithContentsOfFile:[jobDir stringByAppendingPathComponent:f]];
                NSDictionary *a = [[NSFileManager defaultManager] attributesOfItemAtPath:[jobDir stringByAppendingPathComponent:f] error:NULL];
                note(@"%@: %lu bytes, written %@ (original PDF is %lu bytes)", f, (unsigned long)dcm.length, a.fileModificationDate, (unsigned long)pdf.length);
            }
        }
        NSString *log = [@"~/Library/Application Support/VolBrainLink/log.txt" stringByExpandingTildeInPath];
        NSString *logText = [NSString stringWithContentsOfFile:log encoding:NSUTF8StringEncoding error:NULL];
        if (logText) {
            NSArray *lines = [logText componentsSeparatedByString:@"\n"];
            NSUInteger from = lines.count > 60 ? lines.count - 60 : 0;
            note(@"\n--- last lines of log.txt ---\n%@", [[lines subarrayWithRange:NSMakeRange(from, lines.count - from)] componentsJoinedByString:@"\n"]);
        } else note(@"(no log.txt yet)");
        [report writeToFile:[outDir stringByAppendingPathComponent:@"result.txt"] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    }
    return 0;
}
