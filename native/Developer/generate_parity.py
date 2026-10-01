"""Use unchanged Python golden modules. Small developer arrays remain outside Git."""
import sys,pathlib,argparse,json
import numpy as np,cv2
from types import SimpleNamespace
sys.path.insert(0,str(pathlib.Path(__file__).resolve().parents[2]))
from focusstack.sharpness import photographic_score,smooth,focus_score,luminance
from focusstack.depth import Candidates,regularize
from focusstack.blending import occlusion_weight,source_weight
from focusstack.pyramid import Multiband
from focusstack.io import Source
p=argparse.ArgumentParser();p.add_argument('--artifacts',required=True);args=p.parse_args();out=pathlib.Path(args.artifacts).resolve();out.mkdir(parents=True,exist_ok=True)
if out.is_relative_to(pathlib.Path(__file__).resolve().parents[2]):raise ValueError('Fixtures outside repository')
manifest=[]
for quality in ['standard','high','max']:
 for scene in ['flat','texture','edges','branches','planes','odd','halo','affine']:
  h,w=(97,129) if scene=='odd' else ((193,257) if scene=='halo' else (96,128))
  y,x=np.mgrid[:h,:w];rng=np.random.default_rng(27)
  rgb=np.stack([(x*503+y*89)%60000,(x*29+y*881)%62000,(x*317+y*271)%63000],-1).astype(np.float32)
  if scene=='flat':rgb[:]=[1234,23456,54321]
  elif scene=='texture':rgb[:]=rng.uniform(1000,64000,rgb.shape)
  elif scene=='edges':rgb[:]=1000;rgb[:,w//2:]=[61001,62002,63003]
  elif scene=='branches':rgb[:]=22000;rgb[np.abs(x-w*.3-y*.4)<1.2]=[61001,12002,31003]
  frames=[]
  for i in range(3):
   blurred=cv2.GaussianBlur(rgb,(7,7),.8+i*.7)
   if scene in ['planes','halo']:
    a=cv2.GaussianBlur(rgb,(7,7),2);selector=x<w//2 if i==0 else x>=w//2 if i==1 else np.zeros(x.shape,bool);a[selector]=rgb[selector];blurred=a
   frames.append(np.rint(blurred).clip(0,65535).astype(np.uint16))
  transforms=[dict(a=1.,b=0.,tx=0.,ty=0.),dict(a=1.005,b=.008,tx=3.125,ty=-1.875),dict(a=.996,b=-.007,tx=-2.5,ty=3.75)] if scene=='affine' else [dict(a=1.,b=0.,tx=0.,ty=0.) for _ in frames]
  warped=[];validity=[]
  for a,t in zip(frames,transforms):
   source=SimpleNamespace(array=a,info=SimpleNamespace(dtype=a.dtype),release_pages=lambda:None)
   matrix=np.array([[t['a'],-t['b'],t['tx']],[t['b'],t['a'],t['ty']]])
   rgb,valid=Source.warp_tile(source,matrix,(0,h,0,w));warped.append(rgb);validity.append(valid)
  dest=out/(scene+"-"+quality);dest.mkdir(exist_ok=True);c=Candidates((h,w),3);guide=np.zeros((h,w),np.float32)
  for i,a in enumerate(frames):
   rgba=np.full((h,w,4),65535,np.uint16);rgba[...,:3]=a;rgba.tofile(dest/f'source{i}.u16')
   rgb=warped[i];score,gray=(focus_score(rgb,3),luminance(rgb)) if quality=='standard' else photographic_score(rgb,3,quality)
   support=4 if quality=='standard' else 14;eligible=cv2.erode(validity[i].astype(np.uint8),np.ones((2*support+1,2*support+1),np.uint8),borderType=cv2.BORDER_CONSTANT,borderValue=1).astype(bool);score[~eligible]=-1
   score.tofile(dest/f'score{i}.f32');winner=c.update(score,i);guide[winner]=gray[winner]
  conf=c.confidence();labels,edge=regularize(c,conf,guide);
  if quality=='standard':
   labels=c.indices[0].copy();median=cv2.medianBlur(labels,3);labels[conf<.25]=median[conf<.25]
  c.indices.transpose(1,2,0).astype(np.uint32).tofile(dest/'candidates.u32');conf.tofile(dest/'confidence.f32');labels.astype(np.uint32).tofile(dest/'labels.u32')
  mb=Multiband((h,w),{'standard':0,'high':3,'max':4}[quality]);owned=np.zeros((h,w,3),np.float32);protect=np.maximum(np.clip(conf*5,0,1),edge)
  for i,a in enumerate(warped):
   weight,pr,own=occlusion_weight(labels,i,conf,edge,8,validity[i]);
   if quality=='standard':weight=source_weight(labels,i,conf,8,validity[i])
   mb.add(a,weight,None if quality=='standard' else (pr,own));owned+=a*own[...,None]
  image,covered=mb.finish();image.tofile(dest/'reconstruction.f32');image=image if quality=='standard' else image*(1-protect[...,None])+owned*protect[...,None];np.rint(image).clip(0,65535).astype(np.uint16).tofile(dest/'final.u16')
  manifest.append({'name':scene+'-'+quality,'width':w,'height':h,'quality':quality,'transforms':transforms})
(out/'manifest.json').write_text(json.dumps(manifest));print(out)
