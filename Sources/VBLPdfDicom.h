//
//  VBLPdfDicom.h — wraps a PDF in a DICOM Encapsulated PDF object (SOP class 1.2.840.10008.5.1.4.1.1.104.1)
//  that belongs to an existing study, so the viewer files it next to the images.
//  Plain C, Explicit VR Little Endian, UTF-8 (ISO_IR 192).
//

#ifndef VBL_PDF_DICOM_H
#define VBL_PDF_DICOM_H

#include <stddef.h>

typedef struct {
    // Patient and study: copied from the source study (any may be NULL or "").
    const char *patientName;      // DICOM PN, e.g. "DOE^JOHN"
    const char *patientID;
    const char *patientBirthDate; // YYYYMMDD
    const char *patientSex;       // M, F, O
    const char *studyInstanceUID; // required
    const char *studyDate;        // YYYYMMDD
    const char *studyTime;        // HHMMSS
    const char *studyID;
    const char *accessionNumber;
    const char *referringPhysician;
    // New series and instance.
    const char *seriesInstanceUID; // required
    const char *sopInstanceUID;    // required
    int seriesNumber;
    const char *seriesDescription; // e.g. "volBrain vol2Brain report"
    const char *documentTitle;
    const char *contentDate;       // YYYYMMDD
    const char *contentTime;       // HHMMSS
} VBLPdfDicomInfo;

// Returns 0, or -1 with a message in err.
int vbl_write_pdf_dicom(const char *path, const unsigned char *pdf, size_t pdfLength,
                        const VBLPdfDicomInfo *info, char *err, size_t errlen);

// One page of the report as a DICOM Secondary Capture image (SOP class 1.2.840.10008.5.1.4.1.1.7):
// rgb is width*height*3 bytes, rows top to bottom. Uses the same patient/study/series fields as above;
// instanceNumber numbers the pages. Viewers show these pixels as they are (no PDF rendering).
// Returns 0, or -1 with a message in err.
int vbl_write_sc_dicom(const char *path, const unsigned char *rgb, int width, int height, int instanceNumber,
                       const VBLPdfDicomInfo *info, char *err, size_t errlen);

// A DICOM UID "2.25.<decimal>" from 16 random bytes (a UUID). out needs 64 bytes.
void vbl_uid_from_uuid_bytes(const unsigned char bytes[16], char out[64]);

#endif
