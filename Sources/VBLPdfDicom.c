//
//  VBLPdfDicom.c — see VBLPdfDicom.h.
//

#include "VBLPdfDicom.h"
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define VBL_PDF_SOP_CLASS "1.2.840.10008.5.1.4.1.1.104.1"
#define VBL_SC_SOP_CLASS  "1.2.840.10008.5.1.4.1.1.7"
#define VBL_EXPLICIT_LE   "1.2.840.10008.1.2.1"
// Implementation Class UID under the 2.25 (UUID) root, fixed for this plugin.
#define VBL_IMPL_UID      "2.25.233019846307742212315620370372404431431"
#define VBL_IMPL_VERSION  "VOLBRAINLINK_1"

typedef struct { uint8_t *p; size_t len, cap; int failed; } VBLBuf;

static void buf_add(VBLBuf *b, const void *data, size_t n)
{
    if (b->failed) return;
    if (b->len + n > b->cap) {
        size_t cap = b->cap ? b->cap : 4096;
        while (cap < b->len + n) cap *= 2;
        uint8_t *q = (uint8_t *)realloc(b->p, cap);
        if (!q) { b->failed = 1; return; }
        b->p = q; b->cap = cap;
    }
    memcpy(b->p + b->len, data, n);
    b->len += n;
}

static void buf_u16(VBLBuf *b, uint16_t v) { uint8_t x[2] = { (uint8_t)v, (uint8_t)(v >> 8) }; buf_add(b, x, 2); }
static void buf_u32(VBLBuf *b, uint32_t v)
{
    uint8_t x[4] = { (uint8_t)v, (uint8_t)(v >> 8), (uint8_t)(v >> 16), (uint8_t)(v >> 24) };
    buf_add(b, x, 4);
}

static int vr_has_long_length(const char *vr)
{
    return !strcmp(vr, "OB") || !strcmp(vr, "OW") || !strcmp(vr, "SQ") || !strcmp(vr, "UN")
        || !strcmp(vr, "UT") || !strcmp(vr, "UC") || !strcmp(vr, "UR");
}

static void put_element(VBLBuf *b, uint16_t group, uint16_t elem, const char *vr, const void *value, size_t n)
{
    int pad = (n & 1) != 0;
    buf_u16(b, group);
    buf_u16(b, elem);
    buf_add(b, vr, 2);
    if (vr_has_long_length(vr)) { buf_u16(b, 0); buf_u32(b, (uint32_t)(n + pad)); }
    else buf_u16(b, (uint16_t)(n + pad));
    if (n) buf_add(b, value, n);
    if (pad) {
        // UI and binary values are padded with NUL, text with a space.
        uint8_t c = (!strcmp(vr, "UI") || !strcmp(vr, "OB")) ? 0 : ' ';
        buf_add(b, &c, 1);
    }
}

// Length of s cut to at most max bytes without splitting a UTF-8 character.
static size_t utf8_cut(const char *s, size_t max)
{
    size_t n = strlen(s);
    if (n <= max) return n;
    n = max;
    while (n > 0 && ((unsigned char)s[n] & 0xC0) == 0x80) n--;
    return n;
}

static void put_text(VBLBuf *b, uint16_t group, uint16_t elem, const char *vr, const char *s, size_t max)
{
    if (!s) s = "";
    // Backslash separates values in DICOM; not wanted inside these single values.
    size_t n = utf8_cut(s, max);
    char *copy = (char *)malloc(n + 1);
    if (!copy) { b->failed = 1; return; }
    for (size_t i = 0; i < n; i++) copy[i] = (s[i] == '\\') ? '/' : s[i];
    copy[n] = 0;
    put_element(b, group, elem, vr, copy, n);
    free(copy);
}

static void put_uid(VBLBuf *b, uint16_t group, uint16_t elem, const char *uid)
{
    put_element(b, group, elem, "UI", uid, strlen(uid));
}

static int valid_uid(const char *uid)
{
    if (!uid || !*uid || strlen(uid) > 64) return 0;
    for (const char *p = uid; *p; p++) if (!((*p >= '0' && *p <= '9') || *p == '.')) return 0;
    return 1;
}

