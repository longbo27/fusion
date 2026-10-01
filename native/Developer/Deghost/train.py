"""Train a compact mask-only CNN; all artifacts/checkpoints remain external.
Validation seeds are independent of training and hard-negative mining seeds.
"""
import argparse,json,pathlib,sys,time,random
import numpy as np,torch
from torch import nn
from torch.nn import functional as F
from dataset import example,CATEGORIES,CHANNELS
class FocusMotionNetV1(nn.Module):
    def __init__(self):
        super().__init__()
        def block(a,b):return nn.Sequential(nn.Conv2d(a,b,3,padding=1),nn.ReLU(),nn.Conv2d(b,b,3,padding=1),nn.ReLU())
        self.e0=block(12,16);self.d0=nn.Conv2d(16,32,3,stride=2,padding=1);self.e1=block(32,32);self.d1=nn.Conv2d(32,48,3,stride=2,padding=1);self.mid=block(48,48);self.u1=block(80,32);self.u0=block(48,16);self.out=nn.Conv2d(16,7,1)
    def logits(self,x):
        a=self.e0(x);b=self.e1(F.relu(self.d0(a)));c=self.mid(F.relu(self.d1(b)));b=self.u1(torch.cat([F.interpolate(c,scale_factor=2,mode='nearest'),b],1));return self.out(self.u0(torch.cat([F.interpolate(b,scale_factor=2,mode='nearest'),a],1)))
    def forward(self,x):
        z=self.logits(x);return torch.cat([torch.sigmoid(z[:,:3]),torch.softmax(z[:,3:],dim=1)],1)
def metrics(model,device,count=40,seed=2207001):
    rng=np.random.default_rng(seed);result={}
    model.eval()
    with torch.no_grad():
        for category in CATEGORIES:
            tp=fp=fn=tn=own=total=0;static_pixels=static_fp=0
            for _ in range(count):
                x,y,o,frames,_=example(rng,128,category=category);p=model(torch.from_numpy(x[None]).to(device))[0].cpu().numpy();truth=y[0]>.5;mask=p[0]>.5
                tp+=int((mask&truth).sum());fp+=int((mask&~truth).sum());fn+=int((~mask&truth).sum());tn+=int((~mask&~truth).sum());own+=int((p[3:].argmax(0)==o).sum());total+=o.size
                if not truth.any():static_pixels+=truth.size;static_fp+=int(mask.sum())
            result[category]=dict(iou=tp/max(tp+fp+fn,1),precision=tp/max(tp+fp,1),recall=tp/max(tp+fn,1),staticFalsePositiveRate=static_fp/max(static_pixels,1),falseNegativeRate=fn/max(tp+fn,1),ownershipAccuracy=own/max(total,1),tp=tp,fp=fp,fn=fn,tn=tn)
    return result

