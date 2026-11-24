import gzip, struct, numpy as np, math, sys
for fn in sys.argv[1:]:
    b=gzip.open(fn).read()
    h=b[:348]
    assert struct.unpack('<i',h[:4])[0]==348 and h[344:348]==b'n+1\x00'
    dim=struct.unpack('<8h',h[40:56]); dt,bp=struct.unpack('<hh',h[70:74]); pix=struct.unpack('<8f',h[76:108])
    vo=struct.unpack('<f',h[108:112])[0]
    q=struct.unpack('<6f',h[256:280]); srow=np.array(struct.unpack('<12f',h[280:328])).reshape(3,4)
    qc,sc=struct.unpack('<hh',h[252:256])
    nx,ny,nz=dim[1:4]
    arr=np.frombuffer(b[int(vo):],dtype='<i2' if dt==4 else '<f4').reshape(nz,ny,nx)
    # expected
    i,j,k=3,4,min(5,nz-1); exp=i+100*j-7*k if nx>8 else arr[k,j,i]
    # qform reconstruct
    bq,cq,dq=q[:3]; a=math.sqrt(max(0,1-bq*bq-cq*cq-dq*dq))
    R=np.array([[a*a+bq*bq-cq*cq-dq*dq,2*(bq*cq-a*dq),2*(bq*dq+a*cq)],[2*(bq*cq+a*dq),a*a+cq*cq-bq*bq-dq*dq,2*(cq*dq-a*bq)],[2*(bq*dq-a*cq),2*(cq*dq+a*bq),a*a+dq*dq-cq*cq-bq*bq]])
    qfac=pix[0]; Q=R@np.diag([pix[1],pix[2],pix[3]*qfac])
    print(fn,'dims',dim[:4],'dt',dt,'pixdim',np.round(pix[:4],3),'codes',qc,sc,'val ok',arr[k,j,i]==exp or abs(arr[k,j,i]-exp)<1e-4)
    print(' max |qform-sform| =',np.abs(Q-srow[:,:3]).max(), 'offset', srow[:,3], q[3:])
