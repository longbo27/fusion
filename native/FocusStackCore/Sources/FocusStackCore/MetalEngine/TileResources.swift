import Metal

public final class TileResources {
    public let descriptor: TileDescriptor
    public let source: any MTLTexture
    public let copied: any MTLTexture
    public let luminance: any MTLBuffer
    public let gradients: any MTLBuffer
    public init(device: any MTLDevice, descriptor d: TileDescriptor) throws {
        func texture() throws -> any MTLTexture {
            let t = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: PixelFormat.rgba16Uint.metal,
                width: d.width, height: d.height, mipmapped: false)
            t.storageMode = .shared; t.usage = [.shaderRead, .shaderWrite]
            guard let result = device.makeTexture(descriptor: t) else { throw NativeError.resource("Texture allocation failed") }
            return result
        }
        source = try texture(); copied = try texture()
        guard let l = device.makeBuffer(length: d.pixelCount*4, options: .storageModeShared),
              let g = device.makeBuffer(length: d.pixelCount*16, options: .storageModeShared) else {
            throw NativeError.resource("Tile buffer allocation failed")
        }
        luminance = l; gradients = g; descriptor = d
    }
}