static void vbl_err(char *err, size_t errlen, const char *msg)
{
    if (err && errlen) { strncpy(err, msg, errlen - 1); err[errlen - 1] = 0; }
}

static int vbl_write_file(const char *path, VBLBuf *meta, VBLBuf *ds, char *err, size_t errlen);

int vbl_write_pdf_dicom(const char *path, const unsigned char *pdf, size_t pdfLength,
                        const VBLPdfDicomInfo *info, char *err, size_t errlen)
{
    if (!pdf || pdfLength < 5 || memcmp(pdf, "%PDF", 4) != 0) { vbl_err(err, errlen, "The file is not a PDF."); return -1; }
    if (pdfLength > 0xFFFFFFF0u) { vbl_err(err, errlen, "The PDF is too large."); return -1; }
    if (!valid_uid(info->studyInstanceUID) || !valid_uid(info->seriesInstanceUID) || !valid_uid(info->sopInstanceUID)) {
        vbl_err(err, errlen, "Missing or invalid study, series or instance UID.");
        return -1;
    }

    // File meta information (group 0002), preceded by its group length.
    VBLBuf meta = { 0 };
    const uint8_t version[2] = { 0, 1 };
    put_element(&meta, 0x0002, 0x0001, "OB", version, 2);
    put_uid(&meta, 0x0002, 0x0002, VBL_PDF_SOP_CLASS);
    put_uid(&meta, 0x0002, 0x0003, info->sopInstanceUID);
    put_uid(&meta, 0x0002, 0x0010, VBL_EXPLICIT_LE);
    put_uid(&meta, 0x0002, 0x0012, VBL_IMPL_UID);
    put_text(&meta, 0x0002, 0x0013, "SH", VBL_IMPL_VERSION, 16);

    // Data set, tags in ascending order.
    VBLBuf ds = { 0 };
    char number[16];
    put_text(&ds, 0x0008, 0x0005, "CS", "ISO_IR 192", 16);
    put_uid(&ds, 0x0008, 0x0016, VBL_PDF_SOP_CLASS);
    put_uid(&ds, 0x0008, 0x0018, info->sopInstanceUID);
    put_text(&ds, 0x0008, 0x0020, "DA", info->studyDate, 8);
    put_text(&ds, 0x0008, 0x0023, "DA", info->contentDate, 8);
    put_text(&ds, 0x0008, 0x002A, "DT", "", 26);                      // Acquisition DateTime (type 2)
    put_text(&ds, 0x0008, 0x0030, "TM", info->studyTime, 16);
    put_text(&ds, 0x0008, 0x0033, "TM", info->contentTime, 16);
    put_text(&ds, 0x0008, 0x0050, "SH", info->accessionNumber, 16);
    put_text(&ds, 0x0008, 0x0060, "CS", "DOC", 16);
    put_text(&ds, 0x0008, 0x0064, "CS", "WSD", 16);                   // Conversion Type: workstation
    put_text(&ds, 0x0008, 0x0070, "LO", "volBrain (via VolBrainLink plugin)", 64);
    put_text(&ds, 0x0008, 0x0090, "PN", info->referringPhysician, 64);
    put_text(&ds, 0x0008, 0x103E, "LO", info->seriesDescription, 64);
    put_text(&ds, 0x0010, 0x0010, "PN", info->patientName, 64);
    put_text(&ds, 0x0010, 0x0020, "LO", info->patientID, 64);
    put_text(&ds, 0x0010, 0x0030, "DA", info->patientBirthDate, 8);
    put_text(&ds, 0x0010, 0x0040, "CS", info->patientSex, 16);
    put_uid(&ds, 0x0020, 0x000D, info->studyInstanceUID);
    put_uid(&ds, 0x0020, 0x000E, info->seriesInstanceUID);
    put_text(&ds, 0x0020, 0x0010, "SH", info->studyID, 16);
    snprintf(number, sizeof number, "%d", info->seriesNumber);
    put_text(&ds, 0x0020, 0x0011, "IS", number, 12);
    put_text(&ds, 0x0020, 0x0013, "IS", "1", 12);
    put_text(&ds, 0x0028, 0x0301, "CS", "NO", 16);                    // Burned In Annotation
    put_element(&ds, 0x0040, 0xA043, "SQ", NULL, 0);                  // Concept Name Code Sequence (type 2, empty)
    put_text(&ds, 0x0042, 0x0010, "ST", info->documentTitle, 1024);
    put_element(&ds, 0x0042, 0x0011, "OB", pdf, pdfLength);           // Encapsulated Document
    put_text(&ds, 0x0042, 0x0012, "LO", "application/pdf", 64);

    int rc = -1;
    if (meta.failed || ds.failed) { vbl_err(err, errlen, "Out of memory."); goto done; }
    rc = vbl_write_file(path, &meta, &ds, err, errlen);
done:
    free(meta.p);
    free(ds.p);
    return rc;
}

