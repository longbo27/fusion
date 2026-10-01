@_spi(Testing) import FocusStackCore
import XCTest
import Foundation

final class V22Tests:XCTestCase {
    func image(_ kind:String,n:Int=128)throws->ReducedImage {
        var p=[Float](repeating:0,count:n*n);var random:UInt64=2202
        func noise()->Float{random=random&*6364136223846793005&+1442695040888963407;return Float(random>>40)/Float(1<<24)}
        for y in 0..<n{for x in 0..<n{
            let v:Float
            switch kind {
            case "checkerboard":v=((x/8+y/8)%2)==0 ? 0.2:0.8
            case "grid":v=x%16<3||y%16<3 ? 0.8:0.2
            case "windows":v=x%20<8&&y%16<10 ? 0.8:0.2
            case "bricks":v=(y%12<2 || (x+(y/12%2)*8)%16<2) ? 0.8:0.2
            case "weak":v=0.5+noise()*0.00001
            case "grass":v=0.4+noise()*0.2+0.2*sin(Float(x)*0.36+Float(y)*0.11)
            default:v=0.15+noise()*0.7
            };p[y*n+x]=v
        }}
        return try ReducedImage(width:n,height:n,pixels:p)
    }
    func ambiguous(_ kind:String)throws {
        let r=try image(kind)
        XCTAssertThrowsError(try NativeAlignment.align(reference:r,candidate:r,fullWidth:128,fullHeight:128)){error in
            guard let e=error as? RegistrationRejected else{XCTFail("Expected structured registration rejection, got \(error)");return}
            XCTAssertTrue(e.diagnostics.registrationAmbiguous);XCTAssertLessThan(e.diagnostics.registrationConfidence,0.5)
        }
    }
    func testPeriodicGridRejection()throws{try ambiguous("grid")}
    func testRepeatedWindowsRejection()throws{try ambiguous("windows")}
    func testBricksRejection()throws{try ambiguous("bricks")}
    func testCheckerboardRejection()throws{try ambiguous("checkerboard")}
    func testWeakTextureRejection()throws{try ambiguous("weak")}
    func testRandomTextureRegistrationAccepted()throws{let r=try image("random"),a=try NativeAlignment.align(reference:r,candidate:r,fullWidth:128,fullHeight:128);XCTAssertFalse(a.registrationAmbiguous);XCTAssertGreaterThan(a.registrationConfidence,0.8)}
    func testNonperiodicGrassRegistrationAccepted()throws{let r=try image("grass"),a=try NativeAlignment.align(reference:r,candidate:r,fullWidth:128,fullHeight:128);XCTAssertFalse(a.registrationAmbiguous)}
    func testTrueTranslationAccepted()throws {
        let r=try image("random",n:192);var values=r.pixels
        for y in 0..<192{for x in 0..<192{values[y*192+x]=r.pixels[min(191,max(0,y-2))*192+min(191,max(0,x+3))]}}
        let a=try NativeAlignment.align(reference:r,candidate:ReducedImage(width:192,height:192,pixels:values),fullWidth:192,fullHeight:192)
        XCTAssertEqual(a.transform.tx,3,accuracy:0.5);XCTAssertEqual(a.transform.ty,-2,accuracy:0.5)
    }
    func testFocusBlurAccepted()throws {
        let r=try image("random");var values=r.pixels
        for y in 0..<128{for x in 0..<128{var sum:Float=0;for dy in -1...1{for dx in -1...1{sum+=r.pixels[min(127,max(0,y+dy))*128+min(127,max(0,x+dx))]}};values[y*128+x]=sum/9}}
        let a=try NativeAlignment.align(reference:r,candidate:ReducedImage(width:128,height:128,pixels:values),fullWidth:128,fullHeight:128);XCTAssertLessThan(hypot(a.transform.tx,a.transform.ty),1)
    }
    func testBackendSelectionUsesValidatedMeasurement() {
        let v:[InferenceBackendMeasurement]=[.init(backend:.cpu,medianMS:4,validated:true),.init(backend:.cpuANE,medianMS:1,validated:true),.init(backend:.metalML,medianMS:0.2,validated:false)]
        XCTAssertEqual(InferenceBackendSelection.choose(v,neuralEngine:true,metalML:true),.cpuANE)
        XCTAssertEqual(InferenceBackendSelection.choose(v,neuralEngine:false,metalML:true),.cpu)
        XCTAssertEqual(InferenceBackendSelection.choose([.init(backend:.metalML,medianMS:0.5,validated:true),.init(backend:.cpuANE,medianMS:1,validated:true)],neuralEngine:true,metalML:true),.metalML)
    }
    func testBackendSelectionRejectsInvalidTimes(){XCTAssertNil(InferenceBackendSelection.choose([.init(backend:.all,medianMS:.nan,validated:true),.init(backend:.cpu,medianMS:-1,validated:true)],neuralEngine:true,metalML:true))}
    func testNearTieDeterministicOwnership()throws {
        let e=try ProductionMetalPipeline(),d=try TileDescriptor(width:7,height:7);try e.begin(region:d,quality:.maximum)
        var ids=Array(repeating:SIMD4<UInt32>(3,1,4,0),count:d.pixelCount);ids[24]=SIMD4(2,1,4,0)
        try e.installOwnershipFixture(scores:Array(repeating:SIMD4(100,Float(100).nextDown,99,Float(100).nextDown),count:d.pixelCount),indices:ids,uncertainty:Array(repeating:SIMD4<Float>(repeating:0.001),count:d.pixelCount));try e.depth()
        XCTAssertEqual(e.diagnostics().labels[24],0)
    }
    func testConfidentOwnershipRemainsUnchanged()throws {
        let e=try ProductionMetalPipeline(),d=try TileDescriptor(width:17,height:13);try e.begin(region:d,quality:.maximum)
        try e.installOwnershipFixture(scores:Array(repeating:SIMD4(100,80,70,80),count:d.pixelCount),indices:Array(repeating:SIMD4(2,1,3,0),count:d.pixelCount),uncertainty:Array(repeating:SIMD4<Float>(repeating:10),count:d.pixelCount));try e.depth();XCTAssertTrue(e.diagnostics().labels.allSatisfy{$0==2})
    }
    func protected(_ kind:String)throws {
        let d=try TileDescriptor(width:65,height:49),tile=try ProductionTile(core:d,imageWidth:65,imageHeight:49,quality:.maximum),e=try ProductionMetalPipeline()
        let ref=try SyntheticTileProvider.make(d);var other=ref.rgba
        for i in 0..<d.pixelCount{other[i*4]=65535-ref.rgba[i*4];other[i*4+1]=65535-ref.rgba[i*4+1]}
        let candidate=try RGB16Tile(descriptor:d,rgba:other);try e.begin(region:d,quality:.maximum)
        try e.focus(tile:ref,region:d,sourceWidth:65,sourceHeight:49,index:0);try e.focus(tile:candidate,region:d,sourceWidth:65,sourceHeight:49,index:1);try e.depth()
        var mask=[SIMD4<Float>](repeating:SIMD4(0,1,0.9,0),count:d.pixelCount)
        for y in 0..<49{for x in 0..<65 {
            let dynamic:Bool
            switch kind{case "thin":dynamic=x==32;case "occlusion":dynamic=x>16&&x<48&&y>10&&y<40;default:dynamic=x>20}
            if dynamic{mask[y*65+x]=SIMD4(0.9999,0.0001,0.95,0)}
        }}
        try e.installMotionFixture(mask);try e.fuse(tile:ref,region:d,sourceWidth:65,sourceHeight:49,index:0);try e.fuse(tile:candidate,region:d,sourceWidth:65,sourceHeight:49,index:1)
        let output=try e.finish(tile:tile),debug=e.motionDiagnostics(tile:tile)
        XCTAssertTrue(debug.mask.contains(1))
        for i in 0..<d.pixelCount where debug.mask[i]==1 {XCTAssertEqual(debug.owners[i],0);for c in 0..<3{XCTAssertEqual(output.rgba[i*4+c],ref.rgba[i*4+c])}}
    }
    func testThinMotionPreservesCapturedRGB()throws{try protected("thin")}
    func testCoherentForegroundOwnership()throws{try protected("occlusion")}
    func testMultibandCannotReintroduceMotionRGB()throws{try protected("water")}
    func testStaticMaskDoesNotReplaceSources()throws {
        let d=try TileDescriptor(width:33,height:25),e=try ProductionMetalPipeline();try e.begin(region:d,quality:.maximum);let source=try SyntheticTileProvider.make(d);try e.focus(tile:source,region:d,sourceWidth:33,sourceHeight:25,index:0);try e.depth();let before=e.diagnostics().labels
        try e.installMotionFixture(Array(repeating:SIMD4(0.001,0.999,0.95,0),count:d.pixelCount));XCTAssertEqual(e.diagnostics().labels,before)
    }
    func testFocusMotionV1RealInferenceAndPlan()async throws {
        let url=try FocusMotionModelResource.compile();defer{try? FileManager.default.removeItem(at:url)}
        let runner=MotionPrototypeRunner(inputChannels:12,outputChannels:7);try await runner.load(url:url);let prediction=try await runner.predict(features:Array(repeating:0.25,count:12*65536))
        XCTAssertEqual(prediction.probabilities.count,7*65536);XCTAssertTrue(prediction.probabilities.allSatisfy{$0.isFinite&&$0>=0&&$0<=1})
        for i in stride(from:0,to:65536,by:127){XCTAssertEqual((3..<7).reduce(Float(0)){$0+prediction.probabilities[$1*65536+i]},1,accuracy:0.005)}
        let plan=try await ComputePlanInspector().inspect(compiledModelURL:url);XCTAssertGreaterThan(plan.filter{$0.operation.contains("conv")}.count,8)
    }
    func testBoundedParallelDeflatePreservesRGB16()throws {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:false);defer{try? FileManager.default.removeItem(at:dir)}
        let d=try TileDescriptor(width:257,height:193),source=try SyntheticTileProvider.make(d)
        for workers in [1,2] {
            let output=dir.appendingPathComponent("w\(workers).tif"),writer=try TIFFOutputWriter(output:output,width:d.width,height:d.height,blockEdge:512,layout:.strips(rows:17),compressionWorkers:workers)
            try writer.write(source);let report=try writer.finish();XCTAssertEqual(report.compressionWorkers,workers)
            XCTAssertEqual(try LibTIFFTileProvider(url:output).readSync(d).rgba,source.rgba)
            XCTAssertEqual(try ImageIOTileProvider(url:output,maximumDecodedBytes:1048576).readSync(d).rgba,source.rgba)
        }
    }
    func testMotionDoesNotChangePixelsOutsideMask()throws {
        let d=try TileDescriptor(width:65,height:49),t=try ProductionTile(core:d,imageWidth:65,imageHeight:49,quality:.maximum),e=try ProductionMetalPipeline(),ref=try SyntheticTileProvider.make(d)
        var other=ref.rgba;for k in stride(from:0,to:other.count,by:4){other[k]=UInt16(clamping:Int(other[k])+5000)}
        let candidate=try RGB16Tile(descriptor:d,rgba:other)
        func run(_ motion:Bool)throws->RGB16Tile {
            try e.begin(region:d,quality:.maximum);for(i,a)in [ref,candidate].enumerated(){try e.focus(tile:a,region:d,sourceWidth:65,sourceHeight:49,index:i)};try e.depth()
            if motion{var mask=Array(repeating:SIMD4<Float>(0,1,0.95,0),count:d.pixelCount);for y in 10..<40{for x in 20..<40{mask[y*65+x]=SIMD4(0.9999,0.0001,0.95,0)}};try e.installMotionFixture(mask)}
            for(i,a)in [ref,candidate].enumerated(){try e.fuse(tile:a,region:d,sourceWidth:65,sourceHeight:49,index:i)};return try e.finish(tile:t)
        }
        let off=try run(false),on=try run(true),maps=e.motionDiagnostics(tile:t)
        for i in 0..<d.pixelCount where maps.mask[i]==0{for c in 0..<3{XCTAssertEqual(off.rgba[i*4+c],on.rgba[i*4+c])}}
        XCTAssertEqual(Set(zip(maps.mask,maps.components).filter{$0.0==1}.map{$0.1}).count,1)
    }

    func testMissingMetalPackageFallsBackToCoreML()throws {
        let session=try MotionInferenceSession(metalPackage:URL(fileURLWithPath:"/nonexistent/FocusMotionNetV1.mtlpackage"))
        XCTAssertNotEqual(session.timing.backend,.metalML);XCTAssertTrue(session.timing.rejectedBackends.contains{$0.contains("metalML")})
        XCTAssertTrue(session.timing.measurements.allSatisfy{ $0.validated && $0.medianMS>0 })
    }
    func testForcedUnavailableMetalBackendReportsFailure() {
        XCTAssertThrowsError(try MotionInferenceSession(backend:.metalML))
    }

    func testNearTiePreservesSpatialMedianDecision()throws {
        let e=try ProductionMetalPipeline(),d=try TileDescriptor(width:7,height:7);try e.begin(region:d,quality:.maximum)
        var indices=Array(repeating:SIMD4<UInt32>(3,1,2,0),count:d.pixelCount);indices[24]=SIMD4(2,1,3,0)
        try e.installOwnershipFixture(scores:Array(repeating:SIMD4(100,Float(100).nextDown,99,Float(100).nextDown),count:d.pixelCount),indices:indices,uncertainty:Array(repeating:SIMD4<Float>(repeating:0.001),count:d.pixelCount));try e.depth()
        XCTAssertEqual(e.diagnostics().labels[24],3)
    }
    func testNearTiePreservesProtectedThinEdge()throws {
        let e=try ProductionMetalPipeline(),d=try TileDescriptor(width:7,height:7);try e.begin(region:d,quality:.maximum)
        let guide=(0..<d.pixelCount).map{Float($0%7<3 ? 0:50000)}
        try e.installOwnershipFixture(scores:Array(repeating:SIMD4(100,Float(100).nextDown,99,Float(100).nextDown),count:d.pixelCount),indices:Array(repeating:SIMD4(2,1,3,0),count:d.pixelCount),uncertainty:Array(repeating:SIMD4<Float>(repeating:0.001),count:d.pixelCount),guide:guide);try e.depth()
        XCTAssertEqual(e.diagnostics().labels[24],2)
    }

}
