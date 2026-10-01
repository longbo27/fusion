"""Small deterministic occlusion ground truths and objective V1/V1.1 comparison."""
import argparse
from dataclasses import replace
import json
from pathlib import Path
import tempfile
import cv2
import numpy as np
import tifffile
from focusstack import Config, stack


def occlusion_scene(bright=False):
    h,w=257,321
    rng=np.random.default_rng(81)
    low,high=(3000,17000) if bright else (33000,49000)
    background=cv2.GaussianBlur(rng.integers(low,high,(h,w,3),dtype=np.uint16),(3,3),.5).astype(np.float32)
    # Structured background makes texture fidelity distinguishable from halo error.
    mask=np.zeros((h,w),np.uint8)
    cv2.circle(mask,(130,120),45,1,-1)
    cv2.line(mask,(40,30),(265,225),1,2)
    cv2.line(mask,(285,25),(30,220),1,1)
    cv2.line(mask,(90,20),(90,230),1,2)
    alpha=mask.astype(np.float32)[...,None]
    color=np.array([58000,54000,61000] if bright else [2500,4200,1800],np.float32)
    foreground=np.broadcast_to(color,background.shape)
    truth=foreground*alpha+background*(1-alpha)
    near=foreground*alpha+cv2.GaussianBlur(background,(23,23),4)*(1-alpha)
    soft=cv2.GaussianBlur(alpha[...,0],(31,31),5)[...,None]
    far=foreground*soft+background*(1-soft)
    boundary=(cv2.dilate(mask,np.ones((17,17),np.uint8))-cv2.erode(mask,np.ones((5,5),np.uint8))).astype(bool)
    thin=mask.astype(bool) & (np.indices(mask.shape)[1]>190)
    return truth.astype(np.uint16),[near.astype(np.uint16),far.astype(np.uint16)],boundary,thin


def compare(directory):
    results={}
    for bright in (False,True):
        truth,frames,boundary,thin=occlusion_scene(bright)
        paths=[]
        for i,frame in enumerate(frames):
            p=directory/f'input-{i}.tif'
            tifffile.imwrite(p,frame,photometric='rgb',metadata=None)
            paths.append(p)
        modes={}
        for quality in ('standard','max'):
            c=Config(quality=quality,alignment='none',tile_size=128,temp_dir=directory/'scratch')
            result=stack(paths,directory/f'{quality}.tif',c)
            image=tifffile.imread(result.output)
            error=(image.astype(np.float32)-truth)**2
            one=stack(paths,directory/f'{quality}-one.tif',replace(c,tile_size=512))
            modes[quality]=dict(mse=float(error.mean()),halo_mse=float(error[boundary].mean()),
                thin_mse=float(error[thin].mean()),
                seam_max=int(np.max(np.abs(image.astype(np.int32)-tifffile.imread(one.output).astype(np.int32)))))
        results['bright' if bright else 'dark']=modes
    return results


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--report-json',type=Path)
    a=p.parse_args()
    with tempfile.TemporaryDirectory(prefix='focusstack-quality-') as d:
        results=compare(Path(d))
    text=json.dumps(results,indent=2)
    print(text)
    if a.report_json:
        a.report_json.write_text(text)
