"""Developer-only, deterministic synthetic mask training. Never produces photographic RGB.
Install torch==2.7.1 coremltools==9.0 numpy==2.2.6 scipy==1.18.1 in a separate venv.
All datasets/checkpoints/logs go to --artifacts, outside the repository.
"""
import argparse, json, pathlib, random, time
import numpy as np
import torch
from torch import nn
from scipy.ndimage import gaussian_filter, shift, binary_dilation, affine_transform

class FocusMotionNetProto(nn.Module):
    def __init__(self):
        super().__init__()
        self.network=nn.Sequential(nn.Conv2d(5,12,3,padding=1),nn.ReLU(),
            nn.Conv2d(12,12,3,padding=2,dilation=2),nn.ReLU(),
            nn.Conv2d(12,12,3,padding=3,dilation=3),nn.ReLU(),nn.Conv2d(12,2,1))
    def forward(self,x): return torch.sigmoid(self.network(x))

def example(rng, n=64):
    yy,xx=np.mgrid[:n,:n]; kind=int(rng.integers(0,8))
    base=gaussian_filter(rng.random((n,n),dtype=np.float32),rng.uniform(.4,2))
    base=(base-base.min())/(base.max()-base.min()+1e-5)*.6+.15
    # Lines: grass, hair, branches. Ellipses: leaves/occlusion. Smooth noise:
    # cloud/water; sinusoidal textures: waves. Move/deform only a foreground layer.
    layer=np.zeros((n,n),np.float32)
    if kind<3:
        for _ in range(12):
            x0,y0=rng.uniform(0,n,2);angle=rng.uniform(-1,1);width=rng.uniform(.3,1.3)
            layer=np.maximum(layer,np.exp(-((xx-x0-angle*(yy-y0))/width)**2)*((yy>y0-15)&(yy<y0+20)))
    elif kind<6:
        for _ in range(4):
            x0,y0=rng.uniform(0,n,2);a,b=rng.uniform(3,12,2)
            layer=np.maximum(layer,(((xx-x0)/a)**2+((yy-y0)/b)**2<1).astype(np.float32))
    else:
        tex=gaussian_filter(rng.random((n,n)),3)
        if kind==7: tex+=.12*np.sin(xx*.4+yy*.7)
        layer=(tex>np.quantile(tex,.7)).astype(np.float32)
    motion=bool(rng.random()<.5)
    foreground=base*(1-layer)+layer*rng.uniform(.05,.95)
    if motion:
        dy,dx=rng.uniform(-6,6,2); moved=shift(layer,(dy,dx),order=1,mode='constant')
        # A shear supplies local deformation examples, with known ownership changes.
        if rng.random()<.3:
            moved=np.stack([np.roll(moved[y],int(3*np.sin(y*.15))) for y in range(n)])
        candidate=base*(1-moved)+moved*rng.uniform(.05,.95)
        mask=binary_dilation(np.abs(layer-moved)>.12,iterations=1).astype(np.float32)
    else:
        candidate=foreground.copy();mask=np.zeros((n,n),np.float32)
        if rng.random()<.35:
            # Simulated focus breathing followed by the known global inverse
            # registration. Only interpolation/focus residuals remain: mask=0.
            scale=float(rng.uniform(.96,1.04));center=np.array([(n-1)/2]*2)
            breathed=affine_transform(candidate,np.eye(2)/scale,offset=center*(1-1/scale),order=1,mode='reflect')
            candidate=affine_transform(breathed,np.eye(2)*scale,offset=center*(1-scale),order=1,mode='reflect')
    ref=gaussian_filter(foreground,rng.uniform(0,1.6));cand=gaussian_filter(candidate,rng.uniform(0,1.6))
    cand=np.clip(cand*rng.uniform(.96,1.04)+rng.normal(0,.003,cand.shape),0,1)
    ref=np.clip(ref+rng.normal(0,.003,ref.shape),0,1)
    edge=np.hypot(*np.gradient(ref)); confidence=np.clip(1-gaussian_filter(np.abs(ref-cand),2)*4,0,1)
    features=np.stack([ref,cand,np.abs(ref-cand),confidence,edge]).astype(np.float32)
    target=np.stack([mask,1-mask]).astype(np.float32)
    return features,target,kind,motion

