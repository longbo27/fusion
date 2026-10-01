"""Sample a native stack against unchanged V1.1 using the same native transforms.

Output TIFF decoding reads only intersecting strips/tiles. Private source names,
images, native reports and comparison output remain outside the repository.
"""
import argparse,json,pathlib,sys,tempfile,time
import numpy as np
import tifffile
sys.path.insert(0,str(pathlib.Path(__file__).resolve().parents[2]))
from focusstack.io import Source,inspect_image
from focusstack.fusion import fuse_tile,tile_bounds
from focusstack.config import Config

def read_region(path,core):
    y0,y1,x0,x1=core
    result=np.empty((y1-y0,x1-x0,3),np.uint16)
    with tifffile.TiffFile(path) as tif:
        page=tif.pages[0]
        assert page.dtype==np.uint16 and page.samplesperpixel==3
        if page.is_tiled:
            cols=(page.imagewidth+page.tilewidth-1)//page.tilewidth
            segments=[row*cols+col for row in range(y0//page.tilelength,(y1-1)//page.tilelength+1) for col in range(x0//page.tilewidth,(x1-1)//page.tilewidth+1)]
        else:
            segments=range(y0//page.rowsperstrip,(y1-1)//page.rowsperstrip+1)
        for index in segments:
            tif.filehandle.seek(page.dataoffsets[index])
            data,position,_=page.decode(tif.filehandle.read(page.databytecounts[index]),index)
            sy,sx=position[2:4];ey=min(y1,sy+data.shape[1]);ex=min(x1,sx+data.shape[2]);by=max(y0,sy);bx=max(x0,sx)
            result[by-y0:ey-y0,bx-x0:ex-x0]=data[0,by-sy:ey-sy,bx-sx:ex-sx]
    return result

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--report',required=True);parser.add_argument('--output',required=True);parser.add_argument('--stride',type=int,default=17);parser.add_argument('inputs',nargs='+');args=parser.parse_args()
    if args.stride<1:parser.error('stride must be positive')
    text=pathlib.Path(args.report).read_text();report=json.loads(text[text.index('{'):])
    transforms=[np.eye(2,3)]
    transforms.extend(np.array([[a['transform']['a'],-a['transform']['b'],a['transform']['tx']],[a['transform']['b'],a['transform']['a'],a['transform']['ty']]]) for a in report['alignment'])
    if not report['alignment']:transforms=[np.eye(2,3) for _ in args.inputs]
    assert len(transforms)==len(args.inputs)
    with tempfile.TemporaryDirectory(prefix='FocusStackGolden-') as scratch:
        sources=[Source(inspect_image(pathlib.Path(path)),scratch,index) for index,path in enumerate(args.inputs)]
        config=Config(quality='max');shape=sources[0].array.shape[:2]
        for index,(core,bounds) in enumerate(tile_bounds(shape,report['tileEdge'],config.halo,2**config.pyramid_levels)):
            if index%args.stride:continue
            started=time.monotonic();gold=fuse_tile(sources,transforms,bounds,config,0)
            y0,y1,x0,x1=core;by0,_,bx0,_=bounds;gold=gold[y0-by0:y1-by0,x0-bx0:x1-bx0]
            actual=read_region(args.output,core);error=np.abs(actual.astype(np.int32)-gold.astype(np.int32))
            print(json.dumps(dict(core=core,max=int(error.max()),mean=float(error.mean()),p99=float(np.percentile(error,99)),greaterThanOne=int(np.count_nonzero(error>1)),seconds=time.monotonic()-started)),flush=True)
if __name__=='__main__':main()
