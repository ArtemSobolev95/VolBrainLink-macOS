#include "../Sources/VBLNifti.h"
#include <stdio.h>
#include <stdlib.h>
#include <math.h>
int main(int argc,char**argv){
  int nx=40,ny=30,nz=20; float *d=malloc(sizeof(float)*nx*ny*nz);
  for(int k=0;k<nz;k++)for(int j=0;j<ny;j++)for(int i=0;i<nx;i++) d[(k*ny+j)*nx+i]=i+100*j-7*k;
  double th=0.3; double r[3]={cos(th),sin(th),0}, c[3]={-sin(th)*cos(0.2),cos(th)*cos(0.2),-sin(0.2)};
  // normal
  double s[3]={r[1]*c[2]-r[2]*c[1], r[2]*c[0]-r[0]*c[2], r[0]*c[1]-r[1]*c[0]};
  double o0[3]={-100,-120,30}, o1[3]; for(int a=0;a<3;a++) o1[a]=o0[a]+ (nz-1)*1.5*s[a];
  VBLNiftiGeometry g; char err[200];
  if(vbl_nifti_geometry_from_dicom(&g,nx,ny,nz,o0,o1,r,c,0.9,1.1,0,err,200)){puts(err);return 1;}
  if(vbl_write_nifti_gz(argv[1],d,&g,err,200)){puts(err);return 1;}
  d[5]=0.5f; if(vbl_write_nifti_gz(argv[2],d,&g,err,200)){puts(err);return 1;}
  return 0;}
