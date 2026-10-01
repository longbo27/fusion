import Foundation

public enum StackQuality: String, Codable, CaseIterable, Sendable {
    case standard, high, maximum
    public var levels: Int { switch self { case .standard:0;case .high:3;case .maximum:4 } }
    public var focusSupport: Int { self == .standard ? 4 : 14 }
    public var halo: Int { focusSupport+(self == .standard ? 1:2)+8+4*((1<<levels)-1) }
}
public struct SimilarityTransform: Codable, Sendable, Equatable {
    // Source -> reference, using the same pixel-center coordinates as the reference.
    public let a: Double,b: Double,tx: Double,ty: Double
    public init(a: Double = 1,b: Double = 0,tx: Double = 0,ty: Double = 0){self.a=a;self.b=b;self.tx=tx;self.ty=ty}
    public var inverse: SimilarityTransform { let d=a*a+b*b;return SimilarityTransform(a:a/d,b:-b/d,tx:(-a*tx-b*ty)/d,ty:(b*tx-a*ty)/d) }
    public func point(x:Double,y:Double)->(Double,Double){(a*x-b*y+tx,b*x+a*y+ty)}
}
public struct ProductionTile: Sendable {
    public let core: TileDescriptor, region: TileDescriptor
    public init(core:TileDescriptor,imageWidth:Int,imageHeight:Int,quality:StackQuality) throws {
        let grid=1<<quality.levels,halo=quality.halo
        let x=max(0,core.x-halo)/grid*grid,y=max(0,core.y-halo)/grid*grid
        let right=min(imageWidth,((core.x+core.width+halo+grid-1)/grid)*grid)
        let bottom=min(imageHeight,((core.y+core.height+halo+grid-1)/grid)*grid)
        self.core=core;region=try TileDescriptor(x:x,y:y,width:right-x,height:bottom-y)
    }
    public func sourceROI(transform:SimilarityTransform,width:Int,height:Int)throws->TileDescriptor {
        guard [transform.a,transform.b,transform.tx,transform.ty].allSatisfy(\.isFinite),hypot(transform.a,transform.b)>=0.8,hypot(transform.a,transform.b)<=1.25,abs(transform.tx)<=Double(width)*2,abs(transform.ty)<=Double(height)*2 else{throw NativeError.invalid("Invalid similarity transform for bounded source ROI")}
        let inv=transform.inverse,r=region
        let corners=[inv.point(x:Double(r.x),y:Double(r.y)),inv.point(x:Double(r.x+r.width-1),y:Double(r.y)),inv.point(x:Double(r.x),y:Double(r.y+r.height-1)),inv.point(x:Double(r.x+r.width-1),y:Double(r.y+r.height-1))]
        let x=max(0,min(width-1,Int(floor(corners.map{$0.0}.min()!))-2)),y=max(0,min(height-1,Int(floor(corners.map{$0.1}.min()!))-2))
        let right=min(width,max(x+1,Int(ceil(corners.map{$0.0}.max()!))+3)),bottom=min(height,max(y+1,Int(ceil(corners.map{$0.1}.max()!))+3))
        return try TileDescriptor(x:x,y:y,width:right-x,height:bottom-y)
    }
}
