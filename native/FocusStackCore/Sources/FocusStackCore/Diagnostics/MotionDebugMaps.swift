import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

public struct MotionDiagnosticTile:Sendable {
    public let descriptor:TileDescriptor,probability:[Float],mask:[UInt8],confidence:[Float],owners:[UInt32],components:[UInt32]
}
// Developer-only CPU mask readback, opt-in. Preview dimensions are bounded;
// production photographic RGB never travels through this diagnostic path.
final class MotionDebugMapWriter {
    private let directory:URL,width:Int,height:Int,sourceWidth:Int,sourceHeight:Int,registrationConfidence:Double
    private var maps:[String:[UInt8]]
    init(directory:URL,width:Int,height:Int,registrationConfidence:Double)throws {
        guard !FileManager.default.fileExists(atPath:directory.path)else{throw NativeError.invalid("Debug directory already exists")}
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false)
        self.directory=directory;sourceWidth=width;sourceHeight=height;self.registrationConfidence=registrationConfidence
        let scale=min(1,1536.0/Double(max(width,height)));self.width=max(1,Int(Double(width)*scale));self.height=max(1,Int(Double(height)*scale))
        let count=self.width*self.height*4
        maps=Dictionary(uniqueKeysWithValues:["motion_probability","motion_mask","ownership_map","focus_confidence","registration_confidence"].map{($0,[UInt8](repeating:0,count:count))})
    }
    func add(_ tile:MotionDiagnosticTile)throws {
        let d=tile.descriptor
        guard tile.probability.count==d.pixelCount,tile.mask.count==d.pixelCount,tile.confidence.count==d.pixelCount,tile.owners.count==d.pixelCount else{throw NativeError.invalid("Diagnostic tile extent")}
        for py in 0..<height{
            let sy=py*sourceHeight/height
            if sy<d.y||sy>=d.y+d.height{continue}
            for px in 0..<width{
                let sx=px*sourceWidth/width
                if sx<d.x||sx>=d.x+d.width{continue}
                let source=(sy-d.y)*d.width+sx-d.x,index=(py*width+px)*4
                let values:[String:UInt8]=["motion_probability":UInt8(clamping:Int(tile.probability[source]*255)),"motion_mask":tile.mask[source]*255,"focus_confidence":UInt8(clamping:Int(tile.confidence[source]*255)),"registration_confidence":UInt8(clamping:Int(registrationConfidence*255))]
                for(name,value)in values{maps[name]![index]=value;maps[name]![index+1]=value;maps[name]![index+2]=value;maps[name]![index+3]=255}
                let owner=tile.owners[source];maps["ownership_map"]![index]=UInt8((owner*73+40)%256);maps["ownership_map"]![index+1]=UInt8((owner*131+100)%256);maps["ownership_map"]![index+2]=UInt8((owner*197+180)%256);maps["ownership_map"]![index+3]=255
            }
        }
    }
    func finish()throws {
        for(name,bytes)in maps{
            guard let provider=CGDataProvider(data:Data(bytes) as CFData),let image=CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.last.rawValue),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent),let destination=CGImageDestinationCreateWithURL(directory.appendingPathComponent(name+".png") as CFURL,UTType.png.identifier as CFString,1,nil)else{throw NativeError.resource("Debug PNG writer unavailable")}
            CGImageDestinationAddImage(destination,image,nil)
            guard CGImageDestinationFinalize(destination)else{throw NativeError.resource("Debug PNG write failed")}
        }
        let metadata:[String:Any]=["previewWidth":width,"previewHeight":height,"sourceWidth":sourceWidth,"sourceHeight":sourceHeight,"registrationConfidence":registrationConfidence,"note":"Diagnostic 8-bit previews only; photographic RGB16 output is separate. Preview sampling can omit subpixel/fine masks; use tile diagnostics for 100% review."]
        try JSONSerialization.data(withJSONObject:metadata,options:[.prettyPrinted,.sortedKeys]).write(to:directory.appendingPathComponent("diagnostics.json"))
    }
}