static int vbl_write_file(const char *path, VBLBuf *metaBuf, VBLBuf *dsBuf, char *err, size_t errlen)
{
    VBLBuf meta = *metaBuf, ds = *dsBuf;
    int rc = -1;

    FILE *f = fopen(path, "wb");
    if (!f) { vbl_err(err, errlen, "Cannot create the DICOM file."); goto done; }
    uint8_t preamble[128] = { 0 };
    VBLBuf head = { 0 };
    buf_add(&head, preamble, sizeof preamble);
    buf_add(&head, "DICM", 4);
    put_element(&head, 0x0002, 0x0000, "UL", NULL, 0);   // placeholder, value patched below
    head.len -= 2;                                       // UL: 2-byte length field holds 4, then the value
    buf_u16(&head, 4);
    buf_u32(&head, (uint32_t)meta.len);
    int ok = !head.failed
          && fwrite(head.p, 1, head.len, f) == head.len
          && fwrite(meta.p, 1, meta.len, f) == meta.len
          && fwrite(ds.p, 1, ds.len, f) == ds.len;
    free(head.p);
    if (fclose(f) != 0) ok = 0;
    if (!ok) { remove(path); vbl_err(err, errlen, "Writing the DICOM file failed (disk full?)."); goto done; }
    rc = 0;
done:
    return rc;
}

static void put_u16_element(VBLBuf *b, uint16_t group, uint16_t elem, uint16_t value)
{
    uint8_t v[2] = { (uint8_t)value, (uint8_t)(value >> 8) };
    put_element(b, group, elem, "US", v, 2);
}

