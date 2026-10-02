import Foundation
import FusionCore

public actor FusionProjectDocument {
    public nonisolated let directory:URL
    public private(set) var manifest:FusionManifest
    private var original:JSONValue,lastManifestHash:String
    private var auditURL:URL{directory.appendingPathComponent("history/audit.jsonl")}
    public var mapsURL:URL{directory.appendingPathComponent("maps/provenance")}
    private init(directory:URL,manifest:FusionManifest,original:JSONValue,lastManifestHash:String){self.directory=directory;self.manifest=manifest;self.original=original;self.lastManifestHash=lastManifestHash}
    public static func create(directory:URL,manifest:FusionManifest)throws->FusionProjectDocument {
        guard directory.pathExtension=="fusionproject",!FileManager.default.fileExists(atPath:directory.path),manifest.width>0,manifest.height>0,manifest.width<=500000,manifest.height<=500000,manifest.sources.count<=65535,manifest.tileEdge>0,manifest.tileEdge<=1024 else{throw NativeError.invalid("New project directory/geometry required")}
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        for path in ["sources","processing","maps/provenance","manual","qa","history","cache/replacements"]{try FileManager.default.createDirectory(at:directory.appendingPathComponent(path),withIntermediateDirectories:true)}
        let bytes=try CanonicalJSON.data(manifest);guard bytes.count<=8*1048576 else{throw NativeError.resource("Project metadata budget")};try bytes.write(to:directory.appendingPathComponent("manifest.json"),options:.atomic)
        return FusionProjectDocument(directory:directory,manifest:manifest,original:try CanonicalJSON.decoder().decode(JSONValue.self,from:bytes),lastManifestHash:TechnicalHash.data(bytes))
    }
    public static func open(directory:URL)throws->FusionProjectDocument {
        for path in ["maps","maps/provenance","cache","cache/replacements","history","processing","manual","qa"]{let r=try directory.appendingPathComponent(path).resourceValues(forKeys:[.isSymbolicLinkKey,.isDirectoryKey]);guard r.isDirectory==true,r.isSymbolicLink==false else{throw NativeError.invalid("Project symlink/non-directory component")}}
        let url=directory.appendingPathComponent("manifest.json"),raw=try CanonicalJSON.read(JSONValue.self,url:url)
        guard case .object(var object)=raw,case .integer(let version)=object["formatVersion"],version<=1,version>=0 else{throw NativeError.unavailable("Future/invalid project version: preserved without rewriting")}
        if version==0{object["formatVersion"] = .integer(1);if object["sourceFaithfulMode"]==nil{object["sourceFaithfulMode"] = .string("capturedSourcesOnly")}}
        let data=try CanonicalJSON.data(JSONValue.object(object)),manifest=try CanonicalJSON.decoder().decode(FusionManifest.self,from:data)
        guard manifest.width>0,manifest.height>0,manifest.width<=500000,manifest.height<=500000,manifest.tileEdge>0,manifest.tileEdge<=1024,manifest.sources.count<=65535,manifest.provenance.count<=100000,manifest.overrides.count<=100000,manifest.findings.count<=512 else{throw NativeError.invalid("Project bounded schema constraints")}
        if manifest.complete {
            func validCounts(_ report:SourceFaithfulReport,_ coverage:CoverageSummary,_ pixels:UInt64)->Bool {
                let counts=[report.hardOwnership,report.realSourceBlend,report.referenceFallback,report.aiOwnership,report.manuallyOverridden,report.lowConfidence,report.generativePhotographicPixels]
                guard report.pixelCount==pixels,counts.allSatisfy({$0<=pixels}),coverage.evaluatedPixels==pixels,coverage.adequateEvidencePixels<=pixels,coverage.lowEvidencePixels<=pixels else{return false}
                return report.hardOwnership+report.realSourceBlend+report.referenceFallback+report.aiOwnership==pixels
            }
            guard validCounts(manifest.report,manifest.coverage,UInt64(manifest.width)*UInt64(manifest.height)) else{throw NativeError.invalid("Project summary extent mismatch")}
            let expected=((manifest.width+manifest.tileEdge-1)/manifest.tileEdge)*((manifest.height+manifest.tileEdge-1)/manifest.tileEdge)
            guard manifest.sources.count>0,manifest.transforms.count==manifest.sources.count,manifest.transforms.allSatisfy({$0.a.isFinite&&$0.b.isFinite&&$0.tx.isFinite&&$0.ty.isFinite&&$0.a*$0.a+$0.b*$0.b>1e-12}),manifest.provenance.count==expected,Set(manifest.provenance.map(\.id)).count==expected else{throw NativeError.invalid("Incomplete provenance/transform geometry")}
            for b in manifest.provenance{guard b.x>=0,b.y>=0,b.x<manifest.width,b.y<manifest.height,b.x%manifest.tileEdge==0,b.y%manifest.tileEdge==0,b.width==min(manifest.tileEdge,manifest.width-b.x),b.height==min(manifest.tileEdge,manifest.height-b.y),b.id=="\(b.x)-\(b.y)",validCounts(b.summary,b.coverage,UInt64(b.width)*UInt64(b.height)) else{throw NativeError.invalid("Provenance grid/summary mismatch")}}
        }
        let chain=try AuditTrail.verify(url:directory.appendingPathComponent("history/audit.jsonl"))
        guard chain.head==manifest.auditHead else{throw NativeError.invalid("Project/audit head mismatch")}
        return FusionProjectDocument(directory:directory,manifest:manifest,original:raw,lastManifestHash:TechnicalHash.data(try Data(contentsOf:url)))
    }
    private func saveUnlocked()throws {
        let url=directory.appendingPathComponent("manifest.json")
        guard TechnicalHash.data(try Data(contentsOf:url))==lastManifestHash else{throw NativeError.invalid("Project changed by another writer; reopen before editing")}
        manifest.lastModifiedDate=Date()
        let current=try CanonicalJSON.decoder().decode(JSONValue.self,from:CanonicalJSON.data(manifest)),merged=original.updating(with:current),data=try CanonicalJSON.data(merged)
        guard data.count<=8*1048576 else{throw NativeError.resource("Project manifest exceeds bounded limit")}
        try data.write(to:url,options:.atomic);original=merged;lastManifestHash=TechnicalHash.data(data)
    }
    public func save()throws {try ProjectWriteLock.perform(directory:directory){try saveUnlocked()}}
    public func record(_ operation:ProcessingOperation,payload:JSONValue = .object([:]),regions:[PixelRegion]=[])throws {
        try ProjectWriteLock.perform(directory:directory){
        guard TechnicalHash.data(try Data(contentsOf:directory.appendingPathComponent("manifest.json")))==lastManifestHash else{throw NativeError.invalid("Conflicting project writer; reopen before editing")}
        guard manifest.history.count<10000 else{throw NativeError.resource("History budget exhausted")}
        let prospective=try CanonicalJSON.data(manifest);guard prospective.count<8*1048576-1048576 else{throw NativeError.resource("Project metadata reserve exhausted")}
        manifest.auditHead=try AuditTrail.append(url:auditURL,operation:operation,payload:payload)
        manifest.history.append(ProcessingNode(operation:operation,parameters:payload,invalidatedRegions:regions))
        guard manifest.history.count<=10000 else{throw NativeError.resource("History budget exhausted")}
        try saveUnlocked()
        }
    }
    public func availability(sourceIndex:Int,verifyHash:Bool=true)throws->SourceAvailability {
        guard manifest.sources.indices.contains(sourceIndex)else{throw NativeError.invalid("Source index")}
        let source=manifest.sources[sourceIndex]
        guard FileManager.default.fileExists(atPath:source.url.path)else{return .missing}
        guard source.kind != .videoFrame else{return .unsupported}
        let attributes=try source.url.resourceValues(forKeys:[.fileSizeKey,.contentModificationDateKey])
        if UInt64(attributes.fileSize ?? 0) != source.size{return .hashMismatch}
        if !verifyHash,let recorded=source.modificationTime,attributes.contentModificationDate?.timeIntervalSince1970 != recorded{return .hashMismatch}
        if verifyHash, try TechnicalHash.file(source.url) != source.sha256{return .hashMismatch}
        return .available
    }
    public func relink(sourceIndex:Int,to url:URL)throws {
        guard manifest.sources.indices.contains(sourceIndex)else{throw NativeError.invalid("Source index")}
        let replacement=try TechnicalHash.source(url),old=manifest.sources[sourceIndex]
        guard replacement.sha256==old.sha256,replacement.size==old.size,replacement.metadataFingerprint==old.metadataFingerprint else{throw NativeError.invalid("Relink hash/metadata mismatch; original identity retained")}
        manifest.sources[sourceIndex].modificationTime=replacement.modificationTime;manifest.sources[sourceIndex].modificationDate=replacement.modificationDate;manifest.sources[sourceIndex].url=url.standardizedFileURL;manifest.sources[sourceIndex].filename=url.lastPathComponent
        try record(.relink,payload:.object(["sourceID":.string(old.id.uuidString),"sha256":.string(old.sha256)]))
    }
    public func install(render:NativeStackReport,blocks:[ProvenanceBlock],findings:[ArtifactFinding],report:SourceFaithfulReport,coverage:CoverageSummary,output:URL,transforms:[SimilarityTransform])throws {
        manifest.tileEdge=render.tileEdge;manifest.transforms=transforms;manifest.registrationConfidence=render.alignment.map(\.registrationConfidence).min();manifest.provenance=blocks;manifest.findings=findings;manifest.report=report;manifest.coverage=coverage;manifest.outputURL=output;manifest.outputSHA256=try TechnicalHash.file(output);manifest.baseOutputSHA256=manifest.outputSHA256;manifest.complete=true
        try record(.fusion,payload:.object(["sourceFaithful":.bool(report.sourceFaithful),"outputSHA256":.string(manifest.outputSHA256!),"quality":.string(render.quality.rawValue)]))
        try record(.qa,payload:.object(["reviewFindings":.integer(Int64(findings.count)),"coverageCalibrated":.bool(false)]))
    }
    public func inspect(x:Int,y:Int)throws->PixelProvenance {
        guard let block=manifest.provenance.first(where:{x>=$0.x&&y>=$0.y&&x-$0.x<$0.width&&y-$0.y<$0.height})else{throw NativeError.unavailable("No provenance at location")}
        let tile=try ProvenanceStorage.read(block,from:mapsURL)
        return PixelProvenance(word:tile.words[(y-block.y)*block.width+x-block.x])
    }
    public func review(id:String,action:String)throws {
        guard ["markReviewed","ignore","acceptAuto"].contains(action),let i=manifest.findings.firstIndex(where:{$0.id==id})else{throw NativeError.invalid("Review action/finding")}
        manifest.findings[i].reviewed=true;manifest.findings[i].ignored=action=="ignore"
        try record(.review,payload:.object(["finding":.string(id),"action":.string(action)]))
    }
    public func companion(output:URL)throws->AuditCompanion {
        guard manifest.complete else{throw NativeError.invalid("Incomplete project cannot claim source-faithful export")}
        return AuditCompanion(engineVersion:manifest.engineVersion,AIModelVersion:manifest.AIModelVersion,model:manifest.model,sourceFaithful:manifest.report,sources:manifest.sources.map{.init(id:$0.id,size:$0.size,sha256:$0.sha256,metadataFingerprint:$0.metadataFingerprint,colorProfileSHA256:$0.colorProfileSHA256)},transforms:manifest.transforms,registrationConfidence:manifest.registrationConfidence,quality:manifest.quality,aiMode:manifest.aiMode,overrides:manifest.overrides,coverage:manifest.coverage,outputSHA256:try TechnicalHash.file(output),auditHead:manifest.auditHead)
    }
    public func exportAudit(output:URL)throws->URL {
        let url=output.deletingPathExtension().appendingPathExtension("fusion.json")
        guard !FileManager.default.fileExists(atPath:url.path),manifest.sources.allSatisfy({$0.url != url})else{throw NativeError.invalid("Audit destination already exists")}
        try CanonicalJSON.data(companion(output:output)).write(to:url,options:.withoutOverwriting);return url
    }
    public func commitEdit(constraints:[OwnershipConstraint],blocks:[ProvenanceBlock],paths:[String],findings:[ArtifactFinding],regions:[PixelRegion],affected:PixelRegion)throws {
        guard blocks.count==paths.count else{throw NativeError.invalid("Edit transaction extents")}
        let previous=manifest
        do {
            try updateOverrides(constraints)
            for i in blocks.indices{try replace(block:blocks[i],rawPath:paths[i])}
            updateFindings(findings,regions:regions);try recomputeSummary()
            try record(.manualOwnershipEdit,payload:CanonicalJSON.decoder().decode(JSONValue.self,from:CanonicalJSON.data(constraints)),regions:[affected])
        }catch{manifest=previous;throw error}
    }
    public func updateOverrides(_ constraints:[OwnershipConstraint])throws {
        guard constraints.count<=100000,constraints.allSatisfy({$0.region.valid&&$0.region.x+$0.region.width<=manifest.width&&$0.region.y+$0.region.height<=manifest.height&&$0.action.sourceIndex>=0&&$0.action.sourceIndex<manifest.sources.count})else{throw NativeError.invalid("Invalid sparse constraints")}
        manifest.overrides=constraints
    }
    public func replace(block:ProvenanceBlock,rawPath:String)throws {
        guard !rawPath.contains("/"),rawPath.hasSuffix(".rgba16")else{throw NativeError.invalid("Replacement cache path")}
        manifest.provenance.removeAll{$0.id==block.id};manifest.provenance.append(block);manifest.replacementTiles[block.id]=rawPath;manifest.replacementHashes[block.id]=try TechnicalHash.file(directory.appendingPathComponent("cache/replacements/"+rawPath))
    }
    public func preview(region:TileDescriptor)throws->(RGB16Tile,ProductEvidenceTile) {
        guard manifest.complete,let baseline=manifest.outputURL,region.x+region.width<=manifest.width,region.y+region.height<=manifest.height else{throw NativeError.invalid("Preview geometry/project")}
        let base=try LibTIFFTileProvider(url:baseline).readSync(region)
        var rgba=base.rgba,words=[SIMD4<UInt32>](repeating:.zero,count:region.pixelCount)
        let selected=PixelRegion(x:region.x,y:region.y,width:region.width,height:region.height)
        for block in manifest.provenance where selected.intersects(PixelRegion(x:block.x,y:block.y,width:block.width,height:block.height)) {
            let tile=try ProvenanceStorage.read(block,from:mapsURL);var replacement:[UInt16]?
            if let path=manifest.replacementTiles[block.id]{replacement=try replacementPixels(block:block,path:path)}
            for y in max(region.y,block.y)..<min(region.y+region.height,block.y+block.height){for x in max(region.x,block.x)..<min(region.x+region.width,block.x+block.width){let a=(y-region.y)*region.width+x-region.x,b=(y-block.y)*block.width+x-block.x;words[a]=tile.words[b];if let replacement{for c in 0..<4{rgba[a*4+c]=replacement[b*4+c]}}}}
        }
        return(try RGB16Tile(descriptor:region,rgba:rgba),try ProductEvidenceTile(descriptor:region,words:words))
    }
    public func replacementPixels(block:ProvenanceBlock,path:String)throws->[UInt16] {
        guard !path.contains("/"),path.hasSuffix(".rgba16")else{throw NativeError.invalid("Unsafe replacement reference")}
        let url=directory.appendingPathComponent("cache/replacements/"+path),r=try url.resourceValues(forKeys:[.fileSizeKey,.isSymbolicLinkKey])
        guard r.isSymbolicLink==false,r.fileSize==block.width*block.height*8 else{throw NativeError.invalid("Replacement cache extent")}
        let bytes=try Data(contentsOf:url);guard TechnicalHash.data(bytes)==manifest.replacementHashes[block.id]else{throw NativeError.invalid("Replacement cache hash mismatch")}
        return bytes.withUnsafeBytes{Array($0.bindMemory(to:UInt16.self))}
    }
    public func recomputeSummary()throws {
        var summary=SourceFaithfulReport(),coverage=CoverageSummary()
        for block in manifest.provenance{summary.merge(block.summary);coverage.merge(block.coverage)}
        manifest.report=summary;manifest.coverage=coverage
    }
    public func updateFindings(_ findings:[ArtifactFinding],regions:[PixelRegion]) {
        manifest.findings.removeAll{finding in regions.contains{$0.intersects(finding.boundingRegion)}}
        manifest.findings+=findings;manifest.findings=Array(manifest.findings.sorted{$0.severity>$1.severity}.prefix(512))
    }
    public func markExport(output:URL)throws {manifest.outputSHA256=try TechnicalHash.file(output);try record(.export,payload:.object(["outputSHA256":.string(manifest.outputSHA256!)]))}
}
