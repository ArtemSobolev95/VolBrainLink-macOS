//
//  VBLPDFRaster.m
//

#import "VBLPDFRaster.h"
#import <ImageIO/ImageIO.h>
#include <math.h>

// In Dark Mode the viewer recolours the vector content of a PDF (text and backgrounds turn light on
// dark) but leaves pictures alone. Each page is therefore stored as a picture: rendered at 200 dpi on
// white and embedded as JPEG, so the report looks the same in Light and Dark Mode.
NSData *VBLPDFAsImages(NSData *pdf, NSString **problem)
{
#define VBL_FAIL(msg) do { if (problem) *problem = (msg); } while (0)
    CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)pdf);
    CGPDFDocumentRef document = provider ? CGPDFDocumentCreateWithProvider(provider) : NULL;
    CGDataProviderRelease(provider);
    if (!document) { VBL_FAIL(@"not a readable PDF"); return nil; }
    size_t pages = CGPDFDocumentGetNumberOfPages(document);
    NSMutableData *output = [NSMutableData data];
    CGDataConsumerRef consumer = CGDataConsumerCreateWithCFData((__bridge CFMutableDataRef)output);
    CGContextRef pdfContext = consumer ? CGPDFContextCreate(consumer, NULL, NULL) : NULL;
    CGDataConsumerRelease(consumer);
    CGColorSpaceRef rgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    BOOL ok = pdfContext && rgb && pages > 0;
    if (!ok) VBL_FAIL(pages == 0 ? @"the PDF has no pages" : @"could not create the output PDF");
    const CGFloat scale = 200.0 / 72.0;
    for (size_t i = 1; ok && i <= pages; i++) {
        CGPDFPageRef page = CGPDFDocumentGetPage(document, i);
        if (!page) continue;
        CGRect box = CGPDFPageGetBoxRect(page, kCGPDFCropBox);
        int rotation = CGPDFPageGetRotationAngle(page);
        CGRect media = (rotation % 180) ? CGRectMake(0, 0, box.size.height, box.size.width) : CGRectMake(0, 0, box.size.width, box.size.height);
        size_t width = (size_t)ceil(media.size.width * scale), height = (size_t)ceil(media.size.height * scale);
        CGContextRef bitmap = CGBitmapContextCreate(NULL, width, height, 8, 0, rgb, (CGBitmapInfo)kCGImageAlphaNoneSkipLast);
        if (!bitmap) { VBL_FAIL(@"could not create the page bitmap"); ok = NO; break; }
        CGContextSetRGBFillColor(bitmap, 1, 1, 1, 1);
        CGContextFillRect(bitmap, CGRectMake(0, 0, width, height));
        CGContextSetInterpolationQuality(bitmap, kCGInterpolationHigh);
        CGContextScaleCTM(bitmap, scale, scale);
        CGContextConcatCTM(bitmap, CGPDFPageGetDrawingTransform(page, kCGPDFCropBox, media, 0, true));
        CGContextDrawPDFPage(bitmap, page);
        CGImageRef rendered = CGBitmapContextCreateImage(bitmap);
        CGContextRelease(bitmap);
        if (!rendered) { VBL_FAIL(@"could not render a page"); ok = NO; break; }

        // JPEG keeps the file small; the PDF context embeds the JPEG data as it is.
        NSMutableData *jpeg = [NSMutableData data];
        CGImageDestinationRef destination = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)jpeg, CFSTR("public.jpeg"), 1, NULL);
        NSDictionary *options = @{ (__bridge NSString *)kCGImageDestinationLossyCompressionQuality: @0.9 };
        if (destination) {
            CGImageDestinationAddImage(destination, rendered, (__bridge CFDictionaryRef)options);
            if (!CGImageDestinationFinalize(destination)) [jpeg setLength:0];
            CFRelease(destination);
        }
        CGImageRef pageImage = NULL;
        if ([jpeg length]) {
            CGDataProviderRef jpegProvider = CGDataProviderCreateWithCFData((__bridge CFDataRef)jpeg);
            pageImage = CGImageCreateWithJPEGDataProvider(jpegProvider, NULL, true, kCGRenderingIntentDefault);
            CGDataProviderRelease(jpegProvider);
        }
        if (!pageImage) pageImage = CGImageRetain(rendered);
        CGImageRelease(rendered);

        NSDictionary *pageInfo = @{ (__bridge NSString *)kCGPDFContextMediaBox: [NSData dataWithBytes:&media length:sizeof media] };
        CGPDFContextBeginPage(pdfContext, (__bridge CFDictionaryRef)pageInfo);
        CGContextDrawImage(pdfContext, media, pageImage);
        CGPDFContextEndPage(pdfContext);
        CGImageRelease(pageImage);
    }
    if (pdfContext) { CGPDFContextClose(pdfContext); CGContextRelease(pdfContext); }
    CGColorSpaceRelease(rgb);
    CGPDFDocumentRelease(document);
    if (ok && [output length] <= 4) { VBL_FAIL(@"the output PDF is empty"); ok = NO; }
    return ok ? output : nil;
