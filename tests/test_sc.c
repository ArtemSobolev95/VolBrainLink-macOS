#include "../Sources/VBLPdfDicom.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
int main(){ int w=101,h=57; unsigned char *p=malloc(w*h*3); for(int i=0;i<w*h*3;i++) p[i]=(unsigned char)(i*7);
 VBLPdfDicomInfo in={ "Соболев^Артём","ID1","19700101","M","1.2.3.4","20261120","101010","S1","ACC","", "1.2.3.5","1.2.3.6",9900,"volBrain report","volBrain report","20261125","000600"};
 char e[100]; if(vbl_write_sc_dicom("sc.dcm",p,w,h,2,&in,e,100)){puts(e);return 1;}
 const char *pdf="%PDF-1.4 x"; if(vbl_write_pdf_dicom("r.dcm",(const unsigned char*)pdf,strlen(pdf),&in,e,100)){puts(e);return 1;} return 0;}
