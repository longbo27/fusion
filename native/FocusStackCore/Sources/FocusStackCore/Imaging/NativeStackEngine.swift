import Foundation
import QuartzCore

public struct NativeStackReport:Codable,Sendable {
    public let sourceCount:Int,width:Int,height:Int,tileEdge:Int,quality:StackQuality
    public let decodeSeconds:Double,alignmentSeconds:Double,gpu:ProductionTiming,write:TIFFWriteReport,totalSeconds:Double
    public let sourceFaithfulMode:SourceFaithfulMode
    public let productSeconds:Double
    public let aiMode:AIDeghostMode,aiSeconds:Double,modelTiming:MotionModelTiming?
    public let memory:MemorySnapshot,peakMetalBytes:UInt64,alignment:[AlignmentReport]
}
public actor NativeStackEngine {
    public init(){}
    public func run(inputs:[URL],output:URL,quality:StackQuality = .maximum,tileEdge:Int? = nil,suppliedTransforms:[SimilarityTransform]? = nil,aiMode:AIDeghostMode = .off,debugDirectory:URL? = nil,metalPackage:URL? = nil,progress:@Sendable (String,Double)->Void = {_,_ in})throws->NativeStackReport {
        try runProduct(inputs:inputs,output:output,quality:quality,tileEdge:tileEdge,suppliedTransforms:suppliedTransforms,aiMode:aiMode,debugDirectory:debugDirectory,metalPackage:metalPackage,progress:progress)
    }
    public func runProduct(inputs:[URL],output:URL,quality:StackQuality = .maximum,tileEdge:Int? = nil,
                    suppliedTransforms:[SimilarityTransform]? = nil,aiMode:AIDeghostMode = .off,debugDirectory:URL? = nil,metalPackage:URL? = nil,
                    sourceFaithfulMode:SourceFaithfulMode = .capturedSourcesOnly,constraints:[OwnershipConstraint]=[],productTile:(@Sendable (ProductEvidenceTile,RGB16Tile)throws->Void)? = nil,
                    progress:@Sendable (String,Double)->Void = {_,_ in})throws->NativeStackReport {
        let platform=ApplePlatformMemoryClass.current,maximumEdge=platform == .mobile ? 512:1024
        let capability=try MetalContext(),budget=MemoryMonitor.budget(recommended:capability.capabilities.recommendedWorkingSet)
        let selected=tileEdge ?? [maximumEdge,512,256,128].first{edge in
            let extent=edge+2*quality.halo+32
            return edge<=maximumEdge && ProductionMetalPipeline.plannedBytes(width:extent,height:extent,quality:quality)+(productTile != nil || !constraints.isEmpty ? UInt64(extent*extent*40):0)<budget
        } ?? 0
        let tileEdge=selected
        let started=CACurrentMediaTime()
        guard !inputs.isEmpty,inputs.count<=65535,tileEdge>0,tileEdge<=(ApplePlatformMemoryClass.current == .mobile ? 512:1024),
              inputs.allSatisfy({$0.standardizedFileURL != output.standardizedFileURL}) else{throw NativeError.invalid("Invalid stack sources, tile edge or output")}
        let providers=inputs.map{LibTIFFTileProvider(url:$0)},metadata=try providers[0].metadata()
        for provider in providers.dropFirst(){let m=try provider.metadata();guard m.width==metadata.width,m.height==metadata.height,m.icc==metadata.icc else{throw NativeError.invalid("Source geometry/ICC differs; explicit conversion is required before stacking")}}
        let resource=try output.deletingLastPathComponent().resourceValues(forKeys:[.volumeAvailableCapacityForImportantUsageKey])
        let diskNeeded=UInt64(metadata.width)*UInt64(metadata.height)*18+128*1048576
        if let free=resource.volumeAvailableCapacityForImportantUsage,UInt64(max(free,0))<diskNeeded {throw NativeError.resource("Insufficient disk capacity for raw staging, TIFF and codec margin")}
        var transforms=[SimilarityTransform](),alignment=[AlignmentReport]();let alignmentStart=CACurrentMediaTime()
        if let suppliedTransforms {guard suppliedTransforms.count==inputs.count else{throw NativeError.invalid("Transform count mismatch")};transforms=suppliedTransforms}
        else {
            progress("Alignment: reference reduction",0)
            let analysisEdge=platform == .mobile ? 512:1024
            let reference=try ReducedImage.read(providers[0],maximumEdge:analysisEdge);transforms.append(.init())
            for i in 1..<inputs.count{try Task.checkCancellation();progress("Alignment: source \(i+1)/\(inputs.count)",0)
                let candidate=try ReducedImage.read(providers[i],maximumEdge:analysisEdge),report=try NativeAlignment.align(reference:reference,candidate:candidate,fullWidth:metadata.width,fullHeight:metadata.height,previousTransform:transforms.last)
                alignment.append(report);transforms.append(report.transform)
                progress("Registration source \(i+1): confidence \(String(format:"%.3f",report.registrationConfidence)), ambiguous=\(report.registrationAmbiguous)",0)
            }
        }
        let alignmentSeconds=CACurrentMediaTime()-alignmentStart,pipeline=try ProductionMetalPipeline(productEvidence:productTile != nil || !constraints.isEmpty)
        let writer=try TIFFOutputWriter(output:output,width:metadata.width,height:metadata.height,blockEdge:tileEdge,metadata:metadata)
        let motionModel=aiMode == .off ? nil:try MotionInferenceSession(metalPackage:metalPackage)
        let debug=try debugDirectory.map{try MotionDebugMapWriter(directory:$0,width:metadata.width,height:metadata.height,registrationConfidence:alignment.map(\.registrationConfidence).min() ?? 1)}
        var aiSeconds=0.0,productSeconds=0.0
        var decode=0.0,timing=ProductionTiming(),tiles=0
        let totalTiles=((metadata.width+tileEdge-1)/tileEdge)*((metadata.height+tileEdge-1)/tileEdge)
        for y in stride(from:0,to:metadata.height,by:tileEdge){for x in stride(from:0,to:metadata.width,by:tileEdge){
            try autoreleasepool {
            try Task.checkCancellation()
            let core=try TileDescriptor(x:x,y:y,width:min(tileEdge,metadata.width-x),height:min(tileEdge,metadata.height-y))
            let tile=try ProductionTile(core:core,imageWidth:metadata.width,imageHeight:metadata.height,quality:quality)
            try pipeline.begin(region:tile.region,quality:quality)
            if !constraints.isEmpty{try pipeline.installConstraints(constraints,region:tile.region,sourceCount:inputs.count)}
            for i in inputs.indices{
                let start=CACurrentMediaTime(),roi=try tile.sourceROI(transform:transforms[i],width:metadata.width,height:metadata.height),pixels=try providers[i].readSync(roi)
                decode+=CACurrentMediaTime()-start
                try pipeline.focus(tile:pixels,region:tile.region,transform:transforms[i],sourceWidth:metadata.width,sourceHeight:metadata.height,index:i)
            }
            try pipeline.depth()
            if let motionModel {
                let start=CACurrentMediaTime()
                try motionModel.apply(to:pipeline,region:tile.region,mode:aiMode);aiSeconds+=CACurrentMediaTime()-start
            }
            for i in inputs.indices {
                let start=CACurrentMediaTime(),roi=try tile.sourceROI(transform:transforms[i],width:metadata.width,height:metadata.height),pixels=try providers[i].readSync(roi)
                decode+=CACurrentMediaTime()-start
                try pipeline.fuse(tile:pixels,region:tile.region,transform:transforms[i],sourceWidth:metadata.width,sourceHeight:metadata.height,index:i)
            }
            let result=try pipeline.finish(tile:tile);try writer.write(result)
            try debug?.add(pipeline.motionDiagnostics(tile:tile))
            if let productTile{let start=CACurrentMediaTime();try productTile(pipeline.productEvidence(tile:tile,registrationConfidence:suppliedTransforms == nil ? (alignment.map(\.registrationConfidence).min() ?? 1):nil,aiEnabled:aiMode != .off),result);productSeconds+=CACurrentMediaTime()-start}
            let t=pipeline.timing;timing.upload+=t.upload;timing.focus+=t.focus;timing.depth+=t.depth;timing.fusion+=t.fusion;timing.readback+=t.readback
            tiles+=1;progress("Focus/depth/fusion: tile \(tiles)/\(totalTiles); RSS \(MemoryMonitor.snapshot().residentBytes/1048576) MiB",Double(tiles)/Double(totalTiles))
            }
        }}
        progress("Encoding and complete TIFF validation",1);let write=try writer.finish();try debug?.finish()
        return NativeStackReport(sourceCount:inputs.count,width:metadata.width,height:metadata.height,tileEdge:tileEdge,quality:quality,decodeSeconds:decode,alignmentSeconds:alignmentSeconds,gpu:timing,write:write,totalSeconds:CACurrentMediaTime()-started,sourceFaithfulMode:sourceFaithfulMode,productSeconds:productSeconds,aiMode:aiMode,aiSeconds:aiSeconds,modelTiming:motionModel?.timing,memory:MemoryMonitor.snapshot(),peakMetalBytes:pipeline.peakMetalBytes,alignment:alignment)
    }
}
