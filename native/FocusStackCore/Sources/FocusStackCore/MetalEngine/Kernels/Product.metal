// Independent implementation from FocusStack's existing source evidence.
// Optional product path: masks/QA do not alter automatic fusion.
kernel void fsProductExclude(device float4*score [[buffer(0)]],device const uint2*manual [[buffer(1)]],constant P&p [[buffer(5)]],uint2 q [[thread_position_in_grid]]){
 if(any(q>=p.size.xy))return;uint k=q.y*p.size.x+q.x;
 if(manual[k].x==4 && manual[k].y==uint(p.value.x))score[k].x=-1;
}
kernel void fsProductCapture(device const float4*source [[buffer(0)]],device const uint2*manual [[buffer(1)]],device const uint4*indices [[buffer(2)]],device float4*rgb [[buffer(3)]],constant P&p [[buffer(5)]],uint2 q [[thread_position_in_grid]]){
 if(any(q>=p.size.xy))return;uint k=q.y*p.size.x+q.x;uint2 m=manual[k];uint owner=(m.x==1||m.x==4) ? indices[k].x:(m.x==2 ? 0:m.y);
 if(m.x==4 && owner==m.y)return;
 if(m.x>0 && owner==uint(p.value.x))rgb[k]=source[k];
}
kernel void fsProductProject(device ushort4*output [[buffer(0)]],device const uint2*manual [[buffer(1)]],device const float4*rgb [[buffer(2)]],constant P&p [[buffer(5)]],uint2 q [[thread_position_in_grid]]){
 if(any(q>=p.size.xy))return;uint k=q.y*p.size.x+q.x;
 if(manual[k].x>0 && rgb[k].w>.5)output[k]=ushort4(ushort3(clamp(rint(rgb[k].xyz),0.0f,65535.0f)),65535);
}
inline uint productQ(float v){return uint(round(clamp(v,0.0f,1.0f)*255));}
kernel void fsProductEvidence(device const uint4*indices [[buffer(0)]],device const uint4*labels [[buffer(1)]],device const float4*depth [[buffer(2)]],device const float4*motion [[buffer(3)]],device const float4*top [[buffer(4)]],constant P&p [[buffer(5)]],device const float4*recon [[buffer(6)]],device const float4*temporal [[buffer(7)]],device const ushort4*output [[buffer(8)]],device const uint2*manual [[buffer(9)]],device const float4*manualRGB [[buffer(10)]],device uint4*evidence [[buffer(11)]],uint2 q [[thread_position_in_grid]]){
 if(any(q>=p.size.xy))return;uint k=q.y*p.size.x+q.x;float4 d=depth[k],m=motion[k];uint2 edit=manual[k];
 uint owner=labels[k].w,mode=2; // multi-source-capable blend; never invented scalar weights
 if(p.value.x>0 && d.w>=1){mode=1;}
 if(recon[k].w<=1e-8){owner=0;mode=3;}
 if(m.w>.5){owner=0;mode=4;}
 if(edit.x>0 && manualRGB[k].w>.5){owner=(edit.x==1||edit.x==4)?indices[k].x:(edit.x==2?0:edit.y);mode=5;}
 float energy=max(top[k].x,0.0f)/(65535.0f*65535.0f);
 // Uncalibrated absolute focus-evidence index, not a physical probability.
 float coverage=energy/(energy+0.00002f),focus=clamp(d.x,0.0f,1.0f);
 float mo=p.value.z>0?m.x:0,mu=p.value.z>0?1-abs(2*mo-1):1;
 uint qa=0;float l=dot(float3(output[k].xyz),float3(.299,.587,.114))/65535;
 if(coverage<.2)qa|=1; // focus gap / insufficient evidence
 if(focus<.1)qa|=2; // ownership ambiguity
 if(p.value.y>=0 && p.value.y<.7)qa|=4; // registration review
 if(mo>.65 && m.w<.5)qa|=8; // motion leakage candidate
 if(l>temporal[k].w+.02)qa|=16;if(l<temporal[k].z-.02)qa|=32; // halo candidates
 if(any(output[k].xyz==ushort3(0))||any(output[k].xyz==ushort3(65535)))qa|=64;
 uint status=(edit.x>0?1u:0u)|(p.value.y<0?2u:0u)|(p.value.z>0?4u:0u);
 evidence[k]=uint4(owner|(indices[k].y<<16),indices[k].x|(mode<<16)|(status<<24),productQ(focus)|(productQ(mo)<<8)|(productQ(max(p.value.y,0.0f))<<16)|(productQ(coverage)<<24),productQ(mu)|(indices[k].z<<8)|(qa<<24));
}
kernel void fsProductPreview(device const float4*source [[buffer(0)]],device ushort4*output [[buffer(1)]],constant P&p [[buffer(5)]],uint2 q [[thread_position_in_grid]]){if(any(q>=p.size.xy))return;uint k=q.y*p.size.x+q.x;output[k]=ushort4(ushort3(clamp(rint(source[k].xyz),0.0f,65535.0f)),65535);}
kernel void fsProductRespectExclusion(device float4*motion [[buffer(0)]],device const uint2*manual [[buffer(1)]],constant P&p [[buffer(5)]],uint2 q [[thread_position_in_grid]]){if(any(q>=p.size.xy))return;uint k=q.y*p.size.x+q.x;if(manual[k].x==4 && manual[k].y==0)motion[k].w=0;}
