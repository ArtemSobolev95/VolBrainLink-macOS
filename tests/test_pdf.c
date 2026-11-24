#include "../Sources/VBLPdfDicom.h"
#include <stdio.h>
#include <string.h>
int main(){
  unsigned char u[16]; for(int i=0;i<16;i++) u[i]=(unsigned char)(0xF0+i*7); char uid[64]; vbl_uid_from_uuid_bytes(u,uid); printf("%s\n",uid);
  unsigned char z[16]={0}; char u0[64]; vbl_uid_from_uuid_bytes(z,u0); printf("%s\n",u0);
  const char *pdf="%PDF-1.4\n% test\n%%EOF"; // odd length?
  VBLPdfDicomInfo in={ "Соболев^Артём","ID\\1","19700101","M","1.2.3.4","20261120","101010","S1","ACC","", "1.2.3.5","1.2.3.6",9001,"volBrain vol2Brain report","volBrain vol2Brain report","20261125","000600"};
  char e[100]; if(vbl_write_pdf_dicom("r.dcm",(const unsigned char*)pdf,strlen(pdf),&in,e,100)){puts(e);return 1;}
  printf("pdflen %zu\n",strlen(pdf)); return 0;}
