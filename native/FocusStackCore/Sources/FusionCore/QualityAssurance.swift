import Foundation

public enum ArtifactType:String,Codable,Sendable,CaseIterable {
    case ghosting,doubleEdges,brightHalo,darkHalo,registrationDiscontinuity,suspiciousSourceTransition,motionLeakage,lowConfidenceOwnership,focusGap,clippingExposure,possibleTileSeam
}
public struct ArtifactFinding:Codable,Sendable,Identifiable {
    public var id:String,type:ArtifactType,boundingRegion:PixelRegion,severity:Double,confidence:Double,evidence:String,relatedSources:[Int]
    public var reviewed=false,ignored=false
    public init(id:String,type:ArtifactType,boundingRegion:PixelRegion,severity:Double,confidence:Double,evidence:String,relatedSources:[Int]){self.id=id;self.type=type;self.boundingRegion=boundingRegion;self.severity=severity;self.confidence=confidence;self.evidence=evidence;self.relatedSources=relatedSources}
}
public struct CoverageSummary:Codable,Sendable {
    public var evaluatedPixels:UInt64=0,adequateEvidencePixels:UInt64=0,lowEvidencePixels:UInt64=0
    public var coveragePercent:Double{evaluatedPixels==0 ? 0:100*Double(adequateEvidencePixels)/Double(evaluatedPixels)}
    public private(set) var calibratedProbability=false
    public private(set) var interpretation="Absolute noise-adjusted encoded-luminance focus evidence; uncalibrated, low texture and blur can be indistinguishable. Missing detail is never generated."
    public init(){}
    public mutating func merge(_ other:Self){evaluatedPixels+=other.evaluatedPixels;adequateEvidencePixels+=other.adequateEvidencePixels;lowEvidencePixels+=other.lowEvidencePixels}
}
public enum ArtifactSentinel {
    /// Evidence-only bounded review proposals; never changes final pixels.
    public static func inspect(_ tile:ProductEvidenceTile,output:RGB16Tile)->[ArtifactFinding] {
        let d=tile.descriptor;var findings=[ArtifactFinding]()
        let types:[(UInt16,ArtifactType,String)]=[(1,.focusGap,"Low absolute focus evidence; absence of focused detail is not proven"),(2,.lowConfidenceOwnership,"Weak top-candidate separation"),(4,.registrationDiscontinuity,"Global registration confidence below review threshold"),(8,.motionLeakage,"High model motion probability outside selected motion ownership"),(16,.brightHalo,"Reconstruction luminance above streamed source range"),(32,.darkHalo,"Reconstruction luminance below streamed source range"),(64,.clippingExposure,"Output contains a zero or saturated encoded channel")]
        for y in stride(from:0,to:d.height,by:64){for x in stride(from:0,to:d.width,by:64){
            let w=min(64,d.width-x),h=min(64,d.height-y);var counts=[Int](repeating:0,count:7),related=Set<Int>(),transition=0,seam=0,doubleEdge=0
            for yy in y..<y+h{for xx in x..<x+w{let k=yy*d.width+xx,word=tile.words[k],flags=UInt16(word.w>>24);if related.count<8{related.insert(Int(word.x&65535))}
                if flags != 0{for i in 0..<7{counts[i]+=Int((flags>>i)&1)}}
                if xx>0,word.x&65535 != tile.words[k-1].x&65535,word.z&255<51{transition+=1}
                if xx>1 && xx<d.width-1 {
                    let delta=abs(Int(output.rgba[k*4])-Int(output.rgba[(k-1)*4])),next=abs(Int(output.rgba[(k+1)*4])-Int(output.rgba[k*4]))
                    if delta>8000 && next>8000 && (flags&8 != 0){doubleEdge+=1}
                    if (xx==1||xx==d.width-2) && delta>12000 && word.z&255<51{seam+=1}
                }
            }}
            let region=PixelRegion(x:d.x+x,y:d.y+y,width:w,height:h)
            func append(_ type:ArtifactType,_ count:Int,_ explanation:String){let fraction=Double(count)/Double(w*h);guard fraction>0.08 else{return};findings.append(ArtifactFinding(id:"\(d.x+x)-\(d.y+y)-\(type.rawValue)",type:type,boundingRegion:region,severity:min(1,fraction),confidence:0.5,evidence:explanation+"; heuristic review proposal",relatedSources:related.sorted()))}
            for(i,item)in types.enumerated(){append(item.1,counts[i],item.2)}
            append(.suspiciousSourceTransition,transition,"Rapid source changes with ambiguous focus")
            append(.doubleEdges,doubleEdge,"Adjacent strong gradients with unowned model motion")
            append(.ghosting,doubleEdge,"Same double-edge/motion evidence; not an independent detector")
            append(.possibleTileSeam,seam,"Strong gradient near tile border with ambiguous ownership; natural edges may trigger")
        }}
        return Array(findings.sorted{$0.severity==$1.severity ? $0.id<$1.id:$0.severity>$1.severity}.prefix(64))
    }
}
