@_spi(Testing) import FocusStackCore
import FusionCore
import FusionProject
import FusionAI
import Foundation
import XCTest

final class V3Tests:XCTestCase {
    func directory()throws->URL{let d=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);try FileManager.default.createDirectory(at:d,withIntermediateDirectories:false);return d}
    func evidence(mode:String)throws->(ProductEvidenceTile,RGB16Tile,RGB16Tile){
        let d=try TileDescriptor(width:65,height:49),p=try ProductionMetalPipeline(productEvidence:true),t=try ProductionTile(core:d,imageWidth:d.width,imageHeight:d.height,quality:.maximum)
        var rgba=[UInt16](repeating:65535,count:d.pixelCount*4)
        for i in 0..<d.pixelCount{for c in 0..<3{rgba[i*4+c]=UInt16(mode=="sharp" ? (i*7919+c*1597)%50000+5000:30000+i%65*3+i/65*2)}}
        let src=try RGB16Tile(descriptor:d,rgba:rgba);try p.begin(region:d,quality:.maximum)
        if mode=="manual"||mode=="hard"{try p.installConstraints([OwnershipConstraint(region:PixelRegion(x:0,y:0,width:d.width,height:d.height),action:.source(1))],region:d,sourceCount:2)}
        let transform=SimilarityTransform(tx:mode=="fallback" ? 10000:0)
        for i in 0..<2{try p.focus(tile:src,region:d,transform:transform,sourceWidth:d.width,sourceHeight:d.height,index:i)};try p.depth()
        if mode=="ai"{try p.installMotionFixture(Array(repeating:SIMD4(0.9999,0.0001,0.99,0),count:d.pixelCount))}
        for i in 0..<2{try p.fuse(tile:src,region:d,transform:transform,sourceWidth:d.width,sourceHeight:d.height,index:i)}
        let out=try p.finish(tile:t),capture=try p.productEvidence(tile:t,registrationConfidence:mode=="unknown" ? nil:0.94,aiEnabled:mode=="ai")
        return(capture,out,src)
    }
    func testMultibandProvenanceDoesNotInventWeights()throws{let t=try evidence(mode:"blend").0;let p=PixelProvenance(word:t.words[100]);XCTAssertEqual(p.mode,.multibandBlend);XCTAssertNil(p.primaryContribution);XCTAssertTrue(p.contributionDescription.contains("not retained"))}
    func testManualHardOwnershipProvenanceAndPixels()throws{let(t,out,src)=try evidence(mode:"manual");XCTAssertEqual(out.rgba,src.rgba);XCTAssertTrue(t.words.allSatisfy{PixelProvenance(word:$0).mode == .manualOverride&&PixelProvenance(word:$0).primarySource==1})}
    func testAIOwnershipProvenance()throws{let(t,out,src)=try evidence(mode:"ai");XCTAssertEqual(out.rgba,src.rgba);XCTAssertTrue(t.words.allSatisfy{PixelProvenance(word:$0).mode == .aiDeghostOwnership})}
    func testReferenceFallbackProvenance()throws{let t=try evidence(mode:"fallback").0;XCTAssertTrue(t.words.allSatisfy{PixelProvenance(word:$0).mode == .referenceFallback})}
    func testUnknownMotionAndRegistrationRemainUnknown()throws{let p=PixelProvenance(word:try evidence(mode:"unknown").0.words[100]);XCTAssertNil(p.motionProbability);XCTAssertNil(p.registrationConfidence);XCTAssertNil(p.uncertainty.registrationUncertainty)}
    func testCoverageMeasuresAbsoluteEvidenceNotJustWinner()throws{let blurred=try evidence(mode:"blend").0,sharp=try evidence(mode:"sharp").0;let a=blurred.words.reduce(0.0){$0+Double($1.z>>24)},b=sharp.words.reduce(0.0){$0+Double($1.z>>24)};XCTAssertGreaterThan(b,a*2);XCTAssertEqual(PixelProvenance(word:sharp.words[100]).focusConfidence,0)}
    func testSourceFaithfulAccountingIncludesBlends()throws{let t=try evidence(mode:"blend").0;var r=SourceFaithfulReport();t.words.forEach{r.add($0)};XCTAssertTrue(r.sourceFaithful);XCTAssertGreaterThan(r.realSourceBlend,0);XCTAssertEqual(r.generativePhotographicPixels,0)}
    func testCompressedProvenanceRoundTripAndHashRejection()throws{let dir=try directory();defer{try? FileManager.default.removeItem(at:dir)};let tile=try evidence(mode:"blend").0,block=try ProvenanceStorage.write(tile,to:dir);XCTAssertEqual(try ProvenanceStorage.read(block,from:dir).words,tile.words);XCTAssertLessThan(block.compressedBytes,block.rawBytes);try Data([1,2,3]).write(to:dir.appendingPathComponent(block.path));XCTAssertThrowsError(try ProvenanceStorage.read(block,from:dir))}
    func testSentinelSerializesFindingsWithoutModifyingPixels()throws{let(tile,out,_)=try evidence(mode:"blend"),before=out.rgba,findings=ArtifactSentinel.inspect(tile,output:out);XCTAssertFalse(findings.isEmpty);XCTAssertEqual(out.rgba,before);let bytes=try CanonicalJSON.data(findings);XCTAssertEqual(try CanonicalJSON.decoder().decode([ArtifactFinding].self,from:bytes).count,findings.count)}
    func testUncertaintyCausesSurviveStorage()throws{let p=PixelProvenance(word:try evidence(mode:"ai").0.words[100]);let copy=try CanonicalJSON.decoder().decode(PixelProvenance.self,from:CanonicalJSON.data(p));XCTAssertEqual(copy.uncertainty,p.uncertainty);XCTAssertNotNil(copy.uncertainty.motionUncertainty)}
    func testIncrementalPlanIsLocalAndUsesHalo()throws{let plan=try IncrementalPlan(edit:PixelRegion(x:200,y:200,width:32,height:32),width:10000,height:10000,tileEdge:1024,quality:.maximum);XCTAssertEqual(plan.cores.count,1);XCTAssertGreaterThan(plan.readHalo,80)}
    func testIncrementalPlanIncludesNeighborAcrossBoundary()throws{let plan=try IncrementalPlan(edit:PixelRegion(x:1010,y:1010,width:32,height:32),width:3000,height:3000,tileEdge:1024,quality:.maximum);XCTAssertEqual(plan.cores.count,4)}
    func testAuditCanonicalDeterminismAndChain()throws{let dir=try directory();defer{try? FileManager.default.removeItem(at:dir)};let a=dir.appendingPathComponent("a"),b=dir.appendingPathComponent("b"),date=Date(timeIntervalSince1970:42),payload=JSONValue.object(["z":.integer(7),"a":.bool(true)]);let h1=try AuditTrail.append(url:a,operation:.import,payload:payload,date:date),h2=try AuditTrail.append(url:b,operation:.import,payload:payload,date:date);XCTAssertEqual(h1,h2);_ = try AuditTrail.append(url:a,operation:.export,payload:payload,date:date);XCTAssertEqual(try AuditTrail.verify(url:a).count,2)}
    func testAuditTamperIsDetected()throws{let dir=try directory();defer{try? FileManager.default.removeItem(at:dir)};let url=dir.appendingPathComponent("audit");_ = try AuditTrail.append(url:url,operation:.import,payload:.null);_ = try AuditTrail.append(url:url,operation:.export,payload:.null);var text=try String(contentsOf:url,encoding:.utf8);text=text.replacingOccurrences(of:"import",with:"review");try text.write(to:url,atomically:true,encoding:.utf8);XCTAssertThrowsError(try AuditTrail.verify(url:url))}
    func testStreamingOutputSHA256()throws{let dir=try directory();defer{try? FileManager.default.removeItem(at:dir)};let url=dir.appendingPathComponent("hash");try Data("abc".utf8).write(to:url);XCTAssertEqual(try TechnicalHash.file(url),"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")}
    func testIPGatesAreExplicit(){XCTAssertEqual(ProductFeature.future.filter{$0.status == .ipReviewRequired}.count,6);XCTAssertFalse(ProductFeature.future.contains{$0.status == .available})}
    func testUnknownNestedFieldsSurviveMerge()throws{let old=JSONValue.object(["future":.string("keep"),"records":.array([.object(["id":.string("a"),"unknown":.integer(9),"value":.integer(1)])])]),new=JSONValue.object(["records":.array([.object(["id":.string("a"),"value":.integer(2)])])]);let merged=old.updating(with:new);XCTAssertTrue(String(decoding:try CanonicalJSON.data(merged),as:UTF8.self).contains("unknown"));XCTAssertTrue(String(decoding:try CanonicalJSON.data(merged),as:UTF8.self).contains("keep"))}
    func testProjectSaveOpenMigrationAndFutureFieldPreservation()async throws{
        let dir=try directory();defer{try? FileManager.default.removeItem(at:dir)};let url=dir.appendingPathComponent("p.fusionproject"),m=FusionManifest(width:100,height:100,tileEdge:128,quality:.maximum,aiMode:.off,sources:[])
        _ = try FusionProjectDocument.create(directory:url,manifest:m);let path=url.appendingPathComponent("manifest.json");var object=try JSONSerialization.jsonObject(with:Data(contentsOf:path)) as! [String:Any];object["formatVersion"]=0;object["futureExtension"]=["preserve":true];try JSONSerialization.data(withJSONObject:object).write(to:path)
        let doc=try FusionProjectDocument.open(directory:url);try await doc.save();let reopened=try FusionProjectDocument.open(directory:url);let version=await reopened.manifest.formatVersion;XCTAssertEqual(version,1);XCTAssertTrue(String(decoding:try Data(contentsOf:path),as:UTF8.self).contains("futureExtension"))
        object["formatVersion"]=99;try JSONSerialization.data(withJSONObject:object).write(to:path);XCTAssertThrowsError(try FusionProjectDocument.open(directory:url))
    }
    func testProjectMissingSourceAndRelinkIdentity()async throws{
        let dir=try directory();defer{try? FileManager.default.removeItem(at:dir)};let original=dir.appendingPathComponent("source.tif"),moved=dir.appendingPathComponent("moved.tif"),d=try TileDescriptor(width:33,height:25),writer=try TIFFOutputWriter(output:original,width:33,height:25,blockEdge:128);try writer.write(SyntheticTileProvider.make(d));_ = try writer.finish();let source=try TechnicalHash.source(original),doc=try FusionProjectDocument.create(directory:dir.appendingPathComponent("p.fusionproject"),manifest:FusionManifest(width:33,height:25,tileEdge:128,quality:.maximum,aiMode:.off,sources:[source]));try FileManager.default.moveItem(at:original,to:moved);let missing=try await doc.availability(sourceIndex:0);XCTAssertEqual(missing,.missing);try await doc.relink(sourceIndex:0,to:moved);let available=try await doc.availability(sourceIndex:0);XCTAssertEqual(available,.available);try Data([1,2,3]).write(to:moved);let mismatch=try await doc.availability(sourceIndex:0);XCTAssertEqual(mismatch,.hashMismatch)
    }
    func testProjectRejectsImpossibleSummaryCounters()throws {
        let dir=try directory();defer{try? FileManager.default.removeItem(at:dir)}
        var m=FusionManifest(width:1,height:1,tileEdge:1,quality:.maximum,aiMode:.off,sources:[])
        m.complete=true;m.report.pixelCount=UInt64.max;m.report.hardOwnership=UInt64.max
        let url=dir.appendingPathComponent("bad.fusionproject");_ = try FusionProjectDocument.create(directory:url,manifest:m)
        XCTAssertThrowsError(try FusionProjectDocument.open(directory:url))
    }
    func testActualProjectAndLocalEditRoundTrip()async throws{
        let dir=try directory();defer{try? FileManager.default.removeItem(at:dir)};let source=dir.appendingPathComponent("source.tif"),output=dir.appendingPathComponent("output.tif"),project=dir.appendingPathComponent("p.fusionproject"),w=2049,h=193
        let writer=try TIFFOutputWriter(output:source,width:w,height:h,blockEdge:1024)
        for x in stride(from:0,to:w,by:1024){let d=try TileDescriptor(x:x,width:min(1024,w-x),height:h);try writer.write(SyntheticTileProvider.make(d))};_ = try writer.finish()
        let workflow=FusionWorkflow(),(doc,report)=try await workflow.run(inputs:[source],output:output,projectURL:project,suppliedTransforms:[SimilarityTransform()]);XCTAssertTrue(report.sourceFaithful.sourceFaithful)
        let untouched=try await doc.preview(region:TileDescriptor(x:1500,width:64,height:64)).0.rgba,region=PixelRegion(x:200,y:80,width:16,height:16)
        let result=try await workflow.edit(project:doc,constraints:[OwnershipConstraint(region:region,action:.reference)],affected:region)
        XCTAssertEqual(result.recomputedTiles,1);XCTAssertLessThan(result.recomputedPixels,UInt64(w*h))
        let now=try await doc.inspect(x:205,y:85);XCTAssertEqual(now.mode,.manualOverride);XCTAssertTrue(now.manualEdit)
        let after=try await doc.preview(region:TileDescriptor(x:1500,width:64,height:64)).0.rgba;XCTAssertEqual(after,untouched)
        let reopened=try FusionProjectDocument.open(directory:project);let available=try await reopened.availability(sourceIndex:0,verifyHash:false);XCTAssertEqual(available,.available);let count=await reopened.manifest.overrides.count;XCTAssertEqual(count,1)
        let edited=dir.appendingPathComponent("edited.tif");_ = try await workflow.export(project:reopened,to:edited)
        let companion=try CanonicalJSON.read(AuditCompanion.self,url:edited.deletingPathExtension().appendingPathExtension("fusion.json"));XCTAssertEqual(companion.outputSHA256,try TechnicalHash.file(edited));XCTAssertFalse(String(decoding:try CanonicalJSON.data(companion),as:UTF8.self).contains(dir.path))
    }
    func testAutomaticHardOwnershipProvenance()throws {
        let d=try TileDescriptor(width:17,height:13),p=try ProductionMetalPipeline(productEvidence:true),source=try SyntheticTileProvider.make(d),tile=try ProductionTile(core:d,imageWidth:17,imageHeight:13,quality:.maximum)
        try p.begin(region:d,quality:.maximum);for i in 0..<2{try p.focus(tile:source,region:d,sourceWidth:17,sourceHeight:13,index:i)}
        try p.installOwnershipFixture(scores:Array(repeating:SIMD4(100,1,0,100),count:d.pixelCount),indices:Array(repeating:SIMD4(0,1,1,0),count:d.pixelCount),uncertainty:Array(repeating:.zero,count:d.pixelCount));try p.depth()
        for i in 0..<2{try p.fuse(tile:source,region:d,sourceWidth:17,sourceHeight:13,index:i)};_ = try p.finish(tile:tile)
        let e=try p.productEvidence(tile:tile,registrationConfidence:1,aiEnabled:false);XCTAssertTrue(e.words.allSatisfy{PixelProvenance(word:$0).mode == .hardOwnership && PixelProvenance(word:$0).primarySource==0})
    }
    func testExcludeSourceHonorsCandidateConstraint()throws {
        let d=try TileDescriptor(width:33,height:25),p=try ProductionMetalPipeline(productEvidence:true),source=try SyntheticTileProvider.make(d),tile=try ProductionTile(core:d,imageWidth:33,imageHeight:25,quality:.maximum)
        try p.begin(region:d,quality:.maximum);try p.installConstraints([OwnershipConstraint(region:PixelRegion(x:0,y:0,width:33,height:25),action:.exclude(0))],region:d,sourceCount:2)
        for i in 0..<2{try p.focus(tile:source,region:d,sourceWidth:33,sourceHeight:25,index:i)};try p.depth();try p.installMotionFixture(Array(repeating:SIMD4(0.9999,0,0.99,0),count:d.pixelCount))
        for i in 0..<2{try p.fuse(tile:source,region:d,sourceWidth:33,sourceHeight:25,index:i)};_ = try p.finish(tile:tile)
        let e=try p.productEvidence(tile:tile,registrationConfidence:1,aiEnabled:true);XCTAssertTrue(e.words.allSatisfy{PixelProvenance(word:$0).primarySource==1 && PixelProvenance(word:$0).mode != .aiDeghostOwnership})
    }
    func testMissingManualSourceRejectsInsteadOfIgnoringEdit()throws {
        let d=try TileDescriptor(width:17,height:13),p=try ProductionMetalPipeline(productEvidence:true),source=try SyntheticTileProvider.make(d),tile=try ProductionTile(core:d,imageWidth:17,imageHeight:13,quality:.maximum)
        try p.begin(region:d,quality:.maximum);try p.installConstraints([OwnershipConstraint(region:PixelRegion(x:0,y:0,width:17,height:13),action:.source(1))],region:d,sourceCount:2)
        try p.focus(tile:source,region:d,sourceWidth:17,sourceHeight:13,index:0);try p.focus(tile:source,region:d,transform:SimilarityTransform(tx:10000),sourceWidth:17,sourceHeight:13,index:1);try p.depth()
        try p.fuse(tile:source,region:d,sourceWidth:17,sourceHeight:13,index:0);try p.fuse(tile:source,region:d,transform:SimilarityTransform(tx:10000),sourceWidth:17,sourceHeight:13,index:1);XCTAssertThrowsError(try p.finish(tile:tile))
    }

}