def main():
    p=argparse.ArgumentParser();p.add_argument('--artifacts',required=True);p.add_argument('--steps',type=int,default=1200);args=p.parse_args()
    out=pathlib.Path(args.artifacts).resolve();out.mkdir(parents=True,exist_ok=True)
    root=pathlib.Path(__file__).resolve().parents[3]
    if out.is_relative_to(root): raise ValueError('Training artifacts must remain outside repository')
    torch.manual_seed(27);np.random.seed(27);random.seed(27);torch.set_num_threads(4)
    rng=np.random.default_rng(27);model=FocusMotionNetProto();optimizer=torch.optim.Adam(model.parameters(),lr=.002)
    started=time.time();model.train()
    for step in range(args.steps):
        batch=[example(rng) for _ in range(12)];x=torch.from_numpy(np.stack([a[0] for a in batch]));y=torch.from_numpy(np.stack([a[1] for a in batch]))
        prediction=model(x);weight=1+y[:,0:1]*4
        loss=(-(y*torch.log(prediction+1e-6)+(1-y)*torch.log(1-prediction+1e-6))*weight).mean()
        optimizer.zero_grad();loss.backward();optimizer.step()
        if step%100==0: print(json.dumps({'step':step,'loss':loss.item(),'seconds':time.time()-started}),flush=True)
    model.eval();held=np.random.default_rng(7001);tp=fp=fn=tn=0;static_means=[];motion_means=[]
    with torch.no_grad():
        for _ in range(160):
            x,y,kind,motion=example(held);pred=model(torch.from_numpy(x[None]))[0,0].numpy();truth=y[0]>.5;binary=pred>.5
            tp+=int((binary&truth).sum());fp+=int((binary&~truth).sum());fn+=int((~binary&truth).sum());tn+=int((~binary&~truth).sum())
            if motion:motion_means.append(float(pred[truth].mean()) if truth.any() else 0)
            else:static_means.append(float(pred.mean()))
    metrics={'seed':27,'steps':args.steps,'trainingSeconds':time.time()-started,'precision':tp/max(tp+fp,1),'recall':tp/max(tp+fn,1),'iou':tp/max(tp+fp+fn,1),'staticMeanMotion':float(np.mean(static_means)),'motionRegionMean':float(np.mean(motion_means)),'parameters':sum(p.numel() for p in model.parameters()),'note':'Synthetic-only held-out evaluation; no production quality claim.'}
    (out/'training.json').write_text(json.dumps(metrics,indent=2));torch.save(model.state_dict(),out/'prototype.pt')
    x,y,_,_=example(np.random.default_rng(99),256);x.tofile(out/'inference-input.f32');y.tofile(out/'inference-label.f32')
    with torch.no_grad():model(torch.from_numpy(x[None])).numpy().tofile(out/'torch-output.f32')
    import coremltools as ct
    traced=torch.jit.trace(model,torch.zeros(1,5,256,256))
    converted=ct.convert(traced,inputs=[ct.TensorType(name='features',shape=(1,5,256,256),dtype=np.float32)],outputs=[ct.TensorType(name='probabilities',dtype=np.float32)],minimum_deployment_target=ct.target.iOS17,compute_precision=ct.precision.FLOAT16,convert_to='mlprogram')
    converted.short_description='Synthetic FocusMotionNetProto: motion and blend-safety masks only. Not a production model.'
    converted.user_defined_metadata['synthetic_seed']='27';converted.save(str(out/'FocusMotionNetProto.mlpackage'))
    print(json.dumps(metrics),flush=True)
if __name__=='__main__':main()
