import FocusStackCore
import Foundation
import Metal
import CryptoKit

@main struct BenchmarkMain {
    static func printJSON<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        print(String(decoding: try encoder.encode(value),as: UTF8.self))
    }
    static func main() async {
        do {
            let args = CommandLine.arguments
            if args.count > 2, args[1] == "--metadata" {
                let before = MemoryMonitor.snapshot()
                let metadata = try TIFFInspector.inspect(URL(fileURLWithPath: args[2]))
                print(metadata.summary); try printJSON(before); try printJSON(MemoryMonitor.snapshot()); return
            }
            if args.count > 2, args[1] == "--imageio-probe" {
                // Explicit developer experiment in its own process. Full decode permitted
                // solely to MEASURE behavior; not used by UI/production TileProvider.
                let before = MemoryMonitor.snapshot(), url = URL(fileURLWithPath: args[2])
                let metadata = try TIFFInspector.inspect(url)
                print(metadata.summary); print("Before metadata:"); try printJSON(before)
                print("After metadata:"); try printJSON(MemoryMonitor.snapshot())
                let tile = try ImageIOTileProvider(url: url,maximumDecodedBytes: metadata.estimatedDecodedBytes)
                    .readSync(TileDescriptor(width: 1024,height: 1024))
                print("After ImageIO crop/read:"); try printJSON(MemoryMonitor.snapshot())
                let digest = tile.rgba.withUnsafeBytes { SHA256.hash(data: Data($0)) }.map { String(format: "%02x",$0) }.joined()
                print("Source RGBA16 SHA256: \(digest)")
                let pipeline = try GPUTilePipeline()
                let result = try await pipeline.run(tile); try printJSON(result.report); return
            }
            if args.contains("--vision") {
                let report = try MotionAnalyzer.analyze(first: MotionAnalyzer.fixture(),second: MotionAnalyzer.fixture(shift: 1))
                try printJSON(report); return
            }
            if args.contains("--scaling") {
                guard let count = Int(args.last ?? ""), [3,10,20].contains(count) else { throw NativeError.invalid("Use --scaling 3|10|20") }
                let pipeline = try GPUTilePipeline()
                for index in 0..<count {
                    let tile = try SyntheticTileProvider.make(TileDescriptor(x: index*512,width: 512,height: 512))
                    _ = try await pipeline.run(tile)
                }
                let stats = await pipeline.diagnostics()
                print("Sequential logical sources: \(count), allocations: \(stats.allocations), in-flight peak: \(stats.highWater)")
                try printJSON(MemoryMonitor.snapshot()); return
            }
            print(HardwareReport.collect().text)
            let context = try MetalContext(), cache = try PipelineCache(device: context.device)
            print("Luminance thread width: \(cache.luminance.threadExecutionWidth); pipeline max threads: \(cache.luminance.maxTotalThreadsPerThreadgroup)")
            let pipeline = try GPUTilePipeline()
            for size in [1024,2048] {
                let tile = try SyntheticTileProvider.make(TileDescriptor(width: size,height: size))
                _ = try await pipeline.run(tile) // warmup, excludes library/resource setup
                for _ in 0..<3 { let result = try await pipeline.run(tile); try printJSON(result.report) }
            }
        } catch { FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8)); exit(1) }
    }
}
