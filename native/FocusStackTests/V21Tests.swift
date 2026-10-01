import FocusStackCore
import XCTest
import Foundation
import ImageIO
import Metal

final class V21Tests:XCTestCase {
    func temporary()->URL{FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".tif")}
    func fixture(bits:Int=16,bigEndian:Bool=false,orientation:Int=1)throws->URL {
        let w=47,h=33,count=13,ifdEnd=8+2+count*12+4,bitsOffset=ifdEnd,iccOffset=bitsOffset+6,profile=Data("opaque exact ICC".utf8),pixelOffset=iccOffset+profile.count
        var data=Data();func u16(_ n:Int){if bigEndian{data.append(UInt8((n>>8)&255));data.append(UInt8(n&255))}else{data.append(UInt8(n&255));data.append(UInt8((n>>8)&255))}}
        func u32(_ n:Int){if bigEndian{for i in [24,16,8,0]{data.append(UInt8((n>>i)&255))}}else{for i in [0,8,16,24]{data.append(UInt8((n>>i)&255))}}}
        data.append(contentsOf:bigEndian ? [77,77]:[73,73]);u16(42);u32(8);u16(count)
        func entry(_ tag:Int,_ type:Int,_ count:Int,_ value:Int){u16(tag);u16(type);u32(count);if type==3&&count==1{u16(value);u16(0)}else{u32(value)}}
        entry(256,4,1,w);entry(257,4,1,h);entry(258,3,3,bitsOffset);entry(259,3,1,1);entry(262,3,1,2);entry(273,4,1,pixelOffset);entry(274,3,1,orientation);entry(277,3,1,3);entry(278,4,1,h);entry(279,4,1,w*h*3*(bits/8));entry(284,3,1,1);entry(339,3,1,1);entry(34675,7,profile.count,iccOffset);u32(0)
        for _ in 0..<3{u16(bits)};data.append(profile)
        for y in 0..<h{for x in 0..<w{for c in 0..<3{let value=(x*1039+y*431+c*901)&65535;if bits==16{u16(value)}else{data.append(UInt8(value>>8))}}}}
        let url=temporary();try data.write(to:url);return url
    }
    func checkROI(bits:Int=16,big:Bool=false,orientation:Int=1)throws {
        let url=try fixture(bits:bits,bigEndian:big,orientation:orientation);defer{try? FileManager.default.removeItem(at:url)}
        let p=LibTIFFTileProvider(url:url),d=try TileDescriptor(x:3,y:5,width:17,height:19),tile=try p.readSync(d)
        for y in 0..<19{for x in 0..<17{
            let ox=x+3,oy=y+5,sx:Int,sy:Int
            switch orientation{case 1:(sx,sy)=(ox,oy);case 2:(sx,sy)=(46-ox,oy);case 3:(sx,sy)=(46-ox,32-oy);case 4:(sx,sy)=(ox,32-oy);case 5:(sx,sy)=(oy,ox);case 6:(sx,sy)=(oy,32-ox);case 7:(sx,sy)=(46-oy,32-ox);default:(sx,sy)=(46-oy,ox)}
            for c in 0..<3{let v=(sx*1039+sy*431+c*901)&65535;XCTAssertEqual(Int(tile.rgba[(y*17+x)*4+c]),bits==8 ? (v>>8)*257:v)}
        }}
        XCTAssertTrue(try p.plan(d).directUncompressedRows);XCTAssertEqual(try p.metadata().icc,Data("opaque exact ICC".utf8))
    }
    func testLibTIFFStripROI()throws{try checkROI()}
    func testLibTIFFBigEndian16()throws{try checkROI(big:true)}
    func testLibTIFFEightBitExpansion()throws{try checkROI(bits:8)}
    func testLibTIFFBigEndianEightBit()throws{try checkROI(bits:8,big:true)}
    func testLibTIFFAllOrientations()throws{for i in 1...8{try checkROI(orientation:i)}}
    func testLibTIFFROIAdmissionPlan()throws{let url=try fixture();defer{try? FileManager.default.removeItem(at:url)};let p=try LibTIFFTileProvider(url:url).plan(TileDescriptor(width:7,height:9));XCTAssertEqual(p.decodedSegmentBytes,42);XCTAssertEqual(p.requiredSegments,1);XCTAssertLessThan(p.plannedBytes,34*1048576)}
    func roundtrip(compression:TIFFCompression,layout:TIFFWriteLayout,big:Bool=false,icc:Bool=false)throws {
        let out=temporary(),original=try fixture();defer{try? FileManager.default.removeItem(at:out);try? FileManager.default.removeItem(at:original)}
        let d=try TileDescriptor(width:137,height:91),source=try SyntheticTileProvider.make(d),metadata=icc ? try LibTIFFTileProvider(url:original).metadata():nil
        let writer=try TIFFOutputWriter(output:out,width:137,height:91,blockEdge:256,metadata:metadata,layout:layout,compression:compression,forceBigTIFF:big)
        try writer.write(source);let report=try writer.finish();XCTAssertGreaterThan(report.outputBytes,0)
        let p=LibTIFFTileProvider(url:out);XCTAssertEqual(try p.readSync(d).rgba,source.rgba);XCTAssertEqual(try p.metadata().bigTIFF,big);XCTAssertEqual(try p.metadata().bits,16)
        if icc{XCTAssertEqual(try p.metadata().icc,metadata?.icc)}
        if case .strips = layout,!icc {XCTAssertEqual(try ImageIOTileProvider(url:out).readSync(d).rgba,source.rgba)}
    }
    func testNativeDeflateRoundtripImageIO()throws{try roundtrip(compression:.deflate,layout:.strips(rows:7))}
    func testNativeLZWRoundtripImageIO()throws{try roundtrip(compression:.lzw,layout:.strips(rows:9))}
    func testNativeUncompressedRoundtripImageIO()throws{try roundtrip(compression:.none,layout:.strips(rows:11))}
    func testNativeTiledDeflateRoundtrip()throws{try roundtrip(compression:.deflate,layout:.tiles(edge:32))}
    func testNativeTiledLZWRoundtrip()throws{try roundtrip(compression:.lzw,layout:.tiles(edge:16))}
    func testNativeBigTIFFRoundtrip()throws{try roundtrip(compression:.deflate,layout:.tiles(edge:32),big:true)}
    func testExactICCOutputPreservation()throws{try roundtrip(compression:.deflate,layout:.strips(rows:8),icc:true)}
    func testCompressedROISegmentSelection()throws{
        for layout in [TIFFWriteLayout.strips(rows:7),.tiles(edge:32),.strips(rows:91)]{
            let out=temporary();defer{try? FileManager.default.removeItem(at:out)}
            let writer=try TIFFOutputWriter(output:out,width:137,height:91,blockEdge:256,layout:layout);try writer.write(SyntheticTileProvider.make(TileDescriptor(width:137,height:91)));_ = try writer.finish()
            let d=try TileDescriptor(x:40,y:8,width:17,height:19),p=LibTIFFTileProvider(url:out),plan=try p.plan(d)
            XCTAssertEqual(try p.readSync(d).rgba,try SyntheticTileProvider.make(d).rgba)
            switch layout{case .tiles:XCTAssertEqual(plan.requiredSegments,1);case .strips(let rows):XCTAssertEqual(plan.requiredSegments,rows==7 ? 3:1)}
            XCTAssertFalse(plan.directUncompressedRows)
            if case .strips(rows:91)=layout{XCTAssertEqual(plan.decodedSegmentBytes,137*91*6)}
        }
    }
    func testOutputNeverReplacesExistingFile()throws{let out=temporary();defer{try? FileManager.default.removeItem(at:out)};try Data([27]).write(to:out);XCTAssertThrowsError(try TIFFOutputWriter(output:out,width:1,height:1,blockEdge:1));XCTAssertEqual(try Data(contentsOf:out),Data([27]))}
    func testIncompleteOutputIsNotPublished()throws{let out=temporary(),writer=try TIFFOutputWriter(output:out,width:2,height:2,blockEdge:1);defer{try? FileManager.default.removeItem(at:out)};XCTAssertThrowsError(try writer.finish());XCTAssertFalse(FileManager.default.fileExists(atPath:out.path))}
    func testDyadicHaloCoordinates()throws{let p=try ProductionTile(core:TileDescriptor(x:65,y:67,width:64,height:64),imageWidth:511,imageHeight:417,quality:.maximum);XCTAssertEqual(p.region.x%16,0);XCTAssertEqual(p.region.y%16,0);XCTAssertGreaterThanOrEqual(p.region.width,64+84)}
    func testSimilarityInverse() {let t=SimilarityTransform(a:1.02,b:0.03,tx:7,ty:-5),q=t.point(x:239,y:103),r=t.inverse.point(x:q.0,y:q.1);XCTAssertEqual(r.0,239,accuracy:1e-9);XCTAssertEqual(r.1,103,accuracy:1e-9)}
    func analytic(_ d:TileDescriptor,index:Int)throws->RGB16Tile{
        var values=[UInt16](repeating:65535,count:d.pixelCount*4)
        for y in 0..<d.height{for x in 0..<d.width{let gx=Float(x+d.x),gy=Float(y+d.y),gain:Float=(gx<129 ? (index==0 ? 1:0.3):(index==1 ? 1:0.4)),base=26000+4000*sin(gx*0.02)+3000*cos(gy*0.03),detail=gain*(5000*sin(gx*0.7+gy*0.2)+2000*cos(gy*0.8));for c in 0..<3{values[(y*d.width+x)*4+c]=UInt16(clamping:Int((base+detail+Float(c)*4000).rounded()))}}}
        return try RGB16Tile(descriptor:d,rgba:values)
    }
    func region(_ core:TileDescriptor,engine:ProductionMetalPipeline,count:Int=3,transforms:[SimilarityTransform]?=nil)throws->RGB16Tile{
        let t=try ProductionTile(core:core,imageWidth:257,imageHeight:193,quality:.maximum)
        try engine.begin(region:t.region,quality:.maximum)
        for i in 0..<count{let transform=transforms?[i] ?? .init(),roi=try t.sourceROI(transform:transform,width:257,height:193);try engine.focus(tile:analytic(roi,index:i),region:t.region,transform:transform,sourceWidth:257,sourceHeight:193,index:i)};try engine.depth()
        for i in 0..<count{let transform=transforms?[i] ?? .init(),roi=try t.sourceROI(transform:transform,width:257,height:193);try engine.fuse(tile:analytic(roi,index:i),region:t.region,transform:transform,sourceWidth:257,sourceHeight:193,index:i)}
        return try engine.finish(tile:t)
    }
    func testMultibandTileSeams()throws{
        let engine=try ProductionMetalPipeline(),full=try region(TileDescriptor(width:257,height:193),engine:engine)
        var error=0
        for y in stride(from:0,to:193,by:64){for x in stride(from:0,to:257,by:64){try autoreleasepool{let d=try TileDescriptor(x:x,y:y,width:min(64,257-x),height:min(64,193-y)),tile=try region(d,engine:engine);for yy in 0..<d.height{for xx in 0..<d.width{for c in 0..<3{error=max(error,abs(Int(tile.rgba[(yy*d.width+xx)*4+c])-Int(full.rgba[((yy+y)*257+xx+x)*4+c])))}}}}}}
        XCTAssertLessThanOrEqual(error,2,"Global halo/grid seam error in uint16 codes")
    }
    func testAffineGlobalCoordinatesAndTileSeams()throws{
        let engine=try ProductionMetalPipeline(),transforms:[SimilarityTransform]=[.init(),.init(a:1.005,b:0.008,tx:3.125,ty:-1.875),.init(a:0.996,b:-0.007,tx:-2.5,ty:3.75)],full=try region(TileDescriptor(width:257,height:193),engine:engine,transforms:transforms)
        var error=0
        for y in stride(from:0,to:193,by:64){for x in stride(from:0,to:257,by:64){try autoreleasepool{let d=try TileDescriptor(x:x,y:y,width:min(64,257-x),height:min(64,193-y)),tile=try region(d,engine:engine,transforms:transforms);for yy in 0..<d.height{for xx in 0..<d.width{for c in 0..<3{error=max(error,abs(Int(tile.rgba[(yy*d.width+xx)*4+c])-Int(full.rgba[((yy+y)*257+xx+x)*4+c])))}}}}}}
        XCTAssertLessThanOrEqual(error,2)
    }
    func testInvalidTransformRejectedBeforeROIAllocation()throws{let tile=try ProductionTile(core:TileDescriptor(width:17,height:13),imageWidth:47,imageHeight:33,quality:.maximum);XCTAssertThrowsError(try tile.sourceROI(transform:.init(a:0,b:0),width:47,height:33));XCTAssertThrowsError(try tile.sourceROI(transform:.init(tx:.nan),width:47,height:33))}
    func testAIMaskStackRoundtrip()async throws{
        let first=try fixture(),second=try fixture(),out=temporary();defer{for url in [first,second,out]{try? FileManager.default.removeItem(at:url)}}
        let report=try await NativeStackEngine().run(inputs:[first,second],output:out,tileEdge:32,suppliedTransforms:[.init(),.init()],aiMode:.auto)
        XCTAssertGreaterThan(report.aiSeconds,0);XCTAssertEqual(report.aiMode,.auto)
        XCTAssertEqual(try LibTIFFTileProvider(url:out).readSync(TileDescriptor(width:47,height:33)).rgba,try LibTIFFTileProvider(url:first).readSync(TileDescriptor(width:47,height:33)).rgba)
    }
    func testTwentySequentialSources()throws{let engine=try ProductionMetalPipeline(),result=try region(TileDescriptor(width:257,height:193),engine:engine,count:20);XCTAssertEqual(result.rgba.count,257*193*4);XCTAssertLessThan(engine.peakMetalBytes,512*1048576)}
    func testNegativeLaplacianAndFlatReconstruction()throws{
        let engine=try ProductionMetalPipeline(),d=try TileDescriptor(width:65,height:49),t=try ProductionTile(core:d,imageWidth:65,imageHeight:49,quality:.maximum),source=try SyntheticTileProvider.make(d)
        try engine.begin(region:d,quality:.maximum);try engine.focus(tile:source,region:d,sourceWidth:65,sourceHeight:49,index:0);try engine.depth();try engine.fuse(tile:source,region:d,sourceWidth:65,sourceHeight:49,index:0)
        XCTAssertEqual(try engine.finish(tile:t).rgba,source.rgba)
    }
    func testMotionPrototypeRealInference()async throws{
        let compiled=try MotionPrototypeResource.compile(),runner=MotionPrototypeRunner();try await runner.load(url:compiled)
        let prediction=try await runner.predict(features:[Float](repeating:0.25,count:5*65536));XCTAssertEqual(prediction.probabilities.count,131072);XCTAssertTrue(prediction.probabilities.allSatisfy{$0.isFinite&&$0>=0&&$0<=1})
        try? FileManager.default.removeItem(at:compiled)
    }
    func testMotionPrototypeComputePlan()async throws{
        let url=try MotionPrototypeResource.compile();defer{try? FileManager.default.removeItem(at:url)}
        let plan=try await ComputePlanInspector().inspect(compiledModelURL:url);XCTAssertTrue(plan.contains{$0.operation.contains("conv")});XCTAssertTrue(plan.filter{$0.operation.contains("conv")}.allSatisfy{!$0.supported.isEmpty})
    }
    func testNativeAlignmentTranslationRotationScale()throws{
        let n=256;var pixels=[Float](repeating:0,count:n*n)
        for y in 0..<n{for x in 0..<n{let fx=Float(x),fy=Float(y);pixels[y*n+x]=0.5+0.14*sin(fx*0.15+fy*0.041)+0.11*cos(fy*0.21)+0.07*sin(fx*0.61-fy*0.43)}}
        let ref=try ReducedImage(width:n,height:n,pixels:pixels),truth=SimilarityTransform(a:1.012,b:0.017,tx:4,ty:-3);var candidate=pixels
        func sample(_ x:Float,_ y:Float)->Float{let xx=max(0,min(Float(n-1),x)),yy=max(0,min(Float(n-1),y)),ix=Int(xx),iy=Int(yy),fx=xx-Float(ix),fy=yy-Float(iy);return (pixels[iy*n+ix]*(1-fx)+pixels[iy*n+min(ix+1,n-1)]*fx)*(1-fy)+(pixels[min(iy+1,n-1)*n+ix]*(1-fx)+pixels[min(iy+1,n-1)*n+min(ix+1,n-1)]*fx)*fy}
        for y in 0..<n{for x in 0..<n{let q=truth.point(x:Double(x),y:Double(y));candidate[y*n+x]=sample(Float(q.0),Float(q.1))}}
        let result=try NativeAlignment.align(reference:ref,candidate:ReducedImage(width:n,height:n,pixels:candidate),fullWidth:n,fullHeight:n)
        for q in [(20.0,20.0),(200,180)]{let a=result.transform.point(x:q.0,y:q.1),b=truth.point(x:q.0,y:q.1);XCTAssertLessThan(hypot(a.0-b.0,a.1-b.1),0.5)}
    }
}
