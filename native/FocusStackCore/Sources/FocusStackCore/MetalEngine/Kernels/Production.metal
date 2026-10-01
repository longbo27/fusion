#include <metal_stdlib>
using namespace metal;
#pragma clang fp contract(off)
constant float fsEpsilon=0x1.0p-23f;
struct P { uint4 size; float4 value; float4 map0; float4 map1; };
inline int ref101(int x,int n){if(n<=1)return 0;while(x<0||x>=n)x=x<0?-x:2*n-2-x;return x;}
inline float4 at(device const float4*a,int x,int y,uint w,uint h){return a[ref101(y,h)*w+ref101(x,w)];}
inline float2 gradients(device const float4*a,int x,int y,uint w,uint h){
 float a0=at(a,x-1,y-1,w,h).x,b=at(a,x,y-1,w,h).x,c=at(a,x+1,y-1,w,h).x;
 float d=at(a,x-1,y,w,h).x,f=at(a,x+1,y,w,h).x,g=at(a,x-1,y+1,w,h).x,h0=at(a,x,y+1,w,h).x,i=at(a,x+1,y+1,w,h).x;
 return float2(((c-a0)+(i-g))+2*(f-d),(((g+i)+h0)+h0)-(((a0+c)+b)+b));
}
inline float4 up(device const float4*a,int x,int y,uint w,uint h){
 const float g[5]={.0625,.25,.375,.25,.0625};float4 v=0;
 for(int dy=-2;dy<=2;dy++)for(int dx=-2;dx<=2;dx++){
  int xx=ref101(x+dx,2*w),yy=ref101(y+dy,2*h);
  if(!(xx&1)&&!(yy&1))v+=a[(yy/2)*w+xx/2]*(4*g[dx+2]*g[dy+2]);
 }return v;
}
kernel void fsWarp(device const ushort4*in [[buffer(0)]],device float4*out [[buffer(1)]],constant P&p [[buffer(5)]],uint2 q [[thread_position_in_grid]]){
 uint w=p.size.x,h=p.size.y;if(q.x>=w||q.y>=h)return;
 float gx=q.x+p.map0.w,gy=q.y+p.map1.w;
 float sx=p.map0.x*gx+p.map0.y*gy+p.map0.z,sy=p.map1.x*gx+p.map1.y*gy+p.map1.z;
 float valid=sx>=-.0001&&sy>=-.0001&&sx<=p.value.z-1+.0001&&sy<=p.value.w-1+.0001?1:0;
 // OpenCV INTER_LINEAR's 1/32 table: quantize global coordinates before subtracting ROI.
 sx=rint(sx*32)/32-p.value.x;sy=rint(sy*32)/32-p.value.y;
 int x=floor(sx),y=floor(sy);float fx=sx-x,fy=sy-y;uint sw=p.size.z,sh=p.size.w;
 float4 a=float4(in[clamp(y,0,int(sh)-1)*sw+clamp(x,0,int(sw)-1)]);
 float4 b=float4(in[clamp(y,0,int(sh)-1)*sw+clamp(x+1,0,int(sw)-1)]);
 float4 c=float4(in[clamp(y+1,0,int(sh)-1)*sw+clamp(x,0,int(sw)-1)]);
 float4 d=float4(in[clamp(y+1,0,int(sh)-1)*sw+clamp(x+1,0,int(sw)-1)]);
 float w0=(1-fx)*(1-fy),w1=fx*(1-fy),w2=(1-fx)*fy,w3=fx*fy;
 out[q.y*w+q.x]=float4(fma(d.xyz,float3(w3),fma(c.xyz,float3(w2),fma(a.xyz,float3(w0),b.xyz*w1))),valid);
}
kernel void fsErode(device const float4*a [[buffer(0)]],device float4*b [[buffer(1)]],constant P&p [[buffer(5)]],uint2 q [[thread_position_in_grid]]){
 if(any(q>=p.size.xy))return;int r=int(p.value.x);float v=1;
 for(int d=-r;d<=r;d++){int2 t=int2(q)+(p.value.y==0?int2(d,0):int2(0,d));if(all(t>=0)&&t.x<int(p.size.x)&&t.y<int(p.size.y))v=min(v,a[t.y*p.size.x+t.x].w);}
 float4 rgb=a[q.y*p.size.x+q.x];rgb.w=v;b[q.y*p.size.x+q.x]=rgb;
}
kernel void fsMoments(device const float4*rgb [[buffer(0)]],device float4*gray [[buffer(1)]],constant P&p [[buffer(5)]],uint2 q [[thread_position_in_grid]]){
 if(any(q>=p.size.xy))return;uint k=q.y*p.size.x+q.x;float l=dot(rgb[k].xyz,float3(.299,.587,.114));gray[k]=float4(l,l*l,0,0);
}
kernel void fsMixed(device const float4*a [[buffer(0)]],device float4*b [[buffer(1)]],constant P&p [[buffer(5)]],uint2 q [[thread_position_in_grid]]){
 if(any(q>=p.size.xy))return;float v=at(a,q.x,q.y,p.size.x,p.size.y).x-at(a,q.x+1,q.y,p.size.x,p.size.y).x-at(a,q.x,q.y+1,p.size.x,p.size.y).x+at(a,q.x+1,q.y+1,p.size.x,p.size.y).x;
 float4 m=a[q.y*p.size.x+q.x];m.z=v*v;b[q.y*p.size.x+q.x]=m;
}
kernel void fsGaussian(device const float4*a [[buffer(0)]],device float4*b [[buffer(1)]],constant float*g [[buffer(2)]],constant P&p [[buffer(5)]],uint2 q [[thread_position_in_grid]]){
 if(any(q>=p.size.xy))return;int r=int(p.value.x);float4 v=0;
 if(p.value.y==0&&r==1){float4 pair=at(a,int(q.x)-1,q.y,p.size.x,p.size.y)+at(a,int(q.x)+1,q.y,p.size.x,p.size.y);v=fma(at(a,q.x,q.y,p.size.x,p.size.y),float4(g[1]),pair*g[2]);}
 else if(p.value.y==1||r<=2){
  v=at(a,q.x,q.y,p.size.x,p.size.y)*g[r];
  for(int d=1;d<=r;d++){
   float4 pair=at(a,int(q.x)-(p.value.y==0?d:0),int(q.y)-(p.value.y==0?0:d),p.size.x,p.size.y)+at(a,int(q.x)+(p.value.y==0?d:0),int(q.y)+(p.value.y==0?0:d),p.size.x,p.size.y);
   v=fma(pair,float4(g[r+d]),v);
  }
 }else{
  v=at(a,int(q.x)-r,q.y,p.size.x,p.size.y)*g[0];
  for(int d=-r+1;d<=r;d++)v=fma(at(a,int(q.x)+d,q.y,p.size.x,p.size.y),float4(g[d+r]),v);
 }b[q.y*p.size.x+q.x]=v;
}
kernel void fsTensor(device const float4*a [[buffer(0)]],device float4*b [[buffer(1)]],constant P&p [[buffer(5)]],uint2 q [[thread_position_in_grid]]){
 if(any(q>=p.size.xy))return;float2 g=gradients(a,q.x,q.y,p.size.x,p.size.y);b[q.y*p.size.x+q.x]=float4(g.x*g.x,g.y*g.y,g.x*g.y,0);
}
kernel void fsNoise(device const float4*m [[buffer(0)]],device const float4*t [[buffer(1)]],device float4*b [[buffer(2)]],constant P&p [[buffer(5)]],uint2 q [[thread_position_in_grid]]){
 if(any(q>=p.size.xy))return;uint k=q.y*p.size.x+q.x;float4 s=m[k],u=t[k];float coh=sqrt((u.x-u.y)*(u.x-u.y)+4*u.z*u.z)/max(u.x+u.y,1.0f);
 float noise=s.z*.25*max(1-coh*coh,0.0f),variance=max(s.y-s.x*s.x,0.0f);b[k]=float4(noise,variance/(variance+2*noise+1024),0,0);
}
kernel void fsEvidence(device const float4*a [[buffer(0)]],device const float4*n [[buffer(1)]],device float4*b [[buffer(2)]],constant P&p [[buffer(5)]],uint2 q [[thread_position_in_grid]]){
 if(any(q>=p.size.xy))return;uint k=q.y*p.size.x+q.x;float2 g=gradients(a,q.x,q.y,p.size.x,p.size.y);
 float lap=((at(a,q.x,q.y-1,p.size.x,p.size.y).x+at(a,q.x-1,q.y,p.size.x,p.size.y).x)-4*a[k].x)+at(a,q.x+1,q.y,p.size.x,p.size.y).x+at(a,q.x,q.y+1,p.size.x,p.size.y).x;
 b[k]=float4(g.x*g.x+g.y*g.y,lap*lap,n[k].x,0);
}
kernel void fsScore(device const float4*e [[buffer(0)]],device const float4*n [[buffer(1)]],device float4*s [[buffer(2)]],constant P&p [[buffer(5)]],uint2 q [[thread_position_in_grid]]){
 if(any(q>=p.size.xy))return;uint k=q.y*p.size.x+q.x;float v=p.value.z==1?e[k].x:(max(e[k].x-e[k].z*p.value.x*1.5,0.0f)+.2*max(e[k].y-n[k].x*.5,0.0f))*n[k].y;
 s[k].x+=p.value.y*v;
 // First-order Float32 forward-error envelope for the local nonnegative score
 // terms, retaining cancellation condition. 32 rounded aggregation/score ops.
 float terms=p.value.z==1?abs(e[k].x):(abs(e[k].x)+abs(e[k].z*p.value.x*1.5)+.2*(abs(e[k].y)+abs(n[k].x*.5)))*abs(n[k].y);
 s[k].y+=p.value.y*terms*(32*fsEpsilon/(1-32*fsEpsilon));
}
kernel void fsClear(device float4*a [[buffer(0)]],constant P&p [[buffer(5)]],uint2 q [[thread_position_in_grid]]){if(any(q>=p.size.xy))return;a[q.y*p.size.x+q.x]=float4(p.value.x);}
kernel void fsTop(device const float4*s [[buffer(0)]],device const float4*g [[buffer(1)]],device float4*top [[buffer(2)]],device uint4*ids [[buffer(3)]],device float4*guide [[buffer(4)]],device float4*luma [[buffer(6)]],device float4*temporal [[buffer(7)]],device float4*uncertainty [[buffer(8)]],constant P&p [[buffer(5)]],uint2 q [[thread_position_in_grid]]){
 if(any(q>=p.size.xy))return;uint k=q.y*p.size.x+q.x;float v=s[k].x;uint id=uint(p.value.x);float4 t=top[k],l=luma[k],u=uncertainty[k];uint4 a=ids[k];float gray=g[k].x/65535;
 float4 m=temporal[k];if(id==0){m=float4(gray,0,gray,gray);l.w=gray;t.w=v;u.w=s[k].y;}
 else{float delta=gray-m.x;m.x+=delta/float(id+1);m.y+=delta*(gray-m.x);m.z=min(m.z,gray);m.w=max(m.w,gray);}temporal[k]=m;
 if(v>t.x){l.z=l.y;l.y=l.x;l.x=gray;u.z=u.y;u.y=u.x;u.x=s[k].y;t.z=t.y;t.y=t.x;t.x=v;a.z=a.y;a.y=a.x;a.x=id;guide[k].x=g[k].x;}
 else if(v>t.y){l.z=l.y;l.y=gray;u.z=u.y;u.y=s[k].y;t.z=t.y;t.y=v;a.z=a.y;a.y=id;}
 else if(v>t.z){l.z=gray;u.z=s[k].y;t.z=v;a.z=id;}top[k]=t;ids[k]=a;luma[k]=l;uncertainty[k]=u;
}
kernel void fsInvalidate(device const float4*rgb [[buffer(0)]],device float4*s [[buffer(1)]],constant P&p [[buffer(5)]],uint2 q [[thread_position_in_grid]]){if(any(q>=p.size.xy))return;uint k=q.y*p.size.x+q.x;if(rgb[k].w<.5)s[k].x=-1;}
kernel void fsDepth(device const float4*t [[buffer(0)]],device const float4*g [[buffer(1)]],device float4*d [[buffer(2)]],constant P&p [[buffer(5)]],uint2 q [[thread_position_in_grid]]){
 if(any(q>=p.size.xy))return;uint k=q.y*p.size.x+q.x;float conf=clamp((max(t[k].x,0.0f)-max(t[k].y,0.0f))/max(t[k].x,1e-8f),0.0f,1.0f);
 float edge=clamp(length(gradients(g,q.x,q.y,p.size.x,p.size.y))/16000,0.0f,1.0f);d[k]=float4(conf,edge,g[k].x,max(clamp(conf*5,0.0f,1.0f),edge));
}
kernel void fsCleanup(device const float4*d [[buffer(0)]],device const float4*t [[buffer(1)]],device const uint4*ids [[buffer(2)]],device uint4*out [[buffer(3)]],device const float4*uncertainty [[buffer(6)]],constant P&p [[buffer(5)]],uint2 q [[thread_position_in_grid]]){
 if(any(q>=p.size.xy))return;uint k=q.y*p.size.x+q.x;uint values[9];int j=0;
 for(int dy=-1;dy<=1;dy++)for(int dx=-1;dx<=1;dx++)values[j++]=ids[clamp(int(q.y)+dy,0,int(p.size.y)-1)*p.size.x+clamp(int(q.x)+dx,0,int(p.size.x)-1)].x;
 for(int i=1;i<9;i++)for(int n=i;n>0&&values[n]<values[n-1];n--){uint v=values[n];values[n]=values[n-1];values[n-1]=v;}
 uint4 a=ids[k];uint med=values[4];bool allowed=(med==a.x&&t[k].x>=0)||(med==a.y&&t[k].y>=0)||(med==a.z&&t[k].z>=0);
 out[k]=ids[k];out[k].w=p.value.x>.2?(d[k].x<p.value.x?med:a.x):((d[k].x<p.value.x&&d[k].y<.35&&allowed)?med:a.x);
 // Never override a spatial median decision, a protected thin edge, exact
 // zero evidence, or the legacy Standard path. Stabilize only positive
 // ambiguous scores where the existing cleanup retained the local winner.
 if(p.value.y>0 && p.value.x<=.2 && d[k].x>0 && d[k].x<=64*fsEpsilon && d[k].y<.35 && !allowed && out[k].w==a.x && t[k].x>0){
  float4 u=uncertainty[k];uint stable=a.x;
  if(t[k].x-t[k].y<=u.x+u.y && t[k].y>=0)stable=min(stable,a.y);
  if(t[k].x-t[k].z<=u.x+u.z && t[k].z>=0)stable=min(stable,a.z);
  if(t[k].x-t[k].w<=u.x+u.w && t[k].w>=0)stable=0;
  out[k].w=stable;
 }
}
kernel void fsMask(device const uint4*ids [[buffer(0)]],device const float4*rgb [[buffer(1)]],device float4*m [[buffer(2)]],constant P&p [[buffer(5)]],uint2 q [[thread_position_in_grid]]){if(any(q>=p.size.xy))return;uint k=q.y*p.size.x+q.x;m[k]=float4(ids[k].w==uint(p.value.x)?1:0,0,0,0);}
kernel void fsWeights(device const float4*mask [[buffer(0)]],device const float4*local [[buffer(1)]],device const float4*depth [[buffer(2)]],device const float4*rgb [[buffer(3)]],device float4*weights [[buffer(4)]],constant P&p [[buffer(5)]],uint2 q [[thread_position_in_grid]]){
 if(any(q>=p.size.xy))return;uint k=q.y*p.size.x+q.x;float m=mask[k].x,l=local[k].x,protect=max(clamp(depth[k].x*p.value.x,0.0f,1.0f),depth[k].y);
 float softness=(1-protect)*clamp(4*l*(1-l),0.0f,1.0f);float weight=p.value.x==4?clamp(depth[k].x*4,0.0f,1.0f)*m+(1-clamp(depth[k].x*4,0.0f,1.0f))*l:m*(1-softness)+l*softness;weights[k]=float4(weight*rgb[k].w,m*rgb[k].w,protect,0);
}
kernel void fsDown(device const float4*a [[buffer(0)]],device float4*b [[buffer(1)]],constant P&p [[buffer(5)]],uint2 q [[thread_position_in_grid]]){
 if(any(q>=p.size.xy))return;const float g[5]={.0625,.25,.375,.25,.0625};float4 v=0;
 for(int y=-2;y<=2;y++)for(int x=-2;x<=2;x++)v+=at(a,int(q.x)*2+x,int(q.y)*2+y,p.size.z,p.size.w)*(g[x+2]*g[y+2]);b[q.y*p.size.x+q.x]=v;
}
kernel void fsAccumulate(device const float4*rgb [[buffer(0)]],device const float4*coarse [[buffer(1)]],device const float4*weights [[buffer(2)]],device const float4*hard [[buffer(3)]],device float4*acc [[buffer(4)]],constant P&p [[buffer(5)]],uint2 q [[thread_position_in_grid]]){
 if(any(q>=p.size.xy))return;uint k=q.y*p.size.x+q.x,stride=uint(p.value.x),fullw=uint(p.value.y);float w=weights[k].x;
 if(stride>1){float4 h=hard[q.y*stride*fullw+q.x*stride];w=w*(1-h.z)+h.y*h.z;}
 float3 lap=rgb[k].xyz;if(p.value.z>0)lap-=up(coarse,q.x,q.y,p.size.z,p.size.w).xyz;
 acc[k]+=float4(lap*w,w);
}
kernel void fsOwned(device const float4*rgb [[buffer(0)]],device const float4*w [[buffer(1)]],device float4*owned [[buffer(2)]],constant P&p [[buffer(5)]],uint2 q [[thread_position_in_grid]]){if(any(q>=p.size.xy))return;uint k=q.y*p.size.x+q.x;owned[k].xyz+=rgb[k].xyz*w[k].y;}
kernel void fsNormalize(device float4*a [[buffer(0)]],constant P&p [[buffer(5)]],uint2 q [[thread_position_in_grid]]){if(any(q>=p.size.xy))return;uint k=q.y*p.size.x+q.x;a[k].xyz/=max(a[k].w,1e-8f);}
kernel void fsReconstruct(device const float4*lap [[buffer(0)]],device const float4*coarse [[buffer(1)]],device float4*out [[buffer(2)]],constant P&p [[buffer(5)]],uint2 q [[thread_position_in_grid]]){if(any(q>=p.size.xy))return;uint k=q.y*p.size.x+q.x;out[k]=float4(lap[k].xyz+up(coarse,q.x,q.y,p.size.z,p.size.w).xyz,lap[k].w);}
kernel void fsFinal(device const float4*rgb [[buffer(0)]],device const float4*owned [[buffer(1)]],device const float4*depth [[buffer(2)]],device const float4*reference [[buffer(3)]],device ushort4*out [[buffer(4)]],constant P&p [[buffer(5)]],device const float4*motion [[buffer(6)]],uint2 q [[thread_position_in_grid]]){
 if(any(q>=p.size.xy))return;uint k=q.y*p.size.x+q.x;float protect=p.value.x==0?0:depth[k].w;float3 v=rgb[k].xyz*(1-protect)+owned[k].xyz*protect;
 // Orthogonal final projection annihilates ALL reconstructed Laplacian levels
 // in a strong dynamic region. The static pyramid stays unchanged, preventing
 // a changed coarse weight from contaminating pixels outside the narrow mask.
 if(motion[k].w>.5 || rgb[k].w<=1e-8)v=reference[k].xyz;out[k]=ushort4(ushort3(clamp(rint(v),0.0f,65535.0f)),65535);
}
kernel void fsMotionFeatures(device const float4*ref [[buffer(0)]],device const float4*candidate [[buffer(1)]],device const float4*depth [[buffer(2)]],device float*features [[buffer(3)]],constant P&p [[buffer(5)]],uint2 q [[thread_position_in_grid]]){
 if(any(q>=uint2(256)))return;uint x=min(p.size.z-1,uint((q.x+.5)*p.size.z/256)),y=min(p.size.w-1,uint((q.y+.5)*p.size.w/256)),k=y*p.size.z+x,j=q.y*256+q.x;
 float r=dot(ref[k].xyz,float3(.299,.587,.114))/65535,c=dot(candidate[k].xyz,float3(.299,.587,.114))/65535;
 features[j]=r;features[65536+j]=c;features[2*65536+j]=abs(r-c);features[3*65536+j]=depth[k].x;
 // Bounded normalized edge feature; no transfer curve or RGB conversion.
 float l=dot(at(ref,int(x)-1,y,p.size.z,p.size.w).xyz,float3(.299,.587,.114)),rr=dot(at(ref,int(x)+1,y,p.size.z,p.size.w).xyz,float3(.299,.587,.114));
 float t=dot(at(ref,x,int(y)-1,p.size.z,p.size.w).xyz,float3(.299,.587,.114)),b=dot(at(ref,x,int(y)+1,p.size.z,p.size.w).xyz,float3(.299,.587,.114));
 features[4*65536+j]=length(float2(rr-l,b-t))*.5/65535;
}
kernel void fsMergeMotion(device const float*prob [[buffer(0)]],device float4*motion [[buffer(1)]],constant P&p [[buffer(5)]],uint2 q [[thread_position_in_grid]]){
 if(any(q>=p.size.xy))return;uint x=min(255u,q.x*256/p.size.x),y=min(255u,q.y*256/p.size.y);float m=0;
 // Conservative dilation makes one coherent reference owner across the moving
 // foreground boundary. Model probabilities affect ownership only, never RGB.
 for(int dy=-1;dy<=1;dy++)for(int dx=-1;dx<=1;dx++){uint j=clamp(int(y)+dy,0,255)*256+clamp(int(x)+dx,0,255);m=max(m,min(prob[j],1-prob[65536+j]));}
 uint k=q.y*p.size.x+q.x;motion[k].x=max(motion[k].x,m);
}
kernel void fsMotionOwnership(device const float4*motion [[buffer(0)]],device uint4*labels [[buffer(1)]],device float4*depth [[buffer(2)]],constant P&p [[buffer(5)]],uint2 q [[thread_position_in_grid]]){
 if(any(q>=p.size.xy))return;uint k=q.y*p.size.x+q.x;if(motion[k].x>=p.value.x){labels[k].w=0;depth[k].x=1;depth[k].w=1;}
}
