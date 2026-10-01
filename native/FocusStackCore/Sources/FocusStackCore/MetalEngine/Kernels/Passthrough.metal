#include <metal_stdlib>
using namespace metal;
kernel void copy16(texture2d<uint, access::read> source [[texture(0)]],
                   texture2d<uint, access::write> destination [[texture(1)]], uint2 p [[thread_position_in_grid]]) {
    if (p.x >= source.get_width() || p.y >= source.get_height()) return;
    destination.write(source.read(p), p);
}
