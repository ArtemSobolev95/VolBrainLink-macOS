//
//  VBLNifti.h — writes a 3D volume as a compressed NIfTI-1 file (.nii.gz).
//  Plain C (zlib only), so it can be tested without the viewer.
//

#ifndef VBL_NIFTI_H
#define VBL_NIFTI_H

#include <stddef.h>

typedef struct {
    int nx, ny, nz;          // voxels; data is x fastest, then y, then z
    double dx, dy, dz;       // voxel size, mm
    double affine[3][4];     // voxel (i, j, k) -> RAS+ position in mm (NIfTI convention)
} VBLNiftiGeometry;

// Builds the geometry from DICOM values (LPS patient coordinates, as in the DICOM tags).
//   firstOrigin: Image Position (Patient) of the first slice
//   lastOrigin:  Image Position (Patient) of the last slice (ignored when nz == 1)
//   rowDir:      first three values of Image Orientation (Patient): direction of increasing column index
//   colDir:      last three values: direction of increasing row index
//   colSpacing:  distance between columns (Pixel Spacing, 2nd value), rowSpacing: between rows (1st value)
//   singleSliceThickness: used for dz when nz == 1
// Returns 0, or -1 with a message in err.
int vbl_nifti_geometry_from_dicom(VBLNiftiGeometry *g, int nx, int ny, int nz,
                                  const double firstOrigin[3], const double lastOrigin[3],
                                  const double rowDir[3], const double colDir[3],
                                  double colSpacing, double rowSpacing, double singleSliceThickness,
                                  char *err, size_t errlen);

// Writes data (nx*ny*nz floats) to path. Stored as int16 when every value is a whole number that
// fits, otherwise as float32. The header carries no text (descrip, aux_file, intent_name are empty).
// Returns 0, or -1 with a message in err.
int vbl_write_nifti_gz(const char *path, const float *data, const VBLNiftiGeometry *g,
                       char *err, size_t errlen);

#endif
