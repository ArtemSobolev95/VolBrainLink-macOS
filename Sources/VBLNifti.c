//
//  VBLNifti.c — see VBLNifti.h.
//

#include "VBLNifti.h"
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <zlib.h>

static void vbl_err(char *err, size_t errlen, const char *msg)
{
    if (err && errlen) { strncpy(err, msg, errlen - 1); err[errlen - 1] = 0; }
}

static double vbl_norm(const double v[3]) { return sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]); }

int vbl_nifti_geometry_from_dicom(VBLNiftiGeometry *g, int nx, int ny, int nz,
                                  const double firstOrigin[3], const double lastOrigin[3],
                                  const double rowDir[3], const double colDir[3],
                                  double colSpacing, double rowSpacing, double singleSliceThickness,
                                  char *err, size_t errlen)
{
    if (nx < 1 || ny < 1 || nz < 1) { vbl_err(err, errlen, "Empty volume."); return -1; }
    if (!(colSpacing > 0) || !(rowSpacing > 0)) { vbl_err(err, errlen, "The series has no pixel spacing."); return -1; }
    double r[3], c[3], s[3];
    double nr = vbl_norm(rowDir), nc = vbl_norm(colDir);
    if (nr < 0.5 || nc < 0.5) { vbl_err(err, errlen, "The series has no image orientation."); return -1; }
    for (int i = 0; i < 3; i++) { r[i] = rowDir[i] / nr; c[i] = colDir[i] / nc; }

    double dz;
    if (nz > 1) {
        for (int i = 0; i < 3; i++) s[i] = (lastOrigin[i] - firstOrigin[i]) / (nz - 1);
        dz = vbl_norm(s);
        if (!(dz > 1e-4)) { vbl_err(err, errlen, "All slices are at the same position."); return -1; }
    } else {
        // normal = r x c
        s[0] = r[1] * c[2] - r[2] * c[1];
        s[1] = r[2] * c[0] - r[0] * c[2];
        s[2] = r[0] * c[1] - r[1] * c[0];
        dz = singleSliceThickness > 0 ? singleSliceThickness : 1.0;
        for (int i = 0; i < 3; i++) s[i] *= dz;
    }

    g->nx = nx; g->ny = ny; g->nz = nz;
    g->dx = colSpacing; g->dy = rowSpacing; g->dz = dz;
    // LPS -> RAS: negate x and y.
    const double flip[3] = { -1.0, -1.0, 1.0 };
    for (int a = 0; a < 3; a++) {
        g->affine[a][0] = flip[a] * r[a] * colSpacing;
        g->affine[a][1] = flip[a] * c[a] * rowSpacing;
        g->affine[a][2] = flip[a] * s[a];
        g->affine[a][3] = flip[a] * firstOrigin[a];
    }
    return 0;
}

// Quaternion of the rotation part (nifti1_io's nifti_mat44_to_quatern, simplified: the columns are
// normalised here and the matrix is assumed close to orthogonal).
static void vbl_quatern(const VBLNiftiGeometry *g, float *qb, float *qc, float *qd, float *qfac)
{
    double R[3][3];
    for (int j = 0; j < 3; j++) {
        double col[3] = { g->affine[0][j], g->affine[1][j], g->affine[2][j] };
        double n = vbl_norm(col);
        if (n <= 0) n = 1;
        for (int i = 0; i < 3; i++) R[i][j] = col[i] / n;
    }
    double det = R[0][0] * (R[1][1] * R[2][2] - R[1][2] * R[2][1])
               - R[0][1] * (R[1][0] * R[2][2] - R[1][2] * R[2][0])
               + R[0][2] * (R[1][0] * R[2][1] - R[1][1] * R[2][0]);
    *qfac = 1.0f;
    if (det < 0) {
        *qfac = -1.0f;
        for (int i = 0; i < 3; i++) R[i][2] = -R[i][2];
    }
    double a = R[0][0] + R[1][1] + R[2][2] + 1.0, b, c, d;
    if (a > 0.5) {
        a = 0.5 * sqrt(a);
        b = 0.25 * (R[2][1] - R[1][2]) / a;
        c = 0.25 * (R[0][2] - R[2][0]) / a;
        d = 0.25 * (R[1][0] - R[0][1]) / a;
    } else {
        double xd = 1.0 + R[0][0] - (R[1][1] + R[2][2]);
        double yd = 1.0 + R[1][1] - (R[0][0] + R[2][2]);
        double zd = 1.0 + R[2][2] - (R[0][0] + R[1][1]);
        if (xd > 1.0) {
            b = 0.5 * sqrt(xd);
            c = 0.25 * (R[0][1] + R[1][0]) / b;
            d = 0.25 * (R[0][2] + R[2][0]) / b;
            a = 0.25 * (R[2][1] - R[1][2]) / b;
        } else if (yd > 1.0) {
            c = 0.5 * sqrt(yd);
            b = 0.25 * (R[0][1] + R[1][0]) / c;
            d = 0.25 * (R[1][2] + R[2][1]) / c;
            a = 0.25 * (R[0][2] - R[2][0]) / c;
        } else {
            d = 0.5 * sqrt(zd);
            b = 0.25 * (R[0][2] + R[2][0]) / d;
            c = 0.25 * (R[1][2] + R[2][1]) / d;
            a = 0.25 * (R[1][0] - R[0][1]) / d;
        }
        if (a < 0.0) { b = -b; c = -c; d = -d; }
    }
    *qb = (float)b; *qc = (float)c; *qd = (float)d;
}

