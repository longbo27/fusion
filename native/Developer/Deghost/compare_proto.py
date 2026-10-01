"""Same held-out crops, V2.1 pairwise policy vs V2.2 native candidate policy.
The prototype is evaluated in PyTorch CPU with its original sampling/thresholds;
this is a quality comparison, not hardware latency or photographic validation.
"""
import argparse,json,pathlib,sys
import numpy as np,torch
from scipy.ndimage import maximum_filter
sys.path.insert(0,str(pathlib.Path(__file__).resolve().parents[1]/'ML'))
from train_motion_proto import FocusMotionNetProto
p=argparse.ArgumentParser();p.add_argument('--directory',required=True);p.add_argument('--weights',required=True);args=p.parse_args();d=pathlib.Path(args.directory);model=FocusMotionNetProto().eval();model.load_state_dict(torch.load(args.weights,map_location='cpu',weights_only=True));torch.set_num_threads(4);results={}
with torch.no_grad():
 for e in json.loads((d/'manifest.json').read_text()):
  root=d/e['name'];h,w=e['height'],e['width'];truth=np.fromfile(root/'truth.u8',np.uint8).reshape(h,w)>0;ref=np.fromfile(root/'source0.u16',np.uint16).reshape(h,w,4)[...,0].astype(np.float32)/65535;conf=np.fromfile(root/'off.confidence.f32',np.float32).reshape(h,w)
  gy,gx=np.gradient(ref);gx[:,[0,-1]]=0;gy[[0,-1],:]=0;edge=np.hypot(gx,gy);motion=np.zeros((h,w),np.float32);iy=np.minimum(h-1,((np.arange(256)+.5)*h/256).astype(int));ix=np.minimum(w-1,((np.arange(256)+.5)*w/256).astype(int));oy=np.minimum(255,np.arange(h)*256//h);ox=np.minimum(255,np.arange(w)*256//w)
  for i in range(1,e['sources']):
   candidate=np.fromfile(root/f'source{i}.u16',np.uint16).reshape(h,w,4)[...,0].astype(np.float32)/65535;x=np.stack([ref,candidate,np.abs(ref-candidate),conf,edge]);x=x[:,iy[:,None],ix[None,:]];prob=model(torch.from_numpy(x[None]))[0].numpy();m=maximum_filter(np.minimum(prob[0],1-prob[1]),3,mode='nearest');motion=np.maximum(motion,m[oy[:,None],ox[None,:]])
  for mode,threshold in [('auto',.97),('high',.85),('t05',.05),('t10',.1),('t20',.2),('t30',.3),('t40',.4),('t50',.5),('t65',.65)]:
   mask=motion>=threshold;s=results.setdefault(e['category']+' '+mode,dict(tp=0,fp=0,fn=0,tn=0));s['tp']+=int((mask&truth).sum());s['fp']+=int((mask&~truth).sum());s['fn']+=int((~mask&truth).sum());s['tn']+=int((~mask&~truth).sum())
for s in results.values():
 tp,fp,fn,tn=[s[k] for k in ('tp','fp','fn','tn')];s.update(iou=tp/max(tp+fp+fn,1),precision=tp/max(tp+fp,1),recall=tp/max(tp+fn,1),staticFalsePositiveRate=fp/max(fp+tn,1))
(d/'prototype-comparison.json').write_text(json.dumps(results,indent=2));print(json.dumps(results,indent=2))
