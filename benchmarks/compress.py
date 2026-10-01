"""Transcode existing mapped TIFFs sequentially into tiled or single-strip TIFFs."""
import argparse
from pathlib import Path
import numpy as np
import tifffile
from focusstack.memory import close_mapping, evict
from .run import ICC


def transcode(source,destination,single_strip=False):
    pixels=tifffile.memmap(source,mode='r')
    try:
        h,w,_=pixels.shape
        if single_strip:
            # Opt-in decoder stress fixture: the codec inherently needs one full
            # encoded segment here; raw source remains a disk-backed mapping.
            import zlib
            import tempfile
            encoder=zlib.compressobj()
            with tempfile.TemporaryFile() as spool:
                for y in range(0,h,32):
                    spool.write(encoder.compress(np.array(pixels[y:y+32],copy=True).tobytes()))
                    evict(pixels)
                spool.write(encoder.flush())
                size=spool.tell()
                import mmap
                with mmap.mmap(spool.fileno(),size,access=mmap.ACCESS_READ) as payload:
                    tifffile.imwrite(destination,data=iter([payload[:]]),shape=pixels.shape,dtype=np.uint16,
                        photometric='rgb',metadata=None,rowsperstrip=h,compression='zlib',bigtiff=True,
                        iccprofile=ICC,resolution=(300,300),resolutionunit='INCH')
        else:
            def tiles():
                for y in range(0,h,256):
                    for x in range(0,w,256):
                        block=np.zeros((256,256,3),np.uint16)
                        ey,ex=min(y+256,h),min(x+256,w)
                        block[:ey-y,:ex-x]=pixels[y:ey,x:ex]
                        evict(pixels)
                        yield block
            tifffile.imwrite(destination,data=tiles(),shape=pixels.shape,dtype=np.uint16,
                photometric='rgb',metadata=None,tile=(256,256),compression='zlib',bigtiff=True,
                maxworkers=1,buffersize=1024**2,iccprofile=ICC,resolution=(300,300),resolutionunit='INCH')
    finally:
        close_mapping(pixels)


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('source',type=Path)
    p.add_argument('destination',type=Path)
    p.add_argument('--single-strip',action='store_true')
    a=p.parse_args()
    a.destination.parent.mkdir(parents=True,exist_ok=True)
    transcode(a.source,a.destination,a.single_strip)
