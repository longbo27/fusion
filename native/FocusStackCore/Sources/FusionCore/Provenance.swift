@_exported import FocusStackCore
import Foundation

public enum ProvenanceMode:UInt8,Codable,Sendable {
    case hardOwnership=1, multibandBlend=2, referenceFallback=3, aiDeghostOwnership=4, manualOverride=5
}
public struct Uncertainty:Codable,Sendable,Equatable {
    public var focusAmbiguity:Double, motionUncertainty:Double?, registrationUncertainty:Double?, ownershipAmbiguity:Double, insufficientCoverage:Double
    public var reviewRisk:Double { max(focusAmbiguity,motionUncertainty ?? 0,registrationUncertainty ?? 0,ownershipAmbiguity,insufficientCoverage) }
    public var status:String { insufficientCoverage>0.8 ? "INSUFFICIENT SOURCE INFORMATION":(reviewRisk>0.7 ? "REVIEW RECOMMENDED":(reviewRisk>0.3 ? "AMBIGUOUS":"CONFIDENT")) }
}
public struct PixelProvenance:Codable,Sendable {
    public let primarySource:Int, secondaryCandidate:Int, thirdCandidate:Int, bestFocusCandidate:Int, mode:ProvenanceMode
    public let focusConfidence:Double, motionProbability:Double?, registrationConfidence:Double?, coverageConfidence:Double
    public let manualEdit:Bool, uncertainty:Uncertainty, artifactFlags:UInt16
    public var primaryContribution:Double? { mode == .multibandBlend ? nil:1 }
    public var contributionDescription:String { mode == .multibandBlend ? "Multiband real-source blend; scalar pixel weights and exhaustive contributors were not retained.":"Hard captured-source ownership (after registration resampling)." }
    public init(word:SIMD4<UInt32>) {
        primarySource=Int(word.x&65535);secondaryCandidate=Int(word.x>>16);thirdCandidate=Int((word.w>>8)&65535);bestFocusCandidate=Int(word.y&65535)
        mode=ProvenanceMode(rawValue:UInt8((word.y>>16)&255)) ?? .multibandBlend
        let status=word.y>>24;manualEdit=status&1 != 0
        focusConfidence=Double(word.z&255)/255;motionProbability=status&4 != 0 ? Double((word.z>>8)&255)/255:nil
        registrationConfidence=status&2==0 ? Double((word.z>>16)&255)/255:nil
        coverageConfidence=Double(word.z>>24)/255
        uncertainty=Uncertainty(focusAmbiguity:1-focusConfidence,motionUncertainty:status&4 != 0 ? Double(word.w&255)/255:nil,registrationUncertainty:registrationConfidence.map{1-$0},ownershipAmbiguity:1-focusConfidence,insufficientCoverage:1-coverageConfidence)
        artifactFlags=UInt16(word.w>>24)
    }
}
public struct SourceFaithfulReport:Codable,Sendable {
    public let mode:SourceFaithfulMode
    public var pixelCount:UInt64=0,hardOwnership:UInt64=0,realSourceBlend:UInt64=0,referenceFallback:UInt64=0,aiOwnership:UInt64=0,manuallyOverridden:UInt64=0,lowConfidence:UInt64=0
    public private(set) var generativePhotographicPixels:UInt64=0
    public init(){mode = .capturedSourcesOnly}
    public var sourceFaithful:Bool { pixelCount>0 && generativePhotographicPixels==0 && hardOwnership+realSourceBlend+referenceFallback+aiOwnership==pixelCount }
    public mutating func add(_ word:SIMD4<UInt32>) {
        pixelCount+=1
        switch (word.y>>16)&255 {case 1,5:hardOwnership+=1;case 3:referenceFallback+=1;case 4:aiOwnership+=1;default:realSourceBlend+=1}
        if word.y>>24&1 != 0{manuallyOverridden+=1}
        if word.z&255<26 || word.z>>24<51{lowConfidence+=1}
    }
    public mutating func merge(_ other:Self){pixelCount+=other.pixelCount;hardOwnership+=other.hardOwnership;realSourceBlend+=other.realSourceBlend;referenceFallback+=other.referenceFallback;aiOwnership+=other.aiOwnership;manuallyOverridden+=other.manuallyOverridden;lowConfidence+=other.lowConfidence}
    public func percentage(_ count:UInt64)->Double { pixelCount==0 ? 0:100*Double(count)/Double(pixelCount) }
}