int vbl_write_sc_dicom(const char *path, const unsigned char *rgb, int width, int height, int instanceNumber,
                       const VBLPdfDicomInfo *info, char *err, size_t errlen)
{
    if (!rgb || width < 1 || height < 1 || width > 65535 || height > 65535) { vbl_err(err, errlen, "Invalid page image."); return -1; }
    if (!valid_uid(info->studyInstanceUID) || !valid_uid(info->seriesInstanceUID) || !valid_uid(info->sopInstanceUID)) {
        vbl_err(err, errlen, "Missing or invalid study, series or instance UID.");
        return -1;
    }
    VBLBuf meta = { 0 };
    const uint8_t version[2] = { 0, 1 };
    put_element(&meta, 0x0002, 0x0001, "OB", version, 2);
    put_uid(&meta, 0x0002, 0x0002, VBL_SC_SOP_CLASS);
    put_uid(&meta, 0x0002, 0x0003, info->sopInstanceUID);
    put_uid(&meta, 0x0002, 0x0010, VBL_EXPLICIT_LE);
    put_uid(&meta, 0x0002, 0x0012, VBL_IMPL_UID);
    put_text(&meta, 0x0002, 0x0013, "SH", VBL_IMPL_VERSION, 16);

    VBLBuf ds = { 0 };
    char number[16];
    put_text(&ds, 0x0008, 0x0005, "CS", "ISO_IR 192", 16);
    put_element(&ds, 0x0008, 0x0008, "CS", "DERIVED\\SECONDARY", 17);   // Image Type (backslash = value separator)
    put_uid(&ds, 0x0008, 0x0016, VBL_SC_SOP_CLASS);
    put_uid(&ds, 0x0008, 0x0018, info->sopInstanceUID);
    put_text(&ds, 0x0008, 0x0020, "DA", info->studyDate, 8);
    put_text(&ds, 0x0008, 0x0023, "DA", info->contentDate, 8);
    put_text(&ds, 0x0008, 0x0030, "TM", info->studyTime, 16);
    put_text(&ds, 0x0008, 0x0033, "TM", info->contentTime, 16);
    put_text(&ds, 0x0008, 0x0050, "SH", info->accessionNumber, 16);
    put_text(&ds, 0x0008, 0x0060, "CS", "OT", 16);
    put_text(&ds, 0x0008, 0x0064, "CS", "WSD", 16);
    put_text(&ds, 0x0008, 0x0070, "LO", "volBrain (via VolBrainLink plugin)", 64);
    put_text(&ds, 0x0008, 0x0090, "PN", info->referringPhysician, 64);
    put_text(&ds, 0x0008, 0x103E, "LO", info->seriesDescription, 64);
    put_text(&ds, 0x0010, 0x0010, "PN", info->patientName, 64);
    put_text(&ds, 0x0010, 0x0020, "LO", info->patientID, 64);
    put_text(&ds, 0x0010, 0x0030, "DA", info->patientBirthDate, 8);
    put_text(&ds, 0x0010, 0x0040, "CS", info->patientSex, 16);
    put_uid(&ds, 0x0020, 0x000D, info->studyInstanceUID);
    put_uid(&ds, 0x0020, 0x000E, info->seriesInstanceUID);
    put_text(&ds, 0x0020, 0x0010, "SH", info->studyID, 16);
    snprintf(number, sizeof number, "%d", info->seriesNumber);
    put_text(&ds, 0x0020, 0x0011, "IS", number, 12);
    snprintf(number, sizeof number, "%d", instanceNumber);
    put_text(&ds, 0x0020, 0x0013, "IS", number, 12);
    put_text(&ds, 0x0020, 0x0020, "CS", "", 16);                      // Patient Orientation (type 2)
    put_u16_element(&ds, 0x0028, 0x0002, 3);                         // Samples per Pixel
    put_text(&ds, 0x0028, 0x0004, "CS", "RGB", 16);
    put_u16_element(&ds, 0x0028, 0x0006, 0);                         // Planar Configuration: RGBRGB...
    put_u16_element(&ds, 0x0028, 0x0010, (uint16_t)height);          // Rows
    put_u16_element(&ds, 0x0028, 0x0011, (uint16_t)width);           // Columns
    put_u16_element(&ds, 0x0028, 0x0100, 8);
    put_u16_element(&ds, 0x0028, 0x0101, 8);
    put_u16_element(&ds, 0x0028, 0x0102, 7);
    put_u16_element(&ds, 0x0028, 0x0103, 0);
    put_text(&ds, 0x0028, 0x0301, "CS", "NO", 16);
    put_element(&ds, 0x7FE0, 0x0010, "OB", rgb, (size_t)width * (size_t)height * 3);

    int rc = -1;
    if (meta.failed || ds.failed) vbl_err(err, errlen, "Out of memory.");
    else rc = vbl_write_file(path, &meta, &ds, err, errlen);
    free(meta.p);
    free(ds.p);
    return rc;
}

void vbl_uid_from_uuid_bytes(const unsigned char bytes[16], char out[64])
{
    // 128-bit big-endian integer -> decimal by repeated division by 10.
    unsigned char n[16];
    memcpy(n, bytes, 16);
    char digits[48];
    int nd = 0;
    for (;;) {
        int zero = 1;
        unsigned rem = 0;
        for (int i = 0; i < 16; i++) {
            unsigned cur = (rem << 8) | n[i];
            n[i] = (unsigned char)(cur / 10);
            rem = cur % 10;
            if (n[i]) zero = 0;
        }
        digits[nd++] = (char)('0' + rem);
        if (zero) break;
    }
    int o = snprintf(out, 64, "2.25.");
    while (nd > 0 && o < 63) out[o++] = digits[--nd];
    out[o] = 0;
}