def main():
    p=argparse.ArgumentParser();p.add_argument('--artifacts',required=True);p.add_argument('--steps',type=int,default=4000);p.add_argument('--hard-steps',type=int,default=2000);p.add_argument('--device',choices=['cpu','mps'],default='mps');p.add_argument('--external');p.add_argument('--resume');args=p.parse_args()
    out=pathlib.Path(args.artifacts).resolve();root=pathlib.Path(__file__).resolve().parents[3]
    if out.is_relative_to(root):raise ValueError('Private/training artifacts must remain outside Git')
    out.mkdir(parents=True,exist_ok=True);torch.manual_seed(2201);random.seed(2201);np.random.seed(2201);torch.set_num_threads(4)
    device=torch.device('mps' if args.device=='mps' and torch.backends.mps.is_available() else 'cpu')
    if device.type=='mps':torch.mps.set_per_process_memory_fraction(.25)
    external_train=[];external_validation=[];groups={}
    if args.external:
        for manifest in pathlib.Path(args.external).resolve().rglob('manifest.json'):
            data=json.loads(manifest.read_text())
            if not data.get('reviewed'):continue
            group=data['group'];split=data['split']
            if group in groups and groups[group]!=split:raise ValueError('Original-stack group leaks across train/validation')
            groups[group]=split;path=manifest.parent/'example.npz'
            if not path.is_file():raise ValueError('Reviewed example lacks features/masks')
            (external_train if split=='train' else external_validation).append(path)
    def load_external(path,edge=None):
        with np.load(path) as a:x=a['features'];labels=a['motion'];o=a['ownership']
        if x.shape[0]!=12 or x.shape[1]>512 or x.shape[2]>512 or labels.shape!=x.shape[1:] or o.shape!=labels.shape:raise ValueError('External feature contract mismatch')
        valid=labels!=255
        if not valid.any():raise ValueError('Reviewed example has no labeled pixels')
        if edge:
            h,w=labels.shape
            if h<edge or w<edge:raise ValueError('Training annotation crop must be at least 96 square')
            y0=int(rng.integers(h-edge+1));x0=int(rng.integers(w-edge+1));x=x[:,y0:y0+edge,x0:x0+edge];labels=labels[y0:y0+edge,x0:x0+edge];o=o[y0:y0+edge,x0:x0+edge];valid=labels!=255
        motion=(labels==1).astype(np.float32);targets=np.stack([motion,1-motion,np.where(motion>0,.95,.5+x[7]*.5)]).astype(np.float32)
        return x.astype(np.float32),targets,o.astype(np.int64),valid.astype(np.float32)
    model=FocusMotionNetV1().to(device)
    if args.resume:model.load_state_dict(torch.load(args.resume,map_location=device,weights_only=True))
    optimizer=torch.optim.AdamW(model.parameters(),lr=.001,weight_decay=.0001);rng=np.random.default_rng(2201);started=time.monotonic();hard=[]
    def train(steps,phase):
        model.train()
        for step in range(steps):
            batch=[]
            for index in range(8):
                if external_train and index==7:
                    batch.append(load_external(external_train[int(rng.integers(len(external_train)))],96))
                elif phase=='hard' and index<3 and hard:
                    x,y,o=hard[int(rng.integers(len(hard)))];batch.append((x,y,o))
                else:batch.append(example(rng,96,hard=phase=='hard')[:3])
            x=torch.from_numpy(np.stack([a[0] for a in batch])).to(device);y=torch.from_numpy(np.stack([a[1] for a in batch])).to(device);o=torch.from_numpy(np.stack([a[2] for a in batch])).to(device)
            weight=torch.from_numpy(np.stack([a[3] if len(a)>3 else np.ones((96,96),np.float32) for a in batch])).to(device)
            def masked_bce(z,y,pos=1):return (F.binary_cross_entropy_with_logits(z,y,pos_weight=torch.tensor(float(pos),device=device),reduction='none')*weight).sum()/weight.sum().clamp_min(1)
            z=model.logits(x);motion_loss=masked_bce(z[:,0],y[:,0],1.7);safe_loss=masked_bce(z[:,1],y[:,1]);confidence_loss=masked_bce(z[:,2],y[:,2]);owner_loss=F.cross_entropy(z[:,3:],o,ignore_index=255)
            dice=1-(2*(z[:,0].sigmoid()*y[:,0]).sum()+1)/(z[:,0].sigmoid().sum()+y[:,0].sum()+1)
            loss=motion_loss+safe_loss*.3+confidence_loss*.1+owner_loss*.3+dice*.3
            optimizer.zero_grad();loss.backward();optimizer.step()
            if step%100==0:print(json.dumps(dict(phase=phase,step=step,loss=float(loss.item()),seconds=time.monotonic()-started)),flush=True)
    train(args.steps,'base');torch.save(model.cpu().state_dict(),out/'before-mining.pt');model.to(device);before=metrics(model,device,count=15,seed=2206001);(out/'before-mining.json').write_text(json.dumps(before,indent=2))
    # Mandatory hard-negative mining uses unseen STATIC examples, not validation.
    model.eval();mining=np.random.default_rng(2205001);ranking=[]
    with torch.no_grad():
        for index in range(600):
            category=CATEGORIES[index%len(CATEGORIES)];x,y,o,_,_=example(mining,96,category=category,hard=True)
            if y[0].any():continue
            probability=model(torch.from_numpy(x[None]).to(device))[0,0].cpu().numpy();ranking.append((float((probability>.5).mean()),float(probability.mean()),x,y,o,category))
    ranking.sort(key=lambda a:(a[0],a[1]),reverse=True);selected=ranking[:160];hard=[(a[2],a[3],a[4]) for a in selected]
    (out/'hard-negative-mining.json').write_text(json.dumps(dict(examples=len(ranking),retained=len(hard),meanFalsePositiveRate=float(np.mean([a[0] for a in ranking])),selected=[dict(category=a[5],falsePositiveRate=a[0],meanMotion=a[1]) for a in selected]),indent=2))
    for group in optimizer.param_groups:group['lr']=.00035
    train(args.hard_steps,'hard');evaluation=metrics(model,device,count=40)
    if device.type=='mps':torch.mps.synchronize()
    model.cpu().eval();torch.save(model.state_dict(),out/'FocusMotionNetV1.pt')
    real_validation=[]
    with torch.no_grad():
        for path in external_validation:
            x,y,o,valid=load_external(path);h,w=valid.shape;prediction=np.zeros((7,h,w),np.float32)
            for yy in range(0,h,208):
                for xx in range(0,w,208):
                    iy=np.clip(np.arange(yy-24,yy+232),0,h-1);ix=np.clip(np.arange(xx-24,xx+232),0,w-1);patch=x[:,iy[:,None],ix[None,:]]
                    prob=model(torch.from_numpy(patch[None]))[0].numpy();ey=min(h,yy+208);ex=min(w,xx+208);prediction[:,yy:ey,xx:ex]=prob[:,24:24+ey-yy,24:24+ex-xx]
            truth=y[0]>.5;mask=prediction[0]>.5;known=valid>0;tp=int((mask&truth&known).sum());fp=int((mask&~truth&known).sum());fn=int((~mask&truth&known).sum());tn=int((~mask&~truth&known).sum())
            real_validation.append(dict(group=json.loads((path.parent/'manifest.json').read_text())['group'],iou=tp/max(tp+fp+fn,1),precision=tp/max(tp+fp,1),recall=tp/max(tp+fn,1),staticFalsePositiveRate=fp/max(fp+tn,1),labeledPixels=int(known.sum())))
    metadata=dict(resumedFromCheckpoint=bool(args.resume),externalTrainingExamples=len(external_train),externalValidation=real_validation,seed=2201,validationSeed=2207001,device=str(device),steps=args.steps,hardSteps=args.hard_steps,seconds=time.monotonic()-started,parameters=sum(p.numel() for p in model.parameters()),channels=CHANNELS,outputs=['motion','blend_safety','ownership_confidence','reference','best','second','third'],categories=evaluation,note='Synthetic held-out evaluation. Real photographs require separately reviewed external labels; no production-quality claim from synthetic metrics alone.')
    (out/'training.json').write_text(json.dumps(metadata,indent=2));x,y,o,_,_=example(np.random.default_rng(220999),256,category='grass');x.tofile(out/'inference-input.f32');y.tofile(out/'inference-label.f32')
    with torch.no_grad():model(torch.from_numpy(x[None])).numpy().tofile(out/'torch-output.f32')
    import coremltools as ct
    traced=torch.jit.trace(model,torch.zeros(1,12,256,256));converted=ct.convert(traced,inputs=[ct.TensorType(name='features',shape=(1,12,256,256),dtype=np.float32)],outputs=[ct.TensorType(name='probabilities',dtype=np.float32)],minimum_deployment_target=ct.target.iOS17,compute_precision=ct.precision.FLOAT16,convert_to='mlprogram')
    converted.short_description='FocusMotionNetV1: candidate motion/safety/ownership masks; no RGB synthesis.';converted.user_defined_metadata['validation_seed']='2207001';converted.save(str(out/'FocusMotionNetV1.mlpackage'));print(json.dumps(metadata),flush=True)
if __name__=='__main__':main()