#undef VBL_FAIL
}


NSArray<NSDictionary *> *VBLPDFPagesAsRGB(NSData *pdf, CGFloat dpi, NSString **problem)
{
    CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)pdf);
    CGPDFDocumentRef document = provider ? CGPDFDocumentCreateWithProvider(provider) : NULL;
    CGDataProviderRelease(provider);
    if (!document) { if (problem) *problem = @"not a readable PDF"; return nil; }
    size_t pages = CGPDFDocumentGetNumberOfPages(document);
    CGColorSpaceRef rgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    NSMutableArray *result = [NSMutableArray array];
    const CGFloat scale = dpi / 72.0;
    for (size_t i = 1; i <= pages; i++) {
        CGPDFPageRef page = CGPDFDocumentGetPage(document, i);
        if (!page) continue;
        CGRect box = CGPDFPageGetBoxRect(page, kCGPDFCropBox);
        int rotation = CGPDFPageGetRotationAngle(page);
        CGRect media = (rotation % 180) ? CGRectMake(0, 0, box.size.height, box.size.width) : CGRectMake(0, 0, box.size.width, box.size.height);
        size_t width = (size_t)ceil(media.size.width * scale), height = (size_t)ceil(media.size.height * scale);
        size_t rowBytes = width * 4;
        NSMutableData *rgbx = [NSMutableData dataWithLength:rowBytes * height];
        CGContextRef bitmap = CGBitmapContextCreate([rgbx mutableBytes], width, height, 8, rowBytes, rgb, (CGBitmapInfo)kCGImageAlphaNoneSkipLast);
        if (!bitmap) { if (problem) *problem = @"could not create the page bitmap"; result = nil; break; }
        CGContextSetRGBFillColor(bitmap, 1, 1, 1, 1);
        CGContextFillRect(bitmap, CGRectMake(0, 0, width, height));
        CGContextSetInterpolationQuality(bitmap, kCGInterpolationHigh);
        CGContextScaleCTM(bitmap, scale, scale);
        CGContextConcatCTM(bitmap, CGPDFPageGetDrawingTransform(page, kCGPDFCropBox, media, 0, true));
        CGContextDrawPDFPage(bitmap, page);
        CGContextRelease(bitmap);
        // The bitmap's first row in memory is the top of the page; drop the unused fourth byte.
        NSMutableData *packed = [NSMutableData dataWithLength:width * height * 3];
        const uint8_t *src = [rgbx bytes];
        uint8_t *dst = [packed mutableBytes];
        for (size_t p = 0, n = width * height; p < n; p++) {
            dst[3 * p] = src[4 * p]; dst[3 * p + 1] = src[4 * p + 1]; dst[3 * p + 2] = src[4 * p + 2];
        }
        [result addObject:@{ @"rgb": packed, @"width": @(width), @"height": @(height) }];
    }
    CGColorSpaceRelease(rgb);
    CGPDFDocumentRelease(document);
    if (result && [result count] == 0) { if (problem) *problem = @"the PDF has no pages"; return nil; }
    return result;
}
