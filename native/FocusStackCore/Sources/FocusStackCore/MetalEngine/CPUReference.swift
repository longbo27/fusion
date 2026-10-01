import Foundation

// Independent scalar correctness baseline, not the production CPU backend.
public enum CPUReference {
    public static func run(_ tile: RGB16Tile) -> (luminance: [Float], gradients: [SIMD4<Float>]) {
        let d = tile.descriptor, w = d.width, h = d.height
        var l = [Float](repeating: 0, count: d.pixelCount)
        for i in 0..<d.pixelCount {
            l[i] = Float(tile.rgba[i*4])/65535*0.299 + Float(tile.rgba[i*4+1])/65535*0.587 + Float(tile.rgba[i*4+2])/65535*0.114
        }
        func reflect(_ p: Int, _ n: Int) -> Int { n == 1 ? 0 : (p < 0 ? -p : (p >= n ? 2*n-p-2 : p)) }
        var g = [SIMD4<Float>](repeating: .zero, count: d.pixelCount)
        for y in 0..<h { for x in 0..<w {
            let xl = reflect(x-1,w), xr = reflect(x+1,w), yt = reflect(y-1,h), yb = reflect(y+1,h)
            let a=l[yt*w+xl], b=l[yt*w+x], c=l[yt*w+xr], dd=l[y*w+xl], f=l[y*w+xr]
            let gg=l[yb*w+xl], hh=l[yb*w+x], ii=l[yb*w+xr]
            let gx=(c-a)+2*(f-dd)+(ii-gg), gy=(gg-a)+2*(hh-b)+(ii-c)
            g[y*w+x] = SIMD4(gx,gy,gx*gx+gy*gy,0)
        }}
        return (l,g)
    }
    public static let luminanceTolerance: Float = 2e-6
    public static let gradientTolerance: Float = 2e-5
    public static let energyTolerance: Float = 2e-4
}
