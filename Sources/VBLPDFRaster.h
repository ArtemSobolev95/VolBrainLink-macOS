//
//  VBLPDFRaster.h — a PDF whose pages are pictures (200 dpi, on white), so a viewer cannot recolour it.
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

// nil on failure, with the reason in *problem.
NSData *VBLPDFAsImages(NSData *pdf, NSString **problem);

// Each page as packed 8-bit RGB pixels on white, rows top to bottom:
// @{ @"rgb": NSData (width*height*3), @"width": NSNumber, @"height": NSNumber }. nil on failure.
NSArray<NSDictionary *> *VBLPDFPagesAsRGB(NSData *pdf, CGFloat dpi, NSString **problem);
