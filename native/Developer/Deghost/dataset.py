"""Bounded procedural focus/motion examples and identical model feature contract.
No photographs or generated datasets are stored in this source directory.
"""
import numpy as np
import pathlib,sys
sys.path.insert(0,str(pathlib.Path(__file__).resolve().parents[3]))
from focusstack.sharpness import photographic_score
from scipy.ndimage import gaussian_filter, shift, map_coordinates, maximum_filter, uniform_filter
CATEGORIES=('grass','leaves','branches','hair','flowers','cloud','water','waves','cloth','occlusion','silhouette','static_defocus','bokeh','noise')
CHANNELS=('reference','best','second','third','reference_best_residual','reference_second_residual','normalized_residual','focus_confidence','reference_edge','label_disagreement','temporal_std','temporal_range')

def features(frames,order=None):
    frames=np.asarray(frames,np.float32)
    # The generator uses exactly four candidates; production aggregates bounded
    # scalar temporal statistics while retaining only the three winning features.
    frames=np.rint(frames*65535).clip(0,65535).astype(np.float32)/65535
    scores=np.stack([photographic_score(np.repeat((a*65535)[...,None],3,axis=2),3,"max")[0] for a in frames])
    rank=np.argsort(-scores,axis=0,kind='stable')[:3] if order is None else order
    selected=np.take_along_axis(frames,rank,axis=0);sorted_score=np.take_along_axis(scores,rank,axis=0)
    confidence=np.clip((sorted_score[0]-sorted_score[1])/np.maximum(sorted_score[0],1e-8),0,1)
    r=frames[0];a,b,c=selected
    smooth_r=uniform_filter(r,3,mode="mirror");smooth_a=uniform_filter(a,3,mode="mirror");variance=np.maximum(uniform_filter(r*r,3,mode="mirror")-smooth_r*smooth_r,0)
    normalized=np.clip(np.abs(smooth_r-smooth_a)/(np.sqrt(variance)+.03)/4,0,1)
    gy,gx=np.gradient(r);gx[:,[0,-1]]=0;gy[[0,-1],:]=0;labels=rank[0];disagree=np.zeros_like(r)
    padded=np.pad(labels,1,mode="reflect")
    for dy,dx in [(-1,0),(1,0),(0,-1),(0,1)]:disagree+=(labels!=padded[1+dy:1+dy+r.shape[0],1+dx:1+dx+r.shape[1]])*.25
    return np.stack([r,a,b,c,np.abs(r-a),np.abs(r-b),normalized,confidence,np.hypot(gx,gy),disagree,frames.std(axis=0),np.ptp(frames,axis=0)]).astype(np.float32),rank

