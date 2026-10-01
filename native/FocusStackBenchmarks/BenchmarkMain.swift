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
            if args.contains("--production-timing") {
                let engine=try ProductionMetalPipeline(detailedTiming:true),d=try TileDescriptor(width:1024,height:1024),tile=try ProductionTile(core:d,imageWidth:1024,imageHeight:1024,quality:.maximum)
                try engine.begin(region:d,quality:.maximum)
                for i in 0..<3{try engine.focus(tile:SyntheticTileProvider.make(d),region:d,sourceWidth:1024,sourceHeight:1024,index:i)};try engine.depth()
                for i in 0..<3{try engine.fuse(tile:SyntheticTileProvider.make(d),region:d,sourceWidth:1024,sourceHeight:1024,index:i)};_ = try engine.finish(tile:tile)
                try printJSON(engine.kernelTiming);try printJSON(engine.timing);try printJSON(MemoryMonitor.snapshot());return
            }
            if args.count>2,args[1]=="--metal-ml" {
                guard #available(macOS 26,iOS 26,*)else{throw NativeError.unavailable("Metal ML requires OS26")}
                let dir=URL(fileURLWithPath:args[2]),input=try Data(contentsOf:dir.appendingPathComponent("inference-input.f32")).withUnsafeBytes{Array($0.bindMemory(to:Float.self))},expected=try Data(contentsOf:dir.appendingPathComponent("torch-output.f32")).withUnsafeBytes{Array($0.bindMemory(to:Float.self))}
                try printJSON(MetalMLPrototype.run(package:dir.appendingPathComponent("FocusMotionNetProto.mtlpackage"),features:input,expected:expected));return
            }
            if args.count>3,["--stack","--stack-identity","--stack-ai"].contains(args[1]) {
                let output=URL(fileURLWithPath:args[2]),inputs=args.dropFirst(3).map{URL(fileURLWithPath:$0)}
                let report=try await NativeStackEngine().run(inputs:inputs,output:output,suppliedTransforms:args[1]=="--stack-identity" ? inputs.map{_ in SimilarityTransform()}:nil,aiMode:args[1]=="--stack-ai" ? .auto:.off) { message,fraction in print(String(format:"%.1f%% %@",fraction*100,message));fflush(stdout) }
                try printJSON(report);return
            }
            if args.count>3,args[1]=="--align" {
                let first=LibTIFFTileProvider(url:URL(fileURLWithPath:args[2])),metadata=try first.metadata(),ref=try ReducedImage.read(first)
                for path in args.dropFirst(3){let candidate=try ReducedImage.read(LibTIFFTileProvider(url:URL(fileURLWithPath:path)));try printJSON(NativeAlignment.align(reference:ref,candidate:candidate,fullWidth:metadata.width,fullHeight:metadata.height))};try printJSON(MemoryMonitor.snapshot());return
            }
            if args.count>2,args[1]=="--ml-prototype" {
                let dir=URL(fileURLWithPath:args[2]),compiled=dir.appendingPathComponent("FocusMotionNetProto.mlmodelc")
                let input=try Data(contentsOf:dir.appendingPathComponent("inference-input.f32")).withUnsafeBytes{Array($0.bindMemory(to:Float.self))},expected=try Data(contentsOf:dir.appendingPathComponent("torch-output.f32")).withUnsafeBytes{Array($0.bindMemory(to:Float.self))}
                for units in PrototypeComputeUnits.allCases{let runner=MotionPrototypeRunner();try await runner.load(url:compiled,units:units);let result=try await runner.predict(features:input,iterations:20,torchExpected:expected);try printJSON(result.report)}
                for operation in try await ComputePlanInspector().inspect(compiledModelURL:compiled){print("\(operation.operation): preferred \(operation.preferred), supported \(operation.supported), cost \(operation.estimatedCostWeight.map(String.init(describing:)) ?? "unavailable")")};return
            }
            if args.count>2,args[1]=="--production-parity" {
                let root=URL(fileURLWithPath:args[2]),manifest=try JSONSerialization.jsonObject(with:Data(contentsOf:root.appendingPathComponent("manifest.json"))) as! [[String:Any]]
                func load<T>(_ url:URL,_ type:T.Type)throws->[T]{try Data(contentsOf:url).withUnsafeBytes{Array($0.bindMemory(to:T.self))}}
                let engine=try ProductionMetalPipeline()
                for entry in manifest {
                    let name=entry["name"] as! String,w=entry["width"] as! Int,h=entry["height"] as! Int,dir=root.appendingPathComponent(name)
                    let quality=StackQuality(rawValue:entry["quality"] as? String ?? "") ?? .maximum
                    let transforms=(entry["transforms"] as? [[String:Double]])?.map{SimilarityTransform(a:$0["a"]!,b:$0["b"]!,tx:$0["tx"]!,ty:$0["ty"]!)} ?? (0..<3).map{_ in SimilarityTransform()}
                    let d=try TileDescriptor(width:w,height:h),tile=try ProductionTile(core:d,imageWidth:w,imageHeight:h,quality:quality)
                    try engine.begin(region:d,quality:quality);var scores=[Double]()
                    for i in 0..<3 {
                        let input=try RGB16Tile(descriptor:d,rgba:load(dir.appendingPathComponent("source\(i).u16"),UInt16.self))
                        try engine.focus(tile:input,region:d,transform:transforms[i],sourceWidth:w,sourceHeight:h,index:i,exportScore:true)
                        if i==0 { for n in ["gray","stats","tensorStats","noise"] { try engine.debugBuffer(n).withUnsafeBytes { try Data($0).write(to:dir.appendingPathComponent("gpu-"+n+".f32")) } } }
                        let actual=engine.exportedScore(),expected=try load(dir.appendingPathComponent("score\(i).f32"),Float.self)
                        let maxValue=expected.max() ?? 1,err=zip(actual,expected).map{Double(abs($0-$1))}.max() ?? 0
                        scores.append(err/Double(max(maxValue,1)))
                    }
                    try engine.depth()
                    for i in 0..<3 { let input=try RGB16Tile(descriptor:d,rgba:load(dir.appendingPathComponent("source\(i).u16"),UInt16.self));try engine.fuse(tile:input,region:d,transform:transforms[i],sourceWidth:w,sourceHeight:h,index:i) }
                    let result=try engine.finish(tile:tile),diag=engine.diagnostics()
                    let expectedC=try load(dir.appendingPathComponent("candidates.u32"),UInt32.self),expectedL=try load(dir.appendingPathComponent("labels.u32"),UInt32.self),expectedConf=try load(dir.appendingPathComponent("confidence.f32"),Float.self)
                    let mismatches=zip(diag.candidates,expectedC).filter{$0 != $1}.count,labelMismatches=zip(diag.labels,expectedL).filter{$0 != $1}.count,confError=zip(diag.confidence,expectedConf).map{abs($0-$1)}.max() ?? 0
                    let expectedR=try load(dir.appendingPathComponent("reconstruction.f32"),Float.self),reconError=zip(diag.floatRGB,expectedR).map{abs($0-$1)}.max() ?? 0
                    let expectedFinal=try load(dir.appendingPathComponent("final.u16"),UInt16.self);var finalError=0
                    for i in 0..<d.pixelCount{for c in 0..<3{finalError=max(finalError,abs(Int(result.rgba[i*4+c])-Int(expectedFinal[i*3+c])))}}
                    guard scores.allSatisfy({$0<=2e-6}),Double(mismatches)/Double(expectedC.count)<=0.01,Double(labelMismatches)/Double(expectedL.count)<=0.005,confError<=1e-4,finalError<=128 else{throw NativeError.invalid("Golden parity tolerance failed for \(name)")}
                    print("\(name): score relative max \(scores), candidate mismatch \(mismatches)/\(expectedC.count), labels \(labelMismatches)/\(expectedL.count), confidence max \(confError), reconstruction max \(reconError), final uint16 max \(finalError)")
                };try printJSON(MemoryMonitor.snapshot());return
            }
            if args.count > 2, args[1] == "--libtiff-probe" {
                let before=MemoryMonitor.snapshot(), provider=LibTIFFTileProvider(url: URL(fileURLWithPath: args[2]))
                print(try provider.metadata().summary); try printJSON(before)
                let x=args.count>3 ? Int(args[3])! : 0, y=args.count>4 ? Int(args[4])! : 0
                let edge=args.count>5 ? Int(args[5])! : 1024, d=try TileDescriptor(x:x,y:y,width:edge,height:edge)
                try printJSON(provider.plan(d)); let start=Date.timeIntervalSinceReferenceDate
                let tile=try provider.readSync(d)
                print("Decode seconds: \(Date.timeIntervalSinceReferenceDate-start)");try printJSON(MemoryMonitor.snapshot())
                let digest=tile.rgba.withUnsafeBytes { SHA256.hash(data: Data($0)) }.map { String(format: "%02x",$0) }.joined()
                print("RGBA16 SHA256: \(digest)");return
            }
            if args.count>2,args[1]=="--tiff-fixtures" {
                let directory=URL(fileURLWithPath:args[2])
                let manifest=try JSONSerialization.jsonObject(with: Data(contentsOf:directory.appendingPathComponent("manifest.json"))) as! [[String:Any]]
                for entry in manifest {
                    let name=entry["name"] as! String,p=LibTIFFTileProvider(url:directory.appendingPathComponent(name))
                    let d=try TileDescriptor(x:3,y:5,width:17,height:19),tile=try p.readSync(d)
                    let actual=tile.rgba.withUnsafeBytes { Data($0) }, expected=try Data(contentsOf:directory.appendingPathComponent(name+".rgba"))
                    guard actual==expected else { throw NativeError.invalid("TIFF ROI mismatch: \(name)") }
                    print("PASS \(name): \(try p.metadata().summary)")
                };try printJSON(MemoryMonitor.snapshot());return
            }
            if args.count>2,args[1]=="--write-roundtrip" {
                let output=URL(fileURLWithPath:args[2]),d=try TileDescriptor(width:137,height:91)
                let source=try SyntheticTileProvider.make(d),writer=try TIFFOutputWriter(output:output,width:d.width,height:d.height,blockEdge:256,layout:.strips(rows:7))
                try writer.write(source);try printJSON(writer.finish())
                let result=try LibTIFFTileProvider(url:output).readSync(d)
                guard result.rgba==source.rgba else { throw NativeError.invalid("TIFF roundtrip mismatch") }
                let image=try ImageIOTileProvider(url:output,maximumDecodedBytes:1048576).readSync(d)
                guard image.rgba==source.rgba else { throw NativeError.invalid("ImageIO interoperability mismatch") };print("libtiff and ImageIO exact RGB16 roundtrip passed");return
            }
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
            guard args.count==1 else{throw NativeError.invalid("Unknown benchmark command or missing arguments")}
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
