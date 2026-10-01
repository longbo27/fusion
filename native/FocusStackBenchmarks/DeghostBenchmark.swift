import Foundation
import FocusStackCore

// External, bounded fixtures. Each case loads one source tile at a time.
enum DeghostBenchmark {
    static func run(directory:URL,metalPackage:URL? = nil)throws {
        let entries=try JSONSerialization.jsonObject(with:Data(contentsOf:directory.appendingPathComponent("manifest.json"))) as! [[String:Any]]
        let session=try MotionInferenceSession(metalPackage:metalPackage),pipeline=try ProductionMetalPipeline()
        let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
        try encoder.encode(session.timing).write(to:directory.appendingPathComponent("backend.json"))
        for entry in entries {
            let name=entry["name"] as! String,dir=directory.appendingPathComponent(name)
            let w=entry["width"] as! Int,h=entry["height"] as! Int,count=entry["sources"] as! Int
            let paths=entry["tiffs"] as? [String],x=entry["x"] as? Int ?? 0,y=entry["y"] as? Int ?? 0
            let iw=entry["imageWidth"] as? Int ?? w,ih=entry["imageHeight"] as? Int ?? h
            let core=try TileDescriptor(x:x,y:y,width:w,height:h),tile=try ProductionTile(core:core,imageWidth:iw,imageHeight:ih,quality:.maximum)
            let transforms=(entry["transforms"] as? [[String:Double]])?.map{SimilarityTransform(a:$0["a"]!,b:$0["b"]!,tx:$0["tx"]!,ty:$0["ty"]!)} ?? (0..<count).map{_ in SimilarityTransform()}
            func source(_ i:Int)throws->RGB16Tile {
                if let paths{return try LibTIFFTileProvider(url:URL(fileURLWithPath:paths[i])).readSync(tile.sourceROI(transform:transforms[i],width:iw,height:ih))}
                let rgba=try Data(contentsOf:dir.appendingPathComponent("source\(i).u16")).withUnsafeBytes{Array($0.bindMemory(to:UInt16.self))}
                return try RGB16Tile(descriptor:core,rgba:rgba)
            }
            if let paths {let reference=try LibTIFFTileProvider(url:URL(fileURLWithPath:paths[0])).readSync(core);try reference.rgba.withUnsafeBytes{try Data($0).write(to:dir.appendingPathComponent("source0.u16"))}}
            for mode in AIDeghostMode.allCases {
                try pipeline.begin(region:tile.region,quality:.maximum)
                for i in 0..<count{try pipeline.focus(tile:source(i),region:tile.region,transform:transforms[i],sourceWidth:iw,sourceHeight:ih,index:i)}
                try pipeline.depth()
                if mode == .off,entry["ownershipAudit"] as? Bool == true {
                    for name in ["top","indices","depth","uncertainty","labels"]{try pipeline.debugBuffer(name).withUnsafeBytes{try Data($0).write(to:dir.appendingPathComponent("audit-"+name+".raw"))}}
                    let region=["x":tile.region.x,"y":tile.region.y,"width":tile.region.width,"height":tile.region.height]
                    try JSONSerialization.data(withJSONObject:region).write(to:dir.appendingPathComponent("audit-region.json"))
                }
                try session.apply(to:pipeline,region:tile.region,mode:mode)
                for i in 0..<count{try pipeline.fuse(tile:source(i),region:tile.region,transform:transforms[i],sourceWidth:iw,sourceHeight:ih,index:i)}
                let output=try pipeline.finish(tile:tile),maps=pipeline.motionDiagnostics(tile:tile),prefix=mode.rawValue
                func save<T>(_ a:[T],_ ext:String)throws{try a.withUnsafeBytes{try Data($0).write(to:dir.appendingPathComponent(prefix+ext))}}
                try save(output.rgba,".u16");try save(maps.probability,".probability.f32");try save(maps.mask,".mask.u8");try save(maps.owners,".owners.u32");try save(maps.confidence,".confidence.f32");try save(maps.components,".components.u32")
                if paths != nil {
                    let d=try TileDescriptor(width:w,height:h),writer=try TIFFOutputWriter(output:dir.appendingPathComponent(prefix+".tif"),width:w,height:h,blockEdge:1024,metadata:LibTIFFTileProvider(url:URL(fileURLWithPath:paths![0])).metadata())
                    try writer.write(RGB16Tile(descriptor:d,rgba:output.rgba));_ = try writer.finish()
                }
                print("\(name) \(mode.rawValue): motion pixels \(maps.mask.reduce(0){$0+Int($1)})/\(core.pixelCount)");fflush(stdout)
            }
        }
        print("Backend \(session.timing.backend.rawValue), calibrated warm \(session.timing.warmMS) ms; RSS \(MemoryMonitor.snapshot().lifetimePeakBytes), Metal \(pipeline.peakMetalBytes)")
    }
}