def example(rng,n=96,category=None,hard=False):
    category=category or CATEGORIES[int(rng.integers(len(CATEGORIES)))];yy,xx=np.mgrid[:n,:n].astype(np.float32)
    noise=rng.random((n,n),dtype=np.float32);base=gaussian_filter(noise,rng.uniform(.5,2.2));base=(base-base.min())/(np.ptp(base)+1e-6)*rng.uniform(.12,.6)+rng.uniform(.05,.25)
    base+=.03*np.sin(xx*rng.uniform(.03,.4)+yy*rng.uniform(.02,.2))
    layer=np.zeros((n,n),np.float32)
    if category in ('grass','hair','branches'):
        for _ in range(int(rng.integers(10,35))):
            x,y=rng.uniform(0,n,2);slope=rng.uniform(-1.2,1.2);width=rng.uniform(.35,1.4) if category!='branches' else rng.uniform(1,3)
            distance=xx-x-slope*(yy-y)-rng.uniform(0,2)*np.sin(yy*.07)
            line=np.exp(-(distance/width)**2)*((yy>y-25)&(yy<y+40));layer=np.maximum(layer,line)
    elif category in ('leaves','flowers','bokeh','occlusion','silhouette'):
        for _ in range(int(rng.integers(2,9))):
            x,y=rng.uniform(0,n,2);rx,ry=rng.uniform(3,18,2);angle=rng.uniform(-np.pi,np.pi);dx=(xx-x)*np.cos(angle)+(yy-y)*np.sin(angle);dy=-(xx-x)*np.sin(angle)+(yy-y)*np.cos(angle)
            disk=np.clip((1-(dx/rx)**2-(dy/ry)**2)*4,0,1)
            if category=='flowers':disk*=np.clip(.6+.6*np.cos(np.arctan2(dy,dx)*rng.integers(4,9)),0,1)
            layer=np.maximum(layer,disk)
    elif category in ('cloud','water','waves','cloth'):
        tex=gaussian_filter(rng.random((n,n),dtype=np.float32),rng.uniform(1,5))
        tex=(tex-tex.min())/(np.ptp(tex)+1e-6)
        if category in ('water','waves','cloth'):tex=.5+.3*np.sin(xx*rng.uniform(.1,.5)+yy*rng.uniform(.02,.25)+tex*4)
        layer=tex*np.clip((xx-n*.12)/(n*.15),0,1)*np.clip((n*.9-xx)/(n*.1),0,1)
    else:
        layer=gaussian_filter(rng.random((n,n),dtype=np.float32),.4)*.5
    moving=category not in ('static_defocus','bokeh','noise') and rng.random()<.75
    color=rng.uniform(.02,.98);foreground=base*(1-layer)+layer*color
    clean=[];union=np.zeros((n,n),bool);masks=[]
    for index in range(4):
        changed=layer
        if moving and index:
            dx,dy=rng.uniform(.15,7,2)*rng.choice([-1,1],2);deform=rng.uniform(0,2.5) if category in ('grass','hair','cloth','water','waves','cloud') else 0
            changed=map_coordinates(layer,[yy+dy+deform*np.sin(xx*.08),xx+dx+deform*np.sin(yy*.1)],order=1,mode='reflect')
            union|=np.abs(changed-layer)>.08
        clean.append(base*(1-changed)+changed*color);masks.append(changed)
    # Vary focus spatially; a static scene can have disappearing fine texture,
    # defocus/bokeh edges, highlight ringing and registration interpolation.
    frames=[];max_sigma=0
    for index,a in enumerate(clean):
        sigma=rng.uniform(0,3.5 if hard else 2.7)
        if category=='silhouette':sigma=max(sigma,rng.uniform(1.8,4.2))
        max_sigma=max(max_sigma,sigma)
        blurred=gaussian_filter(a,sigma);plane=(xx<n*rng.uniform(.25,.75))
        if index==0:a=blurred
        else:a=np.where(plane,blurred,gaussian_filter(a,rng.uniform(0,2.5)))
        if not moving and rng.random()<.4:
            # Residual subpixel resampling after known global breathing correction.
            sx,sy=rng.uniform(-.3,.3,2);a=shift(shift(a,(sx,sy),order=1,mode='reflect'),(-sx,-sy),order=1,mode='reflect')
        if category=='bokeh':a=gaussian_filter(a,rng.uniform(1,4))
        a=a*rng.uniform(.94,1.06)+rng.uniform(-.012,.012)
        if rng.random()<.25:a=(a-.5)*rng.uniform(.9,1.1)+.5
        if category=='noise':a+=rng.normal(0,rng.uniform(.005,.035),a.shape)
        else:a+=rng.normal(0,rng.uniform(0,.007),a.shape)
        # Small chromatic-fringe approximation affects grayscale geometry locally.
        if not moving and rng.random()<.2:a=.8*a+.2*shift(a,(0,rng.uniform(-.5,.5)),order=1,mode='reflect')
        frames.append(np.clip(a,0,1).astype(np.float32))
    motion=maximum_filter(union.astype(np.float32),2*int(np.ceil(max_sigma))+1) if moving else np.zeros((n,n),np.float32)
    x,rank=features(frames);ownership=np.where(motion>.5,0,1).astype(np.int64)
    ownership_conf=np.where(motion>.5,.95,np.clip(x[7]*2+.5,0,1)).astype(np.float32)
    targets=np.stack([motion,1-motion,ownership_conf]).astype(np.float32)
    return x,targets,ownership,np.stack(frames),category
