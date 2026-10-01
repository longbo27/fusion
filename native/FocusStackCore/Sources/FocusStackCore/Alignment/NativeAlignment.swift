import Foundation
import Accelerate
import QuartzCore

public struct ReducedImage:Sendable {
    public let width:Int,height:Int,pixels:[Float]
    public init(width:Int,height:Int,pixels:[Float])throws{guard width>0,height>0,width<=2048,height<=2048,pixels.count==width*height else{throw NativeError.invalid("Invalid bounded registration image")};self.width=width;self.height=height;self.pixels=pixels}
    public static func read(_ provider:LibTIFFTileProvider,maximumEdge:Int=1024)throws->ReducedImage {
        guard maximumEdge>0,maximumEdge<=2048 else{throw NativeError.invalid("Invalid analysis edge")}
        let m=try provider.metadata(),scale=min(1,Double(maximumEdge)/Double(max(m.width,m.height)))
        let w=max(1,Int(Double(m.width)*scale)),h=max(1,Int(Double(m.height)*scale))
        var sums=[Float](repeating:0,count:w*h),counts=[UInt32](repeating:0,count:w*h)
        // Explicit analysis-only RGB16 >> 8, matching V1's registration reducer.
        // Photographic focus/fusion stays uint16/Float32 throughout.
        let readEdge=ApplePlatformMemoryClass.current == .mobile ? 512:1024
        for y in stride(from:0,to:m.height,by:512){for x in stride(from:0,to:m.width,by:readEdge){
            let d=try TileDescriptor(x:x,y:y,width:min(readEdge,m.width-x),height:min(512,m.height-y)),tile=try provider.readSync(d)
            for yy in 0..<d.height {let dy=(y+yy)*h/m.height;for xx in 0..<d.width{
                let dx=(x+xx)*w/m.width,k=dy*w+dx,i=(yy*d.width+xx)*4
                let r=Float(tile.rgba[i]>>8),g=Float(tile.rgba[i+1]>>8),b=Float(tile.rgba[i+2]>>8)
                sums[k]+=(r*0.299+g*0.587+b*0.114).rounded();counts[k]+=1
            }}
        }}
        for i in sums.indices{sums[i]=(sums[i]/Float(max(counts[i],1))).rounded()/255}
        return try ReducedImage(width:w,height:h,pixels:sums)
    }
    func resized(edge:Int)throws->ReducedImage {
        let scale=min(1,Float(edge)/Float(max(width,height))),w=max(1,Int(Float(width)*scale)),h=max(1,Int(Float(height)*scale))
        var p=[Float](repeating:0,count:w*h);for y in 0..<h{for x in 0..<w{p[y*w+x]=sample(x:(Float(x)+0.5)*Float(width)/Float(w)-0.5,y:(Float(y)+0.5)*Float(height)/Float(h)-0.5)}}
        return try ReducedImage(width:w,height:h,pixels:p)
    }
    func sample(x:Float,y:Float)->Float {
        let x=max(0,min(Float(width-1),x)),y=max(0,min(Float(height-1),y)),ix=Int(x),iy=Int(y),fx=x-Float(ix),fy=y-Float(iy)
        let a=pixels[iy*width+ix],b=pixels[iy*width+min(ix+1,width-1)],c=pixels[min(iy+1,height-1)*width+ix],d=pixels[min(iy+1,height-1)*width+min(ix+1,width-1)]
        return (a*(1-fx)+b*fx)*(1-fy)+(c*(1-fx)+d*fx)*fy
    }
    func normalized()throws->ReducedImage {let mean=pixels.reduce(0,+)/Float(pixels.count),variance=pixels.reduce(Float(0)){$0+($1-mean)*($1-mean)}/Float(pixels.count),scale=max(sqrt(variance),0.001);return try ReducedImage(width:width,height:height,pixels:pixels.map{($0-mean)/scale})}
}
public struct AlignmentReport:Codable,Sendable {
    public let transform:SimilarityTransform,correlation:Double,overlap:Double,seconds:Double,method:String
    public let diagnostics:RegistrationDiagnostics
    public var registrationConfidence:Double{diagnostics.registrationConfidence}
    public var registrationAmbiguous:Bool{diagnostics.registrationAmbiguous}
}
public enum NativeAlignment {
    // Apple Accelerate 2D FFT, zero-padded bounded images. Peak is source->reference.
    private static func phase(_ ref:ReducedImage,_ current:ReducedImage)throws->PhaseEvidence{
        let n=1<<Int(ceil(log2(Double(max(ref.width,ref.height))))),count=n*n,logN=vDSP_Length(log2(Double(n)))
        guard let setup=vDSP_create_fftsetup(logN,FFTRadix(kFFTRadix2))else{throw NativeError.resource("FFT setup failed")};defer{vDSP_destroy_fftsetup(setup)}
        var rr=[Float](repeating:0,count:count),ri=rr,cr=rr,ci=rr
        let rmean=ref.pixels.reduce(0,+)/Float(ref.pixels.count),cmean=current.pixels.reduce(0,+)/Float(current.pixels.count)
        for y in 0..<ref.height{for x in 0..<ref.width{let window=Float(0.5-0.5*cos(2*Double.pi*Double(x)/Double(max(ref.width-1,1))))*Float(0.5-0.5*cos(2*Double.pi*Double(y)/Double(max(ref.height-1,1))));rr[y*n+x]=(ref.pixels[y*ref.width+x]-rmean)*window;cr[y*n+x]=(current.pixels[y*current.width+x]-cmean)*window}}
        rr.withUnsafeMutableBufferPointer{r in ri.withUnsafeMutableBufferPointer{im in cr.withUnsafeMutableBufferPointer{c in ci.withUnsafeMutableBufferPointer{cm in
            var a=DSPSplitComplex(realp:r.baseAddress!,imagp:im.baseAddress!),b=DSPSplitComplex(realp:c.baseAddress!,imagp:cm.baseAddress!)
            vDSP_fft2d_zip(setup,&a,1,0,logN,logN,FFTDirection(FFT_FORWARD));vDSP_fft2d_zip(setup,&b,1,0,logN,logN,FFTDirection(FFT_FORWARD))
            for i in 0..<count{let real=r[i]*c[i]+im[i]*cm[i],imag=im[i]*c[i]-r[i]*cm[i],mag=max(hypot(real,imag),1e-9);r[i]=real/mag;im[i]=imag/mag}
            vDSP_fft2d_zip(setup,&a,1,0,logN,logN,FFTDirection(FFT_INVERSE))
        }}}}
        var peaks=[PhasePeak]()
        for _ in 0..<6 {
            let index=rr.indices.max{rr[$0]<rr[$1]}!,x=index%n,y=index/n
            peaks.append(PhasePeak(x:Float(x>n/2 ? x-n:x),y:Float(y>n/2 ? y-n:y),value:rr[index]))
            for dy in -4...4{for dx in -4...4{rr[((y+dy+n)%n)*n+(x+dx+n)%n] = -Float.greatestFiniteMagnitude}}
        }
        return PhaseEvidence(peaks:peaks)
    }
    private static func solve(_ h:[Double],_ rhs:[Double])->[Double]? {
        var a=(0..<4).map{i in Array(h[i*4..<i*4+4])+[rhs[i]]}
        for i in 0..<4{let pivot=(i..<4).max{abs(a[$0][i])<abs(a[$1][i])}!;a.swapAt(i,pivot);guard abs(a[i][i])>1e-10 else{return nil};let d=a[i][i];for j in i...4{a[i][j]/=d};for k in 0..<4 where k != i{let f=a[k][i];for j in i...4{a[k][j]-=f*a[i][j]}}};return a.map{$0[4]}
    }
    public static func align(reference:ReducedImage,candidate:ReducedImage,fullWidth:Int,fullHeight:Int,previousTransform:SimilarityTransform? = nil)throws->AlignmentReport {
        guard reference.width==candidate.width,reference.height==candidate.height,reference.width>=16,reference.height>=16,max(reference.width,reference.height)<=1024 else{throw NativeError.invalid("Registration requires equal reduced dimensions, at least 16×16 and at most 1024 per edge")}
        let mean=reference.pixels.reduce(0,+)/Float(reference.pixels.count)
        let variance=Double(reference.pixels.reduce(Float(0)){$0+($1-mean)*($1-mean)}/Float(reference.pixels.count))
        if variance<1e-5{throw RegistrationRejected(diagnostics:RegistrationDiagnostics(phasePeakRatio:0,competingCorrelationGap:0,textureVariance:variance,periodicCorrelation:0,pyramidDisagreementPixels:0,localAgreement:0,continuityJumpFraction:0,registrationConfidence:0,registrationAmbiguous:true,reasons:["insufficient texture"]))}
        let started=CACurrentMediaTime(),coarse=try reference.resized(edge:256),other=try candidate.resized(edge:256),phaseEvidence=try phase(coarse,other),translation=phaseEvidence.peaks[0]
        // Ref->source centered coordinates for optimization. Constrain all iterates
        // to uniform scale/rotation; Huber residuals limit local motion influence.
        var a:Float=1,b:Float=0,tx = -translation.x,ty = -translation.y,lastW=coarse.width
        var pyramid=[SimilarityTransform]()
        for edge in [256,512,1024]{
            let rawR=try reference.resized(edge:edge),rawC=try candidate.resized(edge:edge),r=try rawR.normalized(),c=try rawC.normalized(),ratio=Float(r.width)/Float(lastW)
            tx*=ratio;ty*=ratio;lastW=r.width;let cx=Float(r.width-1)/2,cy=Float(r.height-1)/2,sampling=max(1,r.width/512)
            for _ in 0..<35{
                var h=[Double](repeating:0,count:16),rhs=[Double](repeating:0,count:4),used=0
                for y in stride(from:3,to:r.height-3,by:sampling){for x in stride(from:3,to:r.width-3,by:sampling){
                    let xx=Float(x)-cx,yy=Float(y)-cy,sx=a*xx-b*yy+cx+tx,sy=b*xx+a*yy+cy+ty
                    if sx<2||sy<2||sx>=Float(c.width-3)||sy>=Float(c.height-3){continue}
                    let v=c.sample(x:sx,y:sy),residual=r.pixels[y*r.width+x]-v,gx=(c.sample(x:sx+1,y:sy)-c.sample(x:sx-1,y:sy))*0.5,gy=(c.sample(x:sx,y:sy+1)-c.sample(x:sx,y:sy-1))*0.5
                    let j=[Double(gx*xx+gy*yy),Double(-gx*yy+gy*xx),Double(gx),Double(gy)],weight=Double(min(1,0.5/max(abs(residual),0.0001)))
                    for i in 0..<4{rhs[i]+=j[i]*Double(residual)*weight;for k in 0..<4{h[i*4+k]+=j[i]*j[k]*weight}};used+=1
                }}
                guard used>100,let delta=solve(h,rhs) else{break}
                let da=Float(max(-0.01,min(0.01,delta[0]))),db=Float(max(-0.01,min(0.01,delta[1]))),dx=Float(max(-2,min(2,delta[2]))),dy=Float(max(-2,min(2,delta[3])))
                a+=da;b+=db;tx+=dx;ty+=dy;if abs(da)+abs(db)<1e-6&&abs(dx)+abs(dy)<0.001{break}
                guard hypot(a,b)>=0.8,hypot(a,b)<=1.25,abs(atan2(b,a))<=Float.pi/12 else{throw NativeError.invalid("Native registration exceeds similarity limits")}
            }
            let fullRatio=Double(fullWidth)/Double(r.width)
            let levelInverse=SimilarityTransform(a:Double(a),b:Double(b),tx:Double(tx+cx-a*cx+b*cy)*fullRatio,ty:Double(ty+cy-b*cx-a*cy)*fullRatio)
            pyramid.append(levelInverse.inverse)
        }
        let w=reference.width,h=reference.height,cx=Float(w-1)/2,cy=Float(h-1)/2
        // last stage already has the same <=1024 registration dimensions.
        var sx:Double=0,sy:Double=0,sxx:Double=0,syy:Double=0,sxy:Double=0,n=0
        for y in stride(from:2,to:h-2,by:2){for x in stride(from:2,to:w-2,by:2){let xx=Float(x)-cx,yy=Float(y)-cy,px=a*xx-b*yy+cx+tx,py=b*xx+a*yy+cy+ty;if px<0||py<0||px>Float(w-1)||py>Float(h-1){continue};let u=Double(reference.pixels[y*w+x]),v=Double(candidate.sample(x:px,y:py));sx+=u;sy+=v;sxx+=u*u;syy+=v*v;sxy+=u*v;n+=1}}
        let count=Double(n),correlation=(sxy-sx*sy/count)/max(sqrt((sxx-sx*sx/count)*(syy-sy*sy/count)),1e-12),overlap=count/Double(((w-4+1)/2)*((h-4+1)/2))
        guard correlation>=0.2,overlap>=0.6 else{throw NativeError.invalid("Native registration rejected: correlation \(correlation), overlap \(overlap)")}
        let ratio=Double(fullWidth)/Double(w),inverse=SimilarityTransform(a:Double(a),b:Double(b),tx:Double(tx+cx-a*cx+b*cy)*ratio,ty:Double(ty+cy-b*cx-a*cy)*ratio)
        let diagnostics=try RegistrationConfidence.inspect(reference:reference,candidate:candidate,transform:inverse.inverse,fullWidth:fullWidth,fullHeight:fullHeight,phase:phaseEvidence,pyramid:pyramid,previous:previousTransform,finalCorrelation:correlation)
        guard !diagnostics.registrationAmbiguous else{throw RegistrationRejected(diagnostics:diagnostics)}
        return AlignmentReport(transform:inverse.inverse,correlation:correlation,overlap:overlap,seconds:CACurrentMediaTime()-started,method:"Accelerate phase + Huber similarity + independent ambiguity validation",diagnostics:diagnostics)
    }
}
