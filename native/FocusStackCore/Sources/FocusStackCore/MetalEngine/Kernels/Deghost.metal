// Compiled together with Production.metal; shared P, at(), gradients() helpers.
// Fixed candidate statistics and native-scale 256² windows: no full-stack input.
kernel void fsCandidateFeatures(device const float4*ref [[buffer(0)]],device const float4*luma [[buffer(1)]],device const float4*depth [[buffer(2)]],device float*features [[buffer(3)]],device const float4*temporal [[buffer(4)]],constant P&p [[buffer(5)]],device const uint4*labels [[buffer(6)]],uint2 q [[thread_position_in_grid]]){
 if(any(q>=uint2(256)))return;
 int x=int(p.value.x)+int(q.x)-24,y=int(p.value.y)+int(q.y)-24;
 uint k=ref101(y,p.size.w)*p.size.z+ref101(x,p.size.z),j=q.y*256+q.x;
 float r=dot(ref[k].xyz,float3(.299,.587,.114))/65535;float4 c=luma[k],t=temporal[k];
 float mean=0,meanSquare=0,bestMean=0,disagreement=0;
 for(int dy=-1;dy<=1;dy++)for(int dx=-1;dx<=1;dx++){
  uint n=ref101(y+dy,p.size.w)*p.size.z+ref101(x+dx,p.size.z);float a=dot(ref[n].xyz,float3(.299,.587,.114))/65535;mean+=a/9;meanSquare+=a*a/9;bestMean+=luma[n].x/9;
 }
 int2 offsets[4]={int2(-1,0),int2(1,0),int2(0,-1),int2(0,1)};
 for(int i=0;i<4;i++){uint n=ref101(y+offsets[i].y,p.size.w)*p.size.z+ref101(x+offsets[i].x,p.size.z);disagreement+=labels[k].x!=labels[n].x?.25:0;}
 float gx=(dot(at(ref,x+1,y,p.size.z,p.size.w).xyz,float3(.299,.587,.114))-dot(at(ref,x-1,y,p.size.z,p.size.w).xyz,float3(.299,.587,.114)))*.5/65535;
 float gy=(dot(at(ref,x,y+1,p.size.z,p.size.w).xyz,float3(.299,.587,.114))-dot(at(ref,x,y-1,p.size.z,p.size.w).xyz,float3(.299,.587,.114)))*.5/65535;
 features[j]=r;features[65536+j]=c.x;features[2*65536+j]=c.y;features[3*65536+j]=c.z;
 features[4*65536+j]=abs(r-c.x);features[5*65536+j]=abs(r-c.y);
 features[6*65536+j]=clamp(abs(mean-bestMean)/(sqrt(max(meanSquare-mean*mean,0.0f))+.03)/4,0.0f,1.0f);
 features[7*65536+j]=depth[k].x;features[8*65536+j]=length(float2(gx,gy));features[9*65536+j]=disagreement;
 features[10*65536+j]=sqrt(max(t.y/p.value.z,0.0f));features[11*65536+j]=t.w-t.z;
}
kernel void fsScatterMotion(device const float*prob [[buffer(0)]],device float4*motion [[buffer(1)]],constant P&p [[buffer(5)]],uint2 q [[thread_position_in_grid]]){
 if(any(q<uint2(24))||any(q>=uint2(232)))return;
 uint x=uint(p.value.x)+q.x-24,y=uint(p.value.y)+q.y-24;if(x>=p.size.z||y>=p.size.w)return;uint j=q.y*256+q.x;
 motion[y*p.size.z+x]=float4(prob[j],prob[65536+j],prob[2*65536+j],0);
}
inline bool motionGate(float4 v,float threshold){return v.x>=threshold && v.y<=1-threshold && v.z>=(threshold>.8?.75:.65);}
kernel void fsRegularizeMotion(device const float4*a [[buffer(0)]],device float4*b [[buffer(1)]],constant P&p [[buffer(5)]],uint2 q [[thread_position_in_grid]]){
 if(any(q>=p.size.xy))return;uint k=q.y*p.size.x+q.x;float4 v=a[k];int neighbors=0;float peak=v.x;
 for(int dy=-1;dy<=1;dy++)for(int dx=-1;dx<=1;dx++){float4 other=at(a,int(q.x)+dx,int(q.y)+dy,p.size.x,p.size.y);if(motionGate(other,p.value.x))neighbors++;peak=max(peak,other.x);}
 // Preserve confident thin center pixels; otherwise require neighborhood support.
 bool strong=motionGate(v,p.value.x)&&(neighbors>=2 || v.x>.995);v.w=strong?1:0;b[k]=v;
}
kernel void fsMotionDilate(device const float4*a [[buffer(0)]],device float4*b [[buffer(1)]],constant P&p [[buffer(5)]],uint2 q [[thread_position_in_grid]]){
 if(any(q>=p.size.xy))return;uint k=q.y*p.size.x+q.x;float4 v=a[k];
 // One native pixel protects the selected boundary; never a scaled 1024/256 dilation.
 for(int dy=-1;dy<=1;dy++)for(int dx=-1;dx<=1;dx++)v.w=max(v.w,at(a,int(q.x)+dx,int(q.y)+dy,p.size.x,p.size.y).w);
 b[k]=v;
}
kernel void fsComponentInit(device const float4*motion [[buffer(0)]],device atomic_uint*parents [[buffer(1)]],constant P&p [[buffer(5)]],uint2 q [[thread_position_in_grid]]){
 if(any(q>=p.size.xy))return;uint k=q.y*p.size.x+q.x;atomic_store_explicit(&parents[k],motion[k].w>.5?k:UINT_MAX,memory_order_relaxed);
}
inline uint componentRoot(device atomic_uint*parents,uint k){for(int i=0;i<32;i++){uint n=atomic_load_explicit(&parents[k],memory_order_relaxed);if(n==k||n==UINT_MAX)return n;k=n;}return k;}
kernel void fsComponentUnion(device atomic_uint*parents [[buffer(0)]],constant P&p [[buffer(5)]],uint2 q [[thread_position_in_grid]]){
 if(any(q>=p.size.xy))return;uint k=q.y*p.size.x+q.x;if(atomic_load_explicit(&parents[k],memory_order_relaxed)==UINT_MAX)return;
 uint neighbors[2]={q.x? k-1:UINT_MAX,q.y?k-p.size.x:UINT_MAX};
 for(int n=0;n<2;n++){uint other=neighbors[n];if(other==UINT_MAX||atomic_load_explicit(&parents[other],memory_order_relaxed)==UINT_MAX)continue;
  for(int i=0;i<32;i++){uint a=componentRoot(parents,k),b=componentRoot(parents,other);if(a==b)break;uint hi=max(a,b),lo=min(a,b),expected=hi;if(atomic_compare_exchange_weak_explicit(&parents[hi],&expected,lo,memory_order_relaxed,memory_order_relaxed))break;}
 }
}
kernel void fsComponentCompress(device atomic_uint*parents [[buffer(0)]],constant P&p [[buffer(5)]],uint2 q [[thread_position_in_grid]]){
 if(any(q>=p.size.xy))return;uint k=q.y*p.size.x+q.x;if(atomic_load_explicit(&parents[k],memory_order_relaxed)!=UINT_MAX)atomic_store_explicit(&parents[k],componentRoot(parents,k),memory_order_relaxed);
}
kernel void fsCoherentOwnership(device const float4*motion [[buffer(0)]],device const atomic_uint*parents [[buffer(1)]],device uint4*labels [[buffer(2)]],device float4*depth [[buffer(3)]],constant P&p [[buffer(5)]],uint2 q [[thread_position_in_grid]]){
 if(any(q>=p.size.xy))return;uint k=q.y*p.size.x+q.x;
 if(motion[k].w>.5&&atomic_load_explicit(&parents[k],memory_order_relaxed)!=UINT_MAX){labels[k].w=0;}
 // Components consistently select the captured reference. Candidate logits are
 // diagnostics until an independently validated component-source advantage exists.
}
