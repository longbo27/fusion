#include <metal_stdlib>
using namespace metal;
inline int reflect101(int p, int length) {
    if (length == 1) return 0;
    if (p < 0) return -p;
    if (p >= length) return 2*length-p-2;
    return p;
}
kernel void sobelFocus(const device float* l [[buffer(0)]], device float4* result [[buffer(1)]],
                       constant uint2& size [[buffer(2)]], uint2 p [[thread_position_in_grid]]) {
    if (p.x >= size.x || p.y >= size.y) return;
    int xl=reflect101(int(p.x)-1,size.x), xr=reflect101(int(p.x)+1,size.x);
    int yt=reflect101(int(p.y)-1,size.y), yb=reflect101(int(p.y)+1,size.y);
    float a=l[yt*size.x+xl], b=l[yt*size.x+p.x], c=l[yt*size.x+xr];
    float d=l[p.y*size.x+xl], f=l[p.y*size.x+xr];
    float g=l[yb*size.x+xl], h=l[yb*size.x+p.x], i=l[yb*size.x+xr];
    float gx=(c-a)+2.0f*(f-d)+(i-g), gy=(g-a)+2.0f*(h-b)+(i-c);
    result[p.y*size.x+p.x]=float4(gx,gy,gx*gx+gy*gy,0);
}
