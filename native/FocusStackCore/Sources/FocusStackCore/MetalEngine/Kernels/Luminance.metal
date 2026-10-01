#include <metal_stdlib>
using namespace metal;
// Python V1.1 cvtColor RGB2GRAY coefficients, encoded RGB, normalized explicitly.
// uint texture avoids UNORM implementations reducing intermediate precision.
kernel void luminance16(texture2d<uint, access::read> source [[texture(0)]],
                        device float* luminance [[buffer(0)]], uint2 p [[thread_position_in_grid]]) {
    if (p.x >= source.get_width() || p.y >= source.get_height()) return;
    float3 rgb = float3(source.read(p).rgb) / 65535.0f;
    luminance[p.y*source.get_width()+p.x] = rgb.r*0.299f + rgb.g*0.587f + rgb.b*0.114f;
}
