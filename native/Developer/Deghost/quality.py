"""Generate external bounded cases; evaluate actual native policy, not model masks.
Execute --generate, benchmark --deghost-quality DIRECTORY, then --evaluate.
No real labels are inferred automatically. RGB errors are normalized by 65535.
"""
import argparse,json,pathlib
import numpy as np
from scipy.ndimage import binary_dilation,gaussian_filter
from dataset import example,CATEGORIES
ROOT=pathlib.Path(__file__).resolve().parents[3]
def main():
 p=argparse.ArgumentParser();p.add_argument('--directory',required=True);p.add_argument('--generate',action='store_true');p.add_argument('--evaluate',action='store_true');p.add_argument('--count',type=int,default=12);args=p.parse_args();out=pathlib.Path(args.directory).resolve()
 if out.is_relative_to(ROOT):raise ValueError('Fixtures must remain outside Git')
 if args.generate:
  out.mkdir(parents=True,exist_ok=False);rng=np.random.default_rng(2211001);manifest=[]
  for category in CATEGORIES:
   for i in range(args.count):
    _,target,_,frames,_=example(rng,192,category=category,hard=True);name=f'{category}-{i:02d}';d=out/name;d.mkdir();(target[0]>.5).astype(np.uint8).tofile(d/'truth.u8')
    for j,frame in enumerate(frames):
     rgba=np.full((192,192,4),65535,np.uint16);rgba[...,:3]=np.rint(frame[...,None]*65535).astype(np.uint16);rgba.tofile(d/f'source{j}.u16')
    manifest.append(dict(name=name,category=category,width=192,height=192,sources=4))
  (out/'manifest.json').write_text(json.dumps(manifest,indent=2))
 if args.evaluate:
  tables={}
  for entry in json.loads((out/'manifest.json').read_text()):
   d=out/entry['name'];h,w=entry['height'],entry['width'];truth=np.fromfile(d/'truth.u8',np.uint8).reshape(h,w)>0;reference=np.fromfile(d/'source0.u16',np.uint16).reshape(h,w,4)[...,:3].astype(np.float32)/65535
   off=np.fromfile(d/'off.u16',np.uint16).reshape(h,w,4)[...,:3].astype(np.float32)/65535;offowners=np.fromfile(d/'off.owners.u32',np.uint32).reshape(h,w)
   for mode in ['auto','high']:
    mask=np.fromfile(d/f'{mode}.mask.u8',np.uint8).reshape(h,w)>0;rgb=np.fromfile(d/f'{mode}.u16',np.uint16).reshape(h,w,4)[...,:3].astype(np.float32)/65535;owners=np.fromfile(d/f'{mode}.owners.u32',np.uint32).reshape(h,w)
    key=entry['category']+' '+mode;s=tables.setdefault(key,dict(tp=0,fp=0,fn=0,tn=0,cases=0,ownerCorrect=0,ownerTotal=0,haloSquared=0.,haloCount=0,edgeSquared=0.,edgeCount=0,staticSquared=0.,staticCount=0,outsideMaskChanged=0,thinGradientRatioSum=0.,thinCases=0,fullyStaticPixels=0,fullyStaticFP=0))
    if not truth.any():s['fullyStaticPixels']+=truth.size;s['fullyStaticFP']+=int(mask.sum())
    s['tp']+=int((mask&truth).sum());s['fp']+=int((mask&~truth).sum());s['fn']+=int((~mask&truth).sum());s['tn']+=int((~mask&~truth).sum());s['cases']+=1
    expected=np.where(truth,0,offowners);s['ownerCorrect']+=int((owners==expected).sum());s['ownerTotal']+=truth.size
    halo=binary_dilation(truth,iterations=2)&~truth;s['haloSquared']+=float(((rgb-off)**2)[halo].sum());s['haloCount']+=int(halo.sum())*3
    s['staticSquared']+=float(((rgb-off)**2)[~truth].sum());s['staticCount']+=int((~truth).sum())*3
    s['outsideMaskChanged']+=int(np.any(rgb!=off,axis=2)[~mask].sum())
    # Motion double-edge proxy: gradient residual relative to the coherent captured
    # reference, on reliable labeled motion pixels. Thin ratio alone is not quality.
    gr=np.stack(np.gradient(rgb.mean(axis=2)))
    gf=np.stack(np.gradient(reference.mean(axis=2)));s['edgeSquared']+=float(((gr-gf)**2)[:,truth].sum());s['edgeCount']+=int(truth.sum())*2
    if truth.any() and entry['category'] in ['grass','hair','branches']:
     s['thinGradientRatioSum']+=float(np.linalg.norm(gr[:,truth])/max(np.linalg.norm(gf[:,truth]),1e-8));s['thinCases']+=1
  def finish(s):
   tp,fp,fn,tn=[s[k] for k in ('tp','fp','fn','tn')]
   return dict(fullyStaticFalsePositiveRate=s["fullyStaticFP"]/s["fullyStaticPixels"] if s["fullyStaticPixels"] else None,iou=tp/max(tp+fp+fn,1) if tp+fn else None,precision=tp/max(tp+fp,1) if tp+fp else None,recall=tp/max(tp+fn,1) if tp+fn else None,staticFalsePositiveRate=fp/max(fp+tn,1),falseNegativeRate=fn/max(tp+fn,1),ownershipAccuracy=s['ownerCorrect']/s['ownerTotal'],haloMSE=s['haloSquared']/max(s['haloCount'],1),doubleEdgeMSE=s['edgeSquared']/max(s['edgeCount'],1),thinGradientRatio=s['thinGradientRatioSum']/s['thinCases'] if s['thinCases'] else None,staticReconstructionMSE=s['staticSquared']/max(s['staticCount'],1),outsideDetectedMaskChanged=s['outsideMaskChanged'],cases=s['cases'])
  for mode in ["auto","high"]:
   rows=[s for key,s in tables.items() if key.endswith(" "+mode)]
   tables["aggregate "+mode]={k:sum(row[k] for row in rows) for k in rows[0]}
  result={key:finish(s) for key,s in tables.items()};(out/'quality-metrics.json').write_text(json.dumps(result,indent=2));print(json.dumps(result,indent=2))
if __name__=='__main__':main()
