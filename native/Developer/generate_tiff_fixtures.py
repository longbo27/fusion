"""384 small independent TIFF layouts; files/expected pixels stay outside Git."""
import argparse,pathlib,json,numpy as np,tifffile
p=argparse.ArgumentParser();p.add_argument('--artifacts',required=True);a=p.parse_args();out=pathlib.Path(a.artifacts).resolve();out.mkdir(parents=True,exist_ok=True)
if out.is_relative_to(pathlib.Path(__file__).resolve().parents[2]):raise ValueError('Fixtures must remain outside repository')
y,x,c=np.mgrid[:51,:67,:3];rgb=((x*7919+y*1049+c*1363+1)%65536).astype(np.uint16);manifest=[]
for bits in [8,16]:
 for endian in ['<','>']:
  for big in [False,True]:
   for codec in [None,'deflate','lzw']:
    for tiled in [False,True]:
     for ori in range(1,9):
      name=f'{bits}-{endian==">"}-{big}-{codec}-{tiled}-{ori}.tif';a=rgb if bits==16 else (rgb>>8).astype(np.uint8)
      tifffile.imwrite(out/name,a,photometric='rgb',byteorder=endian,bigtiff=big,compression=codec,metadata=None,rowsperstrip=None if tiled else 7,tile=(16,16) if tiled else None,extratags=[(274,'H',1,ori,False)],iccprofile=b'exact-test-icc')
      v=a.astype(np.uint16)*(257 if bits==8 else 1)
      v={1:lambda a:a,2:lambda a:a[:,::-1],3:lambda a:a[::-1,::-1],4:lambda a:a[::-1],5:lambda a:a.transpose(1,0,2),6:lambda a:np.rot90(a,3),7:lambda a:a.transpose(1,0,2)[::-1,::-1],8:lambda a:np.rot90(a,1)}[ori](v)
      b=np.full((19,17,4),65535,np.uint16);b[...,:3]=v[5:24,3:20];b.tofile(out/(name+'.rgba'));manifest.append({'name':name})
(out/'manifest.json').write_text(json.dumps(manifest));print(len(manifest))
