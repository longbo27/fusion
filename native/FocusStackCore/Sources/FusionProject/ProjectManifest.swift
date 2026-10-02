import Foundation
import FusionCore
import FusionAI

public enum ProcessingOperation:String,Codable,Sendable {case `import`,alignment,focusAnalysis,motionAnalysis,aiOwnership,fusion,manualOwnershipEdit,qa,export,review,relink}
public struct ProcessingNode:Codable,Sendable,Identifiable {
    public var id:UUID,operation:ProcessingOperation,parameters:JSONValue,invalidatedRegions:[PixelRegion]
    public init(operation:ProcessingOperation,parameters:JSONValue = .object([:]),invalidatedRegions:[PixelRegion]=[]){id=UUID();self.operation=operation;self.parameters=parameters;self.invalidatedRegions=invalidatedRegions}
}
public struct FusionManifest:Codable,Sendable {
    public var formatVersion=1,engineVersion="FocusStack-3.0-foundation",AIModelVersion:String?,creationDate:Date,lastModifiedDate:Date
    public var sourceFaithfulMode=SourceFaithfulMode.capturedSourcesOnly
    public var width:Int,height:Int,tileEdge:Int,quality:StackQuality,aiMode:AIDeghostMode
    public var sources:[FrameSource],transforms:[SimilarityTransform]=[],registrationConfidence:Double?
    public var provenance:[ProvenanceBlock]=[],overrides:[OwnershipConstraint]=[],findings:[ArtifactFinding]=[],history:[ProcessingNode]=[]
    public var report=SourceFaithfulReport(),coverage=CoverageSummary(),outputURL:URL?,outputSHA256:String?
    public var baseOutputSHA256:String?,replacementHashes:[String:String]=[:]
    public var auditHead:String?,replacementTiles:[String:String]=[:],complete=false
    public var model:ModelGovernance?
    public init(width:Int,height:Int,tileEdge:Int,quality:StackQuality,aiMode:AIDeghostMode,sources:[FrameSource],date:Date=Date()){
        creationDate=date;lastModifiedDate=date;self.width=width;self.height=height;self.tileEdge=tileEdge;self.quality=quality;self.aiMode=aiMode;self.sources=sources
        AIModelVersion=aiMode == .off ? nil:"FocusMotionNetV1";model=aiMode == .off ? nil:ModelGovernance()
    }
}
public enum SourceAvailability:Sendable,Equatable {case available,missing,hashMismatch,unsupported}
public struct AuditCompanion:Codable,Sendable {
    public var schemaVersion=1,engineVersion:String,AIModelVersion:String?,model:ModelGovernance?,sourceFaithful:SourceFaithfulReport
    public var sources:[TechnicalSource],transforms:[SimilarityTransform],registrationConfidence:Double?,quality:StackQuality,aiMode:AIDeghostMode,overrides:[OwnershipConstraint],coverage:CoverageSummary,outputSHA256:String,auditHead:String?
    public private(set) var reproducibility="Recorded decision provenance; cross-hardware bitwise output reproduction is unverified."
    public private(set) var privacy="Source URLs and filenames omitted; technical hashes and IDs retained."
    public struct TechnicalSource:Codable,Sendable {public var id:UUID,size:UInt64,sha256:String,metadataFingerprint:String,colorProfileSHA256:String?}
}