static void put_i16(uint8_t *h, int off, int16_t v) { memcpy(h + off, &v, 2); }
static void put_i32(uint8_t *h, int off, int32_t v) { memcpy(h + off, &v, 4); }
static void put_f32(uint8_t *h, int off, float v)   { memcpy(h + off, &v, 4); }

int vbl_write_nifti_gz(const char *path, const float *data, const VBLNiftiGeometry *g,
                       char *err, size_t errlen)
{
    // The header is written field by field in little-endian order (every Mac is little-endian).
    const uint16_t probe = 1;
    if (*(const uint8_t *)&probe != 1) { vbl_err(err, errlen, "Big-endian machines are not supported."); return -1; }

    size_t n = (size_t)g->nx * g->ny * g->nz;
    int asInt16 = 1;
    float vmin = INFINITY, vmax = -INFINITY;
    for (size_t i = 0; i < n; i++) {
        float v = data[i];
        if (!isfinite(v)) { asInt16 = 0; continue; }
        if (v < vmin) vmin = v;
        if (v > vmax) vmax = v;
        if (asInt16 && (v != floorf(v) || v < -32768.0f || v > 32767.0f)) asInt16 = 0;
    }
    if (!(vmax >= vmin)) { vbl_err(err, errlen, "The series has no pixel values."); return -1; }

    uint8_t h[352];
    memset(h, 0, sizeof h);
    put_i32(h, 0, 348);                      // sizeof_hdr
    h[38] = 'r';                             // regular
    put_i16(h, 40, 3);                       // dim[0]
    put_i16(h, 42, (int16_t)g->nx);
    put_i16(h, 44, (int16_t)g->ny);
    put_i16(h, 46, (int16_t)g->nz);
    put_i16(h, 48, 1); put_i16(h, 50, 1); put_i16(h, 52, 1); put_i16(h, 54, 1);
    put_i16(h, 70, asInt16 ? 4 : 16);        // datatype: DT_INT16 / DT_FLOAT32
    put_i16(h, 72, asInt16 ? 16 : 32);       // bitpix

    float qb, qc, qd, qfac;
    vbl_quatern(g, &qb, &qc, &qd, &qfac);
    put_f32(h, 76, qfac);                    // pixdim[0]
    put_f32(h, 80, (float)g->dx);
    put_f32(h, 84, (float)g->dy);
    put_f32(h, 88, (float)g->dz);
    put_f32(h, 92, 1.0f); put_f32(h, 96, 1.0f); put_f32(h, 100, 1.0f); put_f32(h, 104, 1.0f);
    put_f32(h, 108, 352.0f);                 // vox_offset
    put_f32(h, 112, 1.0f);                   // scl_slope
    put_f32(h, 116, 0.0f);                   // scl_inter
    h[123] = 2 | 8;                          // xyzt_units: mm, s
    put_f32(h, 124, vmax);                   // cal_max
    put_f32(h, 128, vmin);                   // cal_min
    put_i16(h, 252, 1);                      // qform_code: scanner
    put_i16(h, 254, 1);                      // sform_code: scanner
    put_f32(h, 256, qb); put_f32(h, 260, qc); put_f32(h, 264, qd);
    put_f32(h, 268, (float)g->affine[0][3]);
    put_f32(h, 272, (float)g->affine[1][3]);
    put_f32(h, 276, (float)g->affine[2][3]);
    for (int row = 0; row < 3; row++)
        for (int col = 0; col < 4; col++)
            put_f32(h, 280 + row * 16 + col * 4, (float)g->affine[row][col]);
    memcpy(h + 344, "n+1\0", 4);             // magic; bytes 348-351: no extension

    gzFile f = gzopen(path, "wb6");
    if (!f) { vbl_err(err, errlen, "Cannot create the NIfTI file."); return -1; }
    int ok = gzwrite(f, h, sizeof h) == (int)sizeof h;

    const size_t chunk = 1 << 20;
    if (asInt16) {
        int16_t *buf = (int16_t *)malloc(chunk * sizeof(int16_t));
        for (size_t i = 0; ok && buf && i < n; i += chunk) {
            size_t m = (n - i < chunk) ? n - i : chunk;
            for (size_t k = 0; k < m; k++) buf[k] = (int16_t)data[i + k];
            ok = gzwrite(f, buf, (unsigned)(m * sizeof(int16_t))) == (int)(m * sizeof(int16_t));
        }
        if (!buf) ok = 0;
        free(buf);
    } else {
        for (size_t i = 0; ok && i < n; i += chunk) {
            size_t m = (n - i < chunk) ? n - i : chunk;
            ok = gzwrite(f, data + i, (unsigned)(m * sizeof(float))) == (int)(m * sizeof(float));
        }
    }
    if (gzclose(f) != Z_OK) ok = 0;
    if (!ok) { remove(path); vbl_err(err, errlen, "Writing the NIfTI file failed (disk full?)."); return -1; }
    return 0;
}
