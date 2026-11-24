#!/bin/bash
# Test of the Dark Mode fix: converts the newest downloaded volBrain report and saves the result in tests/out.
cd "$(dirname "$0")"
mkdir -p tests/out
xcrun clang -fobjc-arc -I Sources tests/pdf_check.m Sources/VBLPDFRaster.m Sources/VBLPdfDicom.c \
  -framework Foundation -framework CoreGraphics -framework ImageIO -o tests/out/pdf_check && tests/out/pdf_check "$(pwd)/tests/out"
echo
echo "Done. Results are in tests/out."
read -n 1 -s -r -p "Press any key to close."
