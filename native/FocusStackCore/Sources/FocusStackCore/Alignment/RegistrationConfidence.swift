import Foundation

public struct RegistrationDiagnostics: Codable, Sendable {
    public let phasePeakRatio: Double, competingCorrelationGap: Double, textureVariance: Double
    public let periodicCorrelation: Double, pyramidDisagreementPixels: Double, localAgreement: Double
    public let continuityJumpFraction: Double, registrationConfidence: Double, registrationAmbiguous: Bool
    public let reasons: [String]
}
public struct RegistrationRejected: Error, LocalizedError, Sendable {
    public let diagnostics: RegistrationDiagnostics
    public var errorDescription: String? {
        "Registration ambiguous=\(diagnostics.registrationAmbiguous), confidence=\(String(format:"%.3f",diagnostics.registrationConfidence)): " + diagnostics.reasons.joined(separator:"; ")
    }
}
struct PhasePeak { let x: Float, y: Float, value: Float }
struct PhaseEvidence {
    let peaks: [PhasePeak]
    var ratio: Double { Double(peaks[0].value)/max(Double(peaks.dropFirst().first?.value ?? 0),1e-12) }
}
// Independent image evidence, computed only on bounded registration reductions.
// A weak continuity prior never decides ownership or substitutes for image evidence.
enum RegistrationConfidence {
    static func correlation(_ ref: ReducedImage, _ current: ReducedImage, inverse: SimilarityTransform,
                            region: (Int,Int,Int,Int)? = nil, step: Int = 2) -> Double {
        let r=region ?? (2,ref.width-2,2,ref.height-2)
        var a=0.0,b=0.0,aa=0.0,bb=0.0,ab=0.0,n=0.0
        guard r.1>r.0,r.3>r.2 else{return 0}
        for y in stride(from:r.2,to:r.3,by:step){for x in stride(from:r.0,to:r.1,by:step){
            let p=inverse.point(x:Double(x),y:Double(y))
            if p.0<1 || p.1<1 || p.0>Double(current.width-2) || p.1>Double(current.height-2){continue}
            let u=Double(ref.pixels[y*ref.width+x]),v=Double(current.sample(x:Float(p.0),y:Float(p.1)))
            a+=u;b+=v;aa+=u*u;bb+=v*v;ab+=u*v;n+=1
        }}
        guard n>=64 else{return 0}
        return max(-1,min(1,(ab-a*b/n)/max(sqrt(max(aa-a*a/n,0)*max(bb-b*b/n,0)),1e-12)))
    }
    static func highpass(_ image:ReducedImage)throws->ReducedImage {
        var values=image.pixels
        for y in 0..<image.height{for x in 0..<image.width{
            var mean:Float=0
            for dy in -2...2{for dx in -2...2{mean+=image.sample(x:Float(x+dx),y:Float(y+dy))}}
            values[y*image.width+x]=image.pixels[y*image.width+x]-mean/25
        }}
        return try ReducedImage(width:image.width,height:image.height,pixels:values)
    }
    static func inspect(reference:ReducedImage,candidate:ReducedImage,transform:SimilarityTransform,
                        fullWidth:Int,fullHeight:Int,phase:PhaseEvidence,pyramid:[SimilarityTransform],
                        previous:SimilarityTransform?,finalCorrelation:Double)throws->RegistrationDiagnostics {
        let scale=Double(reference.width)/Double(fullWidth)
        func reduced(_ t:SimilarityTransform)->SimilarityTransform{.init(a:t.a,b:t.b,tx:t.tx*scale,ty:t.ty*scale)}
        let inverse=reduced(transform).inverse,r=try reference.resized(edge:256),c=try candidate.resized(edge:256)
        let coarseScale=Double(r.width)/Double(reference.width),mean=reference.pixels.reduce(0,+)/Float(reference.pixels.count)
        let variance=Double(reference.pixels.reduce(Float(0)){$0+($1-mean)*($1-mean)}/Float(reference.pixels.count))
        let hp=try highpass(r)
        var periodic=0.0,aliasOffsets=[(Double,Double)]()
        // Ignore adjacent blur-correlated pixels; exact/repeated structures have
        // distant high-pass aliases. No scene-specific marketing/chip assumptions.
        for shift in 4...min(80,min(r.width,r.height)/3){
            let horizontal=correlation(hp,hp,inverse:.init(tx:Double(shift)),step:2),vertical=correlation(hp,hp,inverse:.init(ty:Double(shift)),step:2)
            periodic=max(periodic,horizontal,vertical)
            if horizontal>=0.985{aliasOffsets.append((Double(shift),0))}
            if vertical>=0.985{aliasOffsets.append((0,Double(shift)))}
        }
        let best=correlation(r,c,inverse:.init(a:inverse.a,b:inverse.b,tx:inverse.tx*coarseScale,ty:inverse.ty*coarseScale))
        var alternative = -1.0
        for peak in phase.peaks {
            let t=SimilarityTransform(tx:Double(-peak.x),ty:Double(-peak.y))
            if hypot(t.tx-inverse.tx*coarseScale,t.ty-inverse.ty*coarseScale)>3 {alternative=max(alternative,correlation(r,c,inverse:t))}
        }
        let displacement=hypot(transform.tx,transform.ty)/Double(max(fullWidth,fullHeight))
        if displacement>0.01 {alternative=max(alternative,correlation(r,c,inverse:.init()))}
        var periodicCompetitor = -1.0
        for offset in aliasOffsets {for sign in [-1.0,1.0]{let alias=SimilarityTransform(a:inverse.a,b:inverse.b,tx:inverse.tx*coarseScale+offset.0*sign,ty:inverse.ty*coarseScale+offset.1*sign);periodicCompetitor=max(periodicCompetitor,correlation(r,c,inverse:alias))}}
        let gap=max(-2,best-max(alternative,periodicCompetitor))
        let localRef=try reference.resized(edge:512),localCurrent=try candidate.resized(edge:512)
        let localScale=Double(localRef.width)/Double(reference.width),localInverse=SimilarityTransform(a:inverse.a,b:inverse.b,tx:inverse.tx*localScale,ty:inverse.ty*localScale)
        var agree=0.0,regions=0.0
        for row in 0..<3{for col in 0..<3{
            let region=(max(2,col*localRef.width/3),min(localRef.width-2,(col+1)*localRef.width/3),max(2,row*localRef.height/3),min(localRef.height-2,(row+1)*localRef.height/3))
            let center=correlation(localRef,localCurrent,inverse:localInverse,region:region),values=[(-2.0,0.0),(2,0),(0,-2),(0,2)].map{dx,dy in correlation(localRef,localCurrent,inverse:.init(a:localInverse.a,b:localInverse.b,tx:localInverse.tx+dx,ty:localInverse.ty+dy),region:region)}
            if center>=max(0.2,finalCorrelation*0.5) && center>=(values.max() ?? 0)-0.02 {agree+=1};regions+=1
        }}
        let agreement=agree/max(regions,1)
        var disagreement=0.0
        if let last=pyramid.last {for t in pyramid.dropLast(){for point in [(0.25,0.25),(0.75,0.75)] {
            let a=t.point(x:point.0*Double(fullWidth),y:point.1*Double(fullHeight)),b=last.point(x:point.0*Double(fullWidth),y:point.1*Double(fullHeight))
            disagreement=max(disagreement,hypot(a.0-b.0,a.1-b.1)*scale)
        }}}
        let jump=previous.map{hypot(transform.tx-$0.tx,transform.ty-$0.ty)/Double(max(fullWidth,fullHeight))} ?? 0
        var reasons=[String]()
        if variance<1e-5 {reasons.append("insufficient texture")}
        // A nearly exact warp can distinguish smooth periodic aliases through its
        // residual energy. Exact repeated textures cannot pass this ratio test.
        let residualDistinguishesAlias = best>0.98 && 1-periodicCompetitor>1e-5 && (1-best)<0.2*(1-periodicCompetitor)
        if periodic>=0.985 && best-periodicCompetitor<0.015 && !residualDistinguishesAlias {reasons.append("repeated high-pass texture (alias correlation \(String(format:"%.4f",periodic)))")}
        if phase.ratio<1.25 && gap<0.025 {reasons.append("competing phase hypotheses")}
        if displacement>0.02 && gap<0.02 {reasons.append("large shift has similarly plausible alternative")}
        if disagreement>5 {reasons.append("image pyramid transforms disagree")}
        if agreement<0.55 {reasons.append("local regions disagree")}
        if jump>0.025 && (phase.ratio<2 || gap<0.025 || agreement<0.8){reasons.append("weak image evidence for focus-frame transform jump")}
        let confidence=max(0,min(1,(max(0,finalCorrelation)*0.45+agreement*0.3+min(1,max(0,phase.ratio-1))*0.15+min(1,max(0,gap)/0.1)*0.1)*(reasons.isEmpty ? 1:0.2)))
        return RegistrationDiagnostics(phasePeakRatio:phase.ratio,competingCorrelationGap:gap,textureVariance:variance,periodicCorrelation:periodic,pyramidDisagreementPixels:disagreement,localAgreement:agreement,continuityJumpFraction:jump,registrationConfidence:confidence,registrationAmbiguous:!reasons.isEmpty,reasons:reasons)
    }
}
