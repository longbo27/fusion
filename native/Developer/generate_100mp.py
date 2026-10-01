"""Developer workload: exactly 100MP/source, bounded rows, real disk TIFFs.
No mapped source stack; scratch/input outputs outside Git.
"""
import argparse,pathlib,numpy as np,tifffile,time,json,sys
sys.path.insert(0,str(pathlib.Path(__file__).resolve().parents[2]))
from focusstack.memory import flush_rows
p=argparse.ArgumentParser();p.add_argument('--artifacts',required=True);p.add_argument('--count',type=int,default=20);p.add_argument('--edge',type=int,default=10000);a=p.parse_args();out=pathlib.Path(a.artifacts).resolve();out.mkdir(parents=True,exist_ok=True)
if out.is_relative_to(pathlib.Path(__file__).resolve().parents[2]):raise ValueError('Artifacts must be outside repository')
w=h=a.edge;x=np.arange(w,dtype=np.float32)[None,:];start=time.time()
for i in range(a.count):
 path=out/f'synthetic-{i:02}.tif'
 if path.exists():raise ValueError(f'Existing input {path}; choose a fresh directory')
 mapped=tifffile.memmap(path,shape=(h,w,3),dtype=np.uint16,photometric='rgb',metadata=None,rowsperstrip=32)
 for y in range(0,h,128):
  yy=np.arange(y,min(y+128,h),dtype=np.float32)[:,None]
  # Global continuous periodic detail, with source-dependent sharpness in two
  # focus planes. Geometry remains identical; all values stay photographic 16-bit.
  gain=np.where(x<w/2,1-i/(a.count+1),.3+i/(a.count+1)).astype(np.float32)
  base=26000+6000*np.sin(x*.007)+5000*np.cos(yy*.013)
  detail=gain*(4000*np.sin(x*.41+yy*.23)+3000*np.cos(x*.71-yy*.13))
  for c in range(3):mapped[y:y+len(yy),:,c]=np.rint(base+detail+c*3000).clip(0,65535).astype(np.uint16)
  # Flush and advise the bounded dirty span. Do not retain a resident full frame.
  flush_rows(mapped,y,min(y+128,h))
 del mapped
 print(json.dumps({'source':i+1,'seconds':time.time()-start,'path':str(path)}),flush=True)
