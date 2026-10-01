import FocusStackCore
import XCTest
import Metal
import CoreML
import ImageIO
import UniformTypeIdentifiers

final class FoundationTests: XCTestCase {
    func testMetalDeviceInitialization() throws { XCTAssertFalse(try MetalContext().device.name.isEmpty) }
    func testCapabilities() throws {
        let m = try MetalContext().capabilities
        XCTAssertTrue(m.unifiedMemory); XCTAssertGreaterThan(m.recommendedWorkingSet,0)
        XCTAssertFalse(m.families.isEmpty)
        XCTAssertFalse(m.probeNotes.isEmpty)
    }
    func testPixelFormatMapping() { XCTAssertEqual(PixelFormat.rgba16Uint.metal,.rgba16Uint); XCTAssertEqual(PixelFormat.rgba16Uint.bytesPerPixel,8) }
    func testNoEightBitPhotoPath() { XCTAssertEqual(PixelFormat.rgba16Uint.bitsPerChannel,16) }
    func testInvalidTileDimensions() {
        for size in [0,-1,2049] { XCTAssertThrowsError(try TileDescriptor(width: size,height: 32)) }
    }
    func testTilePayloadValidation() throws { XCTAssertThrowsError(try RGB16Tile(descriptor: TileDescriptor(width: 2,height: 2),rgba: [0])) }
    func testGlobalTileCoordinates() throws {
        let full = try SyntheticTileProvider.make(TileDescriptor(width: 9,height: 7))
        let tile = try SyntheticTileProvider.make(TileDescriptor(x: 3,y: 2,width: 1,height: 1))
        XCTAssertEqual(Array(full.rgba[((2*9+3)*4)..<((2*9+3)*4+4)]),tile.rgba)
    }
    func testRGBChannelOrder() async throws {
        let d = try TileDescriptor(width: 3,height: 1)
        let tile = try RGB16Tile(descriptor: d,rgba: [65535,0,0,65535,0,65535,0,65535,0,0,65535,65535])
        let gpu = try await GPUTilePipeline().run(tile)
        for (i,e) in [Float(0.299),0.587,0.114].enumerated() { XCTAssertEqual(gpu.luminance[i],e,accuracy: 2e-6) }
    }
    func testUInt16AllValuesPreserved() async throws {
        let d = try TileDescriptor(width: 256,height: 256)
        var values = [UInt16](repeating: 65535,count: d.pixelCount*4)
        for i in 0..<d.pixelCount { values[i*4] = UInt16(i); values[i*4+1] = UInt16(65535-i); values[i*4+2] = UInt16(i) }
        let gpu = try await GPUTilePipeline().run(RGB16Tile(descriptor: d,rgba: values))
        XCTAssertEqual(gpu.copied,values)
    }
    func compare(width: Int,height: Int) async throws -> GPUResult {
        let tile = try SyntheticTileProvider.make(TileDescriptor(width: width,height: height))
        let result = try await GPUTilePipeline().run(tile)
        XCTAssertLessThanOrEqual(result.report.luminanceMaxError,CPUReference.luminanceTolerance)
        XCTAssertLessThanOrEqual(result.report.gradientMaxError,CPUReference.gradientTolerance)
        XCTAssertLessThanOrEqual(result.report.energyMaxError,CPUReference.energyTolerance)
        return result
    }
    func testLuminanceGPUvsCPU() async throws { _ = try await compare(width: 32,height: 32) }
    func testSobelGPUvsCPU() async throws { _ = try await compare(width: 65,height: 49) }
    func testTenengradGPUvsCPU() async throws { let r = try await compare(width: 127,height: 81); XCTAssertGreaterThan(r.report.checksum,0) }
    func testOddDimensions() async throws { _ = try await compare(width: 17,height: 13) }
    func testSinglePixelReflectBorder() async throws { let r = try await compare(width: 1,height: 1); XCTAssertEqual(r.gradients[0],.zero) }
    func testResourceReuse() async throws {
        let engine = try GPUTilePipeline(), tile = try SyntheticTileProvider.make(TileDescriptor(width: 32,height: 32))
        _ = try await engine.run(tile); _ = try await engine.run(tile)
        let stats = await engine.diagnostics(); XCTAssertEqual(stats.allocations,1); XCTAssertEqual(stats.highWater,1)
    }
    func testBoundedInFlightAndBackpressure() throws {
        let context = try MetalContext(), pool = try BufferPool(capacity: 1), d = try TileDescriptor(width: 32,height: 32)
        let r = try pool.acquire(device: context.device,descriptor: d)
        XCTAssertThrowsError(try pool.acquire(device: context.device,descriptor: d))
        pool.release(r); XCTAssertEqual(pool.inFlight,0); XCTAssertEqual(pool.highWater,1)
        XCTAssertThrowsError(try BufferPool(capacity: 3))
    }
    func testChangingDimensionsDoesNotAccumulatePool() async throws {
        let pipeline = try GPUTilePipeline()
        for size in [32,64,32] { _ = try await pipeline.run(SyntheticTileProvider.make(TileDescriptor(width: size,height: size))) }
        let stats = await pipeline.diagnostics(); XCTAssertEqual(stats.allocations,3); XCTAssertEqual(stats.highWater,1)
    }
    func testCapabilityFallback() {
        for state in [(false,false,false),(true,false,false),(true,true,false),(true,true,true)] {
            XCTAssertTrue(MetalCapabilities.choosePath(metal4: state.0,tensor: state.1,encoder: state.2,modelLoaded: false).contains("Standard Metal"))
        }
    }
    func testCoreMLDeviceEnumeration() {
        let info = MLHardwareInspector(); XCTAssertFalse(info.devices.isEmpty)
        if #available(macOS 14.0, *) { XCTAssertEqual(info.devices.count,MLComputeDevice.allComputeDevices.count) }
    }
    func testNoModelLoaded() async { let status = await CoreMLRunner().status(); XCTAssertEqual(status,"No production model loaded.") }
    func testMemoryMonitor() { let memory = MemoryMonitor.snapshot(); XCTAssertGreaterThan(memory.residentBytes,0); XCTAssertGreaterThan(memory.lifetimePeakBytes,0) }
    func testPythonGoldenFixture() async throws {
        struct Fixture: Decodable { let width: Int, height: Int; let rgb: [UInt16]; let luminance: [Float], gx: [Float], gy: [Float], energy: [Float] }
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "golden",withExtension: "json"))
        let f = try JSONDecoder().decode(Fixture.self,from: Data(contentsOf: url))
        let d = try TileDescriptor(width: f.width,height: f.height)
        var rgba = [UInt16](repeating: 65535,count: d.pixelCount*4)
        for i in 0..<d.pixelCount { for c in 0..<3 { rgba[i*4+c] = f.rgb[i*3+c] } }
        let r = try await GPUTilePipeline().run(RGB16Tile(descriptor: d,rgba: rgba))
        for i in 0..<d.pixelCount {
            XCTAssertEqual(r.luminance[i],f.luminance[i],accuracy: CPUReference.luminanceTolerance)
            XCTAssertEqual(r.gradients[i].x,f.gx[i],accuracy: CPUReference.gradientTolerance)
            XCTAssertEqual(r.gradients[i].y,f.gy[i],accuracy: CPUReference.gradientTolerance)
            XCTAssertEqual(r.gradients[i].z,f.energy[i],accuracy: CPUReference.energyTolerance)
        }
    }
    func withTIFF(_ body: (URL,[UInt16]) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("tiff")
        defer { try? FileManager.default.removeItem(at: url) }
        let tile = try SyntheticTileProvider.make(TileDescriptor(width: 7,height: 5))
        let data = tile.rgba.withUnsafeBytes { Data($0) }
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)) // explicit test profile only
        let provider = try XCTUnwrap(CGDataProvider(data: data as CFData))
        let image = try XCTUnwrap(CGImage(width: 7,height: 5,bitsPerComponent: 16,bitsPerPixel: 64,bytesPerRow: 56,
            space: space,bitmapInfo: [.byteOrder16Little,CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)],provider: provider,
            decode: nil,shouldInterpolate: false,intent: .defaultIntent))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL,UTType.tiff.identifier as CFString,1,nil))
        CGImageDestinationAddImage(destination,image,[kCGImagePropertyDPIWidth: 300,kCGImagePropertyDPIHeight: 300] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination)); try body(url,tile.rgba)
    }
    func testTIFFMetadataParsing() throws {
        try withTIFF { url,_ in let m = try TIFFInspector.inspect(url); XCTAssertEqual(m.width,7); XCTAssertEqual(m.height,5); XCTAssertEqual(m.bitsPerSample,16); XCTAssertEqual(m.channels,3); XCTAssertEqual(m.dpiX,300) }
    }
    func testICCMetadataDiscovery() throws {
        try withTIFF { url,_ in let m = try TIFFInspector.inspect(url); XCTAssertNotNil(m.color.profile.imageIOICCRepresentation); XCTAssertNotNil(m.color.profile.name) }
    }
    func testImageIOTilePrecision() throws {
        try withTIFF { url,rgba in let t = try ImageIOTileProvider(url: url).readSync(TileDescriptor(width: 7,height: 5)); XCTAssertEqual(t.rgba,rgba) }
    }
    func testDecodeBudgetGate() throws {
        try withTIFF { url,_ in XCTAssertThrowsError(try ImageIOTileProvider(url: url,maximumDecodedBytes: 1).readSync(TileDescriptor(width: 1,height: 1))) }
    }
    func testMalformedTIFFRejected() { XCTAssertThrowsError(try TIFFInspector.inspect(URL(fileURLWithPath: "/nonexistent.tiff"))) }
    func testVisionOpticalFlow() throws {
        let r = try MotionAnalyzer.analyze(first: MotionAnalyzer.fixture(),second: MotionAnalyzer.fixture(shift: 1))
        XCTAssertEqual(r.width,128); XCTAssertEqual(r.height,128)
        XCTAssertEqual(r.pixelFormat,kCVPixelFormatType_TwoComponent32Float); XCTAssertGreaterThan(r.outputBytes,0)
    }
    func testExactSourceICCBytesRetained() throws {
        try withTIFF { url,_ in
            let source = try XCTUnwrap(TIFFProfileReader.readICC(url))
            let metadata = try TIFFInspector.inspect(url)
            XCTAssertEqual(metadata.color.profile.exactSourceICC,source)
            XCTAssertTrue(metadata.color.embeddedProfileEvidence.contains("present"))
        }
    }
    func testClassicAndBigTIFFICCByteOrder() throws {
        for big in [false,true] { for little in [false,true] {
            var bytes = Data()
            func add(_ value: UInt64,_ count: Int) {
                for i in 0..<count { let shift = (little ? i : count-i-1)*8; bytes.append(UInt8(truncatingIfNeeded: value >> shift)) }
            }
            bytes.append(contentsOf: little ? [73,73] : [77,77]); add(big ? 43 : 42,2)
            if big { add(8,2); add(0,2); add(16,8) } else { add(8,4) }
            add(1,big ? 8 : 2); add(34675,2); add(7,2); add(128,big ? 8 : 4)
            add(big ? 52 : 26,big ? 8 : 4); add(0,big ? 8 : 4)
            let profile = Data((0..<128).map { UInt8($0) }); bytes.append(profile)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: url) }
            try bytes.write(to: url); XCTAssertEqual(try TIFFProfileReader.readICC(url),profile)
        }}
    }
    func testMalformedICCOffsetRejected() throws {
        // Little-endian classic IFD, ICC length 128, invalid offset beyond EOF.
        let bytes = Data([73,73,42,0,8,0,0,0,1,0,115,135,7,0,128,0,0,0,255,255,255,255,0,0,0,0])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try bytes.write(to: url); XCTAssertThrowsError(try TIFFProfileReader.readICC(url))
    }

    func testMobileMemoryEnvelopeAndTileLimit() throws {
        let policy = TileMemoryPolicy(platform: .mobile,physicalBytes: 4*1073741824,
            recommendedGPUBytes: 2*1073741824,residentBytes: 256*1048576)
        XCTAssertEqual(policy.maximumInFlightTiles,1); XCTAssertEqual(policy.preferredTileEdge,512)
        try policy.validate(edge: 512,inFlight: 1)
        XCTAssertThrowsError(try policy.validate(edge: 1024,inFlight: 1))
        XCTAssertThrowsError(try policy.validate(edge: 512,inFlight: 2))
    }
    func testMemoryPressureRejectsTiles() {
        let policy = TileMemoryPolicy(platform: .mobile,physicalBytes: 2*1073741824,
            recommendedGPUBytes: 1073741824,residentBytes: 2*1073741824)
        XCTAssertEqual(policy.availableBudgetBytes,0); XCTAssertEqual(policy.preferredTileEdge,0)
        XCTAssertThrowsError(try policy.validate(edge: 128,inFlight: 1))
    }

    func testSchedulerBackpressureBeforeDecode() async throws {
        struct WaitingProvider: TileProvider {
            func read(_ descriptor: TileDescriptor) async throws -> RGB16Tile {
                try await Task.sleep(for: .milliseconds(50))
                return try SyntheticTileProvider.make(descriptor)
            }
        }
        let scheduler = try TileScheduler(), descriptor = try TileDescriptor(width: 32,height: 32)
        let accepted = await withTaskGroup(of: Bool.self,returning: Int.self) { group in
            for _ in 0..<2 { group.addTask {
                do { _ = try await scheduler.processPrototype(provider: WaitingProvider(),descriptor: descriptor); return true }
                catch { return false }
            }}
            var count = 0
            for await success in group { if success { count += 1 } }
            return count
        }
        XCTAssertEqual(accepted,1)
    }

    func testSchedulerValidatesMobileBudgetBeforeDecode() async throws {
        actor RecordingProvider: TileProvider {
            private(set) var calls = 0
            func read(_ descriptor: TileDescriptor) async throws -> RGB16Tile {
                calls += 1; return try SyntheticTileProvider.make(descriptor)
            }
        }
        let scheduler = try TileScheduler(memoryClass: .mobile), provider = RecordingProvider()
        do {
            _ = try await scheduler.processPrototype(provider: provider,descriptor: TileDescriptor(width: 1024,height: 1024))
            XCTFail("Mobile oversized tile must be rejected")
        } catch {}
        let calls = await provider.calls; XCTAssertEqual(calls,0)
    }

}
