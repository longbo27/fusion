import Foundation
import FusionCore
import QuartzCore

public struct ProductRunReport:Codable,Sendable {
    public let engine:NativeStackReport,importHashSeconds:Double,finalizeSeconds:Double,totalSeconds:Double,provenanceBytes:UInt64,projectBytes:UInt64,sourceFaithful:SourceFaithfulReport,coverage:CoverageSummary,reviewFindings:Int
}
public struct IncrementalReport:Codable,Sendable {public let recomputedTiles:Int,recomputedPixels:UInt64,seconds:Double,readHalo:Int}
public actor FusionWorkflow {
    private var processing=false
    private var editorPipeline:ProductionMetalPipeline?
    private var editorSession:MotionInferenceSession?
    public init(){}
    public func run(inputs:[URL],output:URL,projectURL:URL,quality:StackQuality = .maximum,aiMode:AIDeghostMode = .off,suppliedTransforms:[SimilarityTransform]?=nil,diagnosticDirectory:URL?=nil,progress:@Sendable (String,Double)->Void = {_,_ in})async throws->(FusionProjectDocument,ProductRunReport) {
        guard !processing else{throw NativeError.resource("One product operation at a time")};processing=true;defer{processing=false}
        editorPipeline=nil;editorSession=nil
        let start=CACurrentMediaTime();var sources=[FrameSource]()
        for url in inputs{progress("Hashing source identity",0);sources.append(try TechnicalHash.source(url))}
        guard let first=inputs.first else{throw NativeError.invalid("No source")};let metadata=try LibTIFFTileProvider(url:first).metadata(),hashSeconds=CACurrentMediaTime()-start
        let doc=try FusionProjectDocument.create(directory:projectURL,manifest:FusionManifest(width:metadata.width,height:metadata.height,tileEdge:ApplePlatformMemoryClass.current == .mobile ? 512:1024,quality:quality,aiMode:aiMode,sources:sources))
        try await doc.record(.import,payload:.object(["inputHashes":.array(sources.map{.string($0.sha256)}),"mode":.string(SourceFaithfulMode.capturedSourcesOnly.rawValue)]))
        let sink=ProjectCollector(directory:await doc.mapsURL)
        let report=try await NativeStackEngine().runProduct(inputs:inputs,output:output,quality:quality,suppliedTransforms:suppliedTransforms,aiMode:aiMode,debugDirectory:diagnosticDirectory,productTile:{try sink.add($0,$1)},progress:progress)
        let finalize=CACurrentMediaTime()
        // Verify identities after processing; changed originals cannot receive a
        // trusted audit. The newly rendered output remains an untrusted artifact.
        for(i,source)in sources.enumerated(){guard try TechnicalHash.file(source.url)==source.sha256 else{throw NativeError.invalid("Source changed while rendering: \(i)")}}
        let result=sink.result(),transforms=suppliedTransforms ?? ([SimilarityTransform()]+report.alignment.map(\.transform))
        try await doc.record(.alignment,payload:.object(["transforms":try CanonicalJSON.decoder().decode(JSONValue.self,from:CanonicalJSON.data(transforms)),"confidenceMeasured":.bool(suppliedTransforms==nil)]))
        try await doc.record(.focusAnalysis,payload:.object(["quality":.string(quality.rawValue),"sourceCount":.integer(Int64(inputs.count))]))
        if let timing=report.modelTiming{try await doc.record(.motionAnalysis,payload:.object(["model":.string("FocusMotionNetV1"),"measuredBackend":.string(timing.backend.rawValue),"placement":.string("compute-plan diagnostics; no physical dispatch trace")]));try await doc.record(.aiOwnership,payload:.object(["policy":.string("coherent captured reference")]))}
        try await doc.install(render:report,blocks:result.0,findings:result.1,report:result.2,coverage:result.3,output:output,transforms:transforms)
        try await doc.markExport(output:output);_ = try await doc.exportAudit(output:output)
        return(doc,ProductRunReport(engine:report,importHashSeconds:hashSeconds,finalizeSeconds:CACurrentMediaTime()-finalize,totalSeconds:CACurrentMediaTime()-start,provenanceBytes:result.0.reduce(0){$0+UInt64($1.compressedBytes)},projectBytes:try Self.directoryBytes(projectURL),sourceFaithful:result.2,coverage:result.3,reviewFindings:result.1.count))
    }
    public func edit(project:FusionProjectDocument,constraints:[OwnershipConstraint],affected:PixelRegion)async throws->IncrementalReport {
        guard !processing else{throw NativeError.resource("One product operation at a time")};processing=true;defer{processing=false}
        let start=CACurrentMediaTime(),m=await project.manifest
        guard m.complete,m.transforms.count==m.sources.count else{throw NativeError.invalid("Incomplete project/transforms")}
        for i in m.sources.indices{guard try await project.availability(sourceIndex:i,verifyHash:false) == .available else{throw NativeError.invalid("Missing or changed source; relink before recompute")}}
        let plan=try IncrementalPlan(edit:affected,width:m.width,height:m.height,tileEdge:m.tileEdge,quality:m.quality)
        guard !plan.cores.isEmpty else{throw NativeError.invalid("Edit outside output")}
        if editorPipeline==nil{editorPipeline=try ProductionMetalPipeline(productEvidence:true)}
        if m.aiMode != .off && editorSession==nil{editorSession=try MotionInferenceSession()}
        let pipeline=editorPipeline!,session=m.aiMode == .off ? nil:editorSession,providers=m.sources.map{LibTIFFTileProvider(url:$0.url)}
        var newBlocks=[ProvenanceBlock](),newPaths=[String](),newFindings=[ArtifactFinding]()
        let maps=await project.mapsURL,cache=project.directory.appendingPathComponent("cache/replacements")
        for core in plan.cores {
            let rendered: (ProductEvidenceTile,RGB16Tile)=try autoreleasepool {
                let tile=try ProductionTile(core:core,imageWidth:m.width,imageHeight:m.height,quality:m.quality)
                try pipeline.begin(region:tile.region,quality:m.quality);try pipeline.installConstraints(constraints,region:tile.region,sourceCount:m.sources.count)
                for i in providers.indices{let roi=try tile.sourceROI(transform:m.transforms[i],width:m.width,height:m.height);try pipeline.focus(tile:providers[i].readSync(roi),region:tile.region,transform:m.transforms[i],sourceWidth:m.width,sourceHeight:m.height,index:i)}
                try pipeline.depth();try session?.apply(to:pipeline,region:tile.region,mode:m.aiMode)
                for i in providers.indices{let roi=try tile.sourceROI(transform:m.transforms[i],width:m.width,height:m.height);try pipeline.fuse(tile:providers[i].readSync(roi),region:tile.region,transform:m.transforms[i],sourceWidth:m.width,sourceHeight:m.height,index:i)}
                let pixels=try pipeline.finish(tile:tile),evidence=try pipeline.productEvidence(tile:tile,registrationConfidence:m.registrationConfidence,aiEnabled:m.aiMode != .off)
                return(evidence,pixels)
            }
            let block=try ProvenanceStorage.write(rendered.0,to:maps),path="\(block.id)-\(UUID().uuidString).rgba16"
            try rendered.1.rgba.withUnsafeBytes{try Data($0).write(to:cache.appendingPathComponent(path),options:.withoutOverwriting)}
            newBlocks.append(block);newPaths.append(path);newFindings+=ArtifactSentinel.inspect(rendered.0,output:rendered.1)
        }
        try await project.commitEdit(constraints:constraints,blocks:newBlocks,paths:newPaths,findings:newFindings,regions:plan.cores.map{PixelRegion(x:$0.x,y:$0.y,width:$0.width,height:$0.height)},affected:affected)
        return IncrementalReport(recomputedTiles:plan.cores.count,recomputedPixels:plan.cores.reduce(0){$0+UInt64($1.pixelCount)},seconds:CACurrentMediaTime()-start,readHalo:plan.readHalo)
    }
    public func export(project:FusionProjectDocument,to output:URL)async throws->TIFFWriteReport {
        guard !processing else{throw NativeError.resource("One product operation at a time")};processing=true;defer{processing=false}
        let m=await project.manifest
        guard m.complete,let baseline=m.outputURL,baseline != output,m.sources.allSatisfy({$0.url != output}) else{throw NativeError.invalid("New output destination required")}
        guard try TechnicalHash.file(baseline)==m.baseOutputSHA256 else{throw NativeError.invalid("Baseline output hash mismatch")}
        let provider=LibTIFFTileProvider(url:baseline),metadata=try provider.metadata(),writer=try TIFFOutputWriter(output:output,width:m.width,height:m.height,blockEdge:m.tileEdge,metadata:metadata)
        for block in m.provenance.sorted(by:{$0.y==$1.y ? $0.x<$1.x:$0.y<$1.y}){
            let d=try TileDescriptor(x:block.x,y:block.y,width:block.width,height:block.height),tile:RGB16Tile
            if let path=m.replacementTiles[block.id]{tile=try RGB16Tile(descriptor:d,rgba:await project.replacementPixels(block:block,path:path))}else{tile=try provider.readSync(d)}
            try writer.write(tile)
        }
        let report=try writer.finish();try await project.markExport(output:output);_ = try await project.exportAudit(output:output);return report
    }
    public func previewSource(project:FusionProjectDocument,index:Int,region:TileDescriptor)async throws->RGB16Tile {
        guard !processing else{throw NativeError.resource("Source preview waits for processing")};let m=await project.manifest;guard m.sources.indices.contains(index),m.transforms.count==m.sources.count else{throw NativeError.invalid("Source preview index/transforms")}
        let extent=try ProductionTile(core:region,imageWidth:m.width,imageHeight:m.height,quality:.standard),roi=try extent.sourceROI(transform:m.transforms[index],width:m.width,height:m.height)
        let pixels=try LibTIFFTileProvider(url:m.sources[index].url).readSync(roi)
        return try ProductionMetalPipeline().alignedPreview(tile:pixels,region:region,transform:m.transforms[index],sourceWidth:m.width,sourceHeight:m.height)
    }
    public static func directoryBytes(_ directory:URL)throws->UInt64 {
        guard let e=FileManager.default.enumerator(at:directory,includingPropertiesForKeys:[.fileSizeKey,.isRegularFileKey])else{throw NativeError.resource("Cannot enumerate project")};var n:UInt64=0
        for case let url as URL in e{let r=try url.resourceValues(forKeys:[.fileSizeKey,.isRegularFileKey]);if r.isRegularFile==true{n+=UInt64(r.fileSize ?? 0)}};return n
    }
}
