import Foundation
import Metal
import QuartzCore

public struct ProductionDiagnostics: Sendable {
    public let scores:[Float],candidates:[UInt32],confidence:[Float],labels:[UInt32],floatRGB:[Float]
}
public struct ProductionTiming: Codable, Sendable {
    public var upload=0.0,focus=0.0,depth=0.0,fusion=0.0,readback=0.0
    public init(){}
}
// One owner, one region, one outstanding command buffer. No allocation is indexed
// by source count. The stack actor applies admission/backpressure before calling.
public final class ProductionMetalPipeline {
    private struct Parameters { var size=SIMD4<UInt32>(0,0,0,0),value=SIMD4<Float>(0,0,0,0),map0=SIMD4<Float>(0,0,0,0),map1=SIMD4<Float>(0,0,0,0) }
    public let context:MetalContext
    private let counters:BatchCounterTiming?
    public var kernelTiming:[String:Double]{counters?.seconds ?? [:]}
    private let pipelines:[String:any MTLComputePipelineState]
    private var buffers:[String:any MTLBuffer]=[:],shape=(0,0),pyramidSizes:[(Int,Int)]=[]
    private var quality=StackQuality.maximum
    public private(set) var timing=ProductionTiming(),peakMetalBytes:UInt64=0
    private var lastScores:[Float]=[] // Explicit debug export only; empty during production.
    public init(detailedTiming:Bool=false) throws {
        context=try MetalContext();counters=detailedTiming ? BatchCounterTiming(device:context.device):nil
        guard let url=Bundle.module.url(forResource:"Production",withExtension:"metal",subdirectory:"Kernels") else { throw NativeError.resource("Missing production shaders") }
        let options=MTLCompileOptions();if #available(macOS 15,iOS 18,*){options.mathMode = .safe;options.mathFloatingPointFunctions = .precise}else{options.fastMathEnabled=false}
        // Separate adds/multiplies track OpenCV's Float32 paths; no fast contraction.
        let library=try context.device.makeLibrary(source:String(contentsOf:url,encoding:.utf8),options:options)
        var states:[String:any MTLComputePipelineState]=[:]
        for name in ["Warp","Erode","Moments","Mixed","Gaussian","Tensor","Noise","Evidence","Score","Clear","Top","Invalidate","Depth","Cleanup","Mask","Weights","Down","Accumulate","Owned","Normalize","Reconstruct","Final","MotionFeatures","MergeMotion","MotionOwnership"] {
            states[name]=try context.device.makeComputePipelineState(function:library.makeFunction(name:"fs"+name)!)
        };pipelines=states
    }
    private func buffer(_ name:String)->any MTLBuffer { buffers[name]! }
    private func dispatch(_ c:any MTLCommandBuffer,_ name:String,_ binds:[Int:String],_ p:Parameters,_ weights:[Float]?=nil) throws {
        guard let e=(counters.map{c.makeComputeCommandEncoder(descriptor:$0.pass(name:name))} ?? c.makeComputeCommandEncoder()),let pipeline=pipelines[name] else { throw NativeError.resource("GPU encoder unavailable") }
        e.setComputePipelineState(pipeline);for(i,name)in binds{e.setBuffer(buffer(name),offset:0,index:i)}
        var args=p;e.setBytes(&args,length:MemoryLayout<Parameters>.stride,index:5)
        if let weights { weights.withUnsafeBytes {e.setBytes($0.baseAddress!,length:$0.count,index:2)} }
        e.dispatchThreads(MTLSize(width:Int(p.size.x),height:Int(p.size.y),depth:1),threadsPerThreadgroup:MTLSize(width:pipeline.threadExecutionWidth,height:4,depth:1));e.endEncoding()
    }
    private func command(_ body:(any MTLCommandBuffer)throws->Void)throws->Double {
        try autoreleasepool {
        try Task.checkCancellation();guard let c=context.queue.makeCommandBuffer()else{throw NativeError.resource("Command buffer unavailable")}
        counters?.begin(device:context.device)
        try body(c);c.commit();c.waitUntilCompleted();guard c.status == .completed else {throw NativeError.resource(c.error?.localizedDescription ?? "Metal failed")}
        counters?.resolve(device:context.device)
        return max(0,c.gpuEndTime-c.gpuStartTime)
        }
    }
    private func args(_ w:Int?=nil,_ h:Int?=nil)->Parameters { var p=Parameters();p.size.x=UInt32(w ?? shape.0);p.size.y=UInt32(h ?? shape.1);return p }
    private func clear(_ c:any MTLCommandBuffer,_ name:String,_ value:Float=0,_ w:Int?=nil,_ h:Int?=nil)throws {var p=args(w,h);p.value.x=value;try dispatch(c,"Clear",[0:name],p)}
    private func gaussian(_ c:any MTLCommandBuffer,_ input:String,_ output:String,_ radius:Int,_ sigma:Double?=nil)throws {
        let g=Self.gaussian(radius:radius,sigma:sigma ?? max(Double(radius)/3,0.5));var p=args();p.value.x=Float(radius)
        try dispatch(c,"Gaussian",[0:input,1:"temp"],p,g);p.value.y=1;try dispatch(c,"Gaussian",[0:"temp",1:output],p,g)
    }
    public static func gaussian(radius:Int,sigma:Double)->[Float] {
        if radius==0{return[1]};let values=(-radius...radius).map{exp(-Double($0*$0)/(2*sigma*sigma))},sum=values.reduce(0,+);return values.map{Float($0/sum)}
    }
    private static func noiseGain(radius:Int,sigma:Double)->Float {
        let raw=(-radius...radius).map{exp(-Double($0*$0)/(2*sigma*sigma))},sum=raw.reduce(0,+),g=raw.map{$0/sum}
        func convolve(_ k:[Double])->[Double]{var out=[Double](repeating:0,count:g.count+2);for i in g.indices{for j in 0..<3{out[i+j]+=g[i]*k[j]}};return out}
        let d=convolve([-1,0,1]),s=convolve([1,2,1]);return Float(2*d.reduce(0){$0+$1*$1}*s.reduce(0){$0+$1*$1})
    }
    public static func plannedBytes(width:Int,height:Int,quality:StackQuality)->UInt64 {
        var w=width,h=height,levels=0
        for _ in 0...quality.levels{levels+=w*h;w=(w+1)/2;h=(h+1)/2}
        return UInt64(width*height*16*23+levels*16*4)+32*1048576+2*1048576+64*1048576
    }
    public func begin(region:TileDescriptor,quality:StackQuality)throws {
        self.quality=quality;timing=ProductionTiming();lastScores=[];counters?.reset()
        if shape != (region.width,region.height)||pyramidSizes.count != quality.levels+1 {
            buffers.removeAll();shape=(region.width,region.height);pyramidSizes=[]
            var w=shape.0,h=shape.1;for _ in 0...quality.levels{pyramidSizes.append((w,h));w=(w+1)/2;h=(h+1)/2}
            let bytes=Self.plannedBytes(width:shape.0,height:shape.1,quality:quality)
            guard bytes<MemoryMonitor.budget(recommended:context.capabilities.recommendedWorkingSet) else{throw NativeError.resource("Production tile exceeds RSS/OS/GPU budget")}
            func alloc(_ name:String,_ count:Int)throws{guard let b=context.device.makeBuffer(length:count,options:.storageModeShared)else{throw NativeError.resource("GPU allocation failed")};buffers[name]=b}
            for name in ["source","validTemp","gray","mixed","stats","tensor","tensorStats","noise","filtered","evidence","aggregated","temp","score","top","indices","labels","depth","mask","weights","reference","owned","output","motion"] {try alloc(name,shape.0*shape.1*16)}
            // Upload capacity is spatially bounded, independent of frame count.
            try alloc("upload",2048*2048*8)
            try alloc("features",5*65536*4);try alloc("probabilities",2*65536*4)
            for(level,s)in pyramidSizes.enumerated(){for prefix in ["rgb","maskP","acc","recon"]{try alloc(prefix+String(level),s.0*s.1*16)}}
        }
        _=try command{c in
            try clear(c,"top",-1);try clear(c,"indices");try clear(c,"gray");try clear(c,"mask");try clear(c,"noise");try clear(c,"reference");try clear(c,"owned");try clear(c,"motion")
            for(i,s)in pyramidSizes.enumerated(){try clear(c,"acc\(i)",0,s.0,s.1)}
        };peakMetalBytes=max(peakMetalBytes,UInt64(context.device.currentAllocatedSize))
    }
    private func upload(_ tile:RGB16Tile,region:TileDescriptor,transform:SimilarityTransform,sourceWidth:Int,sourceHeight:Int,erode:Bool,_ c:any MTLCommandBuffer)throws {
        let start=CACurrentMediaTime();_ = tile.rgba.withUnsafeBytes{memcpy(buffer("upload").contents(),$0.baseAddress!,$0.count)};timing.upload+=CACurrentMediaTime()-start
        var p=args();p.size.z=UInt32(tile.descriptor.width);p.size.w=UInt32(tile.descriptor.height)
        p.value=SIMD4(Float(tile.descriptor.x),Float(tile.descriptor.y),Float(sourceWidth),Float(sourceHeight))
        let inverse=transform.inverse;p.map0=SIMD4(Float(inverse.a),Float(-inverse.b),Float(inverse.tx),Float(region.x));p.map1=SIMD4(Float(inverse.b),Float(inverse.a),Float(inverse.ty),Float(region.y))
        try dispatch(c,"Warp",[0:"upload",1:"source"],p)
        guard erode else { return };p=args();p.value.x=Float(quality.focusSupport);try dispatch(c,"Erode",[0:"source",1:"validTemp"],p);p.value.y=1;try dispatch(c,"Erode",[0:"validTemp",1:"source"],p)
    }
    public func focus(tile:RGB16Tile,region:TileDescriptor,transform:SimilarityTransform = .init(),sourceWidth:Int,sourceHeight:Int,index:Int,exportScore:Bool=false)throws {
        guard index<65536 else{throw NativeError.invalid("Source count exceeds index capacity")}
        timing.focus+=try command{c in
            try upload(tile,region:region,transform:transform,sourceWidth:sourceWidth,sourceHeight:sourceHeight,erode:true,c)
            if index==0{guard let e=c.makeBlitCommandEncoder()else{throw NativeError.resource("Blit unavailable")};e.copy(from:buffer("source"),sourceOffset:0,to:buffer("reference"),destinationOffset:0,size:shape.0*shape.1*16);e.endEncoding()}
            try dispatch(c,"Moments",[0:"source",1:"gray"],args());try clear(c,"score")
            if quality != .standard {
                try dispatch(c,"Mixed",[0:"gray",1:"mixed"],args());try gaussian(c,"mixed","stats",3)
                try dispatch(c,"Tensor",[0:"gray",1:"tensor"],args());try gaussian(c,"tensor","tensorStats",3)
                try dispatch(c,"Noise",[0:"stats",1:"tensorStats",2:"noise"],args())
                let scales:[(Int,Double,Float)]=quality == .maximum ? [(1,0.7,1),(3,1,0.7),(6,2,0.4)]:[(1,0.7,1),(3,1,0.7)]
                for(r,sigma,weight)in scales{
                    try gaussian(c,"gray","filtered",r,sigma);try dispatch(c,"Evidence",[0:"filtered",1:"noise",2:"evidence"],args())
                    try gaussian(c,"evidence","aggregated",r==1 ? 3:6);var p=args();p.value=SIMD4(Self.noiseGain(radius:r,sigma:sigma),weight,0,0)
                    try dispatch(c,"Score",[0:"aggregated",1:"noise",2:"score"],p)
                }
            }else{
                try dispatch(c,"Evidence",[0:"gray",1:"noise",2:"evidence"],args());try gaussian(c,"evidence","aggregated",3)
                var p=args();p.value=SIMD4(0,1,1,0);try dispatch(c,"Score",[0:"aggregated",1:"noise",2:"score"],p)
            }
            try dispatch(c,"Invalidate",[0:"source",1:"score"],args());var p=args();p.value.x=Float(index)
            try dispatch(c,"Top",[0:"score",1:"gray",2:"top",3:"indices",4:"mask"],p)
        }
        if exportScore{lastScores=floats("score",channel:0)}
    }
    public func debugBuffer(_ name:String)->[Float]{let p=buffer(name).contents().assumingMemoryBound(to:Float.self);return Array(UnsafeBufferPointer(start:p,count:shape.0*shape.1*4))}
    public func exportedScore()->[Float]{lastScores}
    public func depth()throws {
        timing.depth+=try command{c in
            try dispatch(c,"Depth",[0:"top",1:"mask",2:"depth"],args());var p=args();p.value.x=quality == .standard ? 0.25:0.2
            try dispatch(c,"Cleanup",[0:"depth",1:"top",2:"indices",3:"labels"],p)
        }
    }
    public func fuse(tile:RGB16Tile,region:TileDescriptor,transform:SimilarityTransform = .init(),sourceWidth:Int,sourceHeight:Int,index:Int)throws {
        timing.fusion+=try command{c in
            try upload(tile,region:region,transform:transform,sourceWidth:sourceWidth,sourceHeight:sourceHeight,erode:false,c)
            var p=args();p.value.x=Float(index);try dispatch(c,"Mask",[0:"labels",1:"source",2:"mask"],p)
            try gaussian(c,"mask","filtered",8);p.value.x=quality == .standard ? 4:5
            try dispatch(c,"Weights",[0:"mask",1:"filtered",2:"depth",3:"source",4:"weights"],p)
            try dispatch(c,"Owned",[0:"source",1:"weights",2:"owned"],args())
            guard let e=c.makeBlitCommandEncoder()else{throw NativeError.resource("Blit unavailable")}
            e.copy(from:buffer("source"),sourceOffset:0,to:buffer("rgb0"),destinationOffset:0,size:shape.0*shape.1*16)
            e.copy(from:buffer("weights"),sourceOffset:0,to:buffer("maskP0"),destinationOffset:0,size:shape.0*shape.1*16);e.endEncoding()
            if quality.levels>0{for level in 1...quality.levels{let s=pyramidSizes[level],prev=pyramidSizes[level-1];var a=args(s.0,s.1);a.size.z=UInt32(prev.0);a.size.w=UInt32(prev.1)
                try dispatch(c,"Down",[0:"rgb\(level-1)",1:"rgb\(level)"],a);try dispatch(c,"Down",[0:"maskP\(level-1)",1:"maskP\(level)"],a)
            }}
            for(level,s)in pyramidSizes.enumerated(){var a=args(s.0,s.1);let next=pyramidSizes[min(level+1,quality.levels)];a.size.z=UInt32(next.0);a.size.w=UInt32(next.1)
                a.value=SIMD4(Float(1<<level),Float(shape.0),level<quality.levels ? 1:0,0)
                try dispatch(c,"Accumulate",[0:"rgb\(level)",1:"rgb\(min(level+1,quality.levels))",2:"maskP\(level)",3:"weights",4:"acc\(level)"],a)
            }
        }
    }
    public func finish(tile:ProductionTile)throws->RGB16Tile {
        timing.fusion+=try command{c in
            for(i,s)in pyramidSizes.enumerated(){try dispatch(c,"Normalize",[0:"acc\(i)"],args(s.0,s.1))}
            guard let e=c.makeBlitCommandEncoder()else{throw NativeError.resource("Blit unavailable")};let last=quality.levels,s=pyramidSizes[last]
            e.copy(from:buffer("acc\(last)"),sourceOffset:0,to:buffer("recon\(last)"),destinationOffset:0,size:s.0*s.1*16);e.endEncoding()
            if last>0{for i in stride(from:last-1,through:0,by:-1){let s=pyramidSizes[i],next=pyramidSizes[i+1];var p=args(s.0,s.1);p.size.z=UInt32(next.0);p.size.w=UInt32(next.1)
                try dispatch(c,"Reconstruct",[0:"acc\(i)",1:"recon\(i+1)",2:"recon\(i)"],p)
            }}
            var p=args();p.value.x=quality == .standard ? 0:1
            try dispatch(c,"Final",[0:"recon0",1:"owned",2:"depth",3:"reference",4:"output"],p)
        }
        let start=CACurrentMediaTime(),d=tile.core,r=tile.region,ptr=buffer("output").contents().assumingMemoryBound(to:UInt16.self)
        var rgba=[UInt16](repeating:0,count:d.pixelCount*4)
        rgba.withUnsafeMutableBufferPointer { out in for y in 0..<d.height{let offset=((y+d.y-r.y)*r.width+d.x-r.x)*4;memcpy(out.baseAddress!+y*d.width*4,ptr+offset,d.width*8)} }
        timing.readback+=CACurrentMediaTime()-start
        return try RGB16Tile(descriptor:d,rgba:rgba)
    }
    func motionFeatures(tile:RGB16Tile,region:TileDescriptor,transform:SimilarityTransform,sourceWidth:Int,sourceHeight:Int)throws->any MTLBuffer {
        _=try command{c in
            try upload(tile,region:region,transform:transform,sourceWidth:sourceWidth,sourceHeight:sourceHeight,erode:false,c)
            var p=args(256,256);p.size.z=UInt32(shape.0);p.size.w=UInt32(shape.1)
            try dispatch(c,"MotionFeatures",[0:"reference",1:"source",2:"depth",3:"features"],p)
        };return buffer("features")
    }
    var motionOutput:any MTLBuffer{buffer("probabilities")}
    func mergeMotion()throws{_=try command{c in try dispatch(c,"MergeMotion",[0:"probabilities",1:"motion"],args())}}
    func applyMotion(mode:AIDeghostMode)throws{_=try command{c in var p=args();p.value.x=mode.threshold;try dispatch(c,"MotionOwnership",[0:"motion",1:"labels",2:"depth"],p)}}
    private func floats(_ name:String,channel:Int)->[Float]{let ptr=buffer(name).contents().assumingMemoryBound(to:SIMD4<Float>.self);return(0..<shape.0*shape.1).map{ptr[$0][channel]}}
    public func diagnostics()->ProductionDiagnostics{
        let n=shape.0*shape.1,idx=buffer("indices").contents().assumingMemoryBound(to:SIMD4<UInt32>.self),rgb=buffer("recon0").contents().assumingMemoryBound(to:SIMD4<Float>.self)
        return ProductionDiagnostics(scores:lastScores,candidates:(0..<n).flatMap{[idx[$0].x,idx[$0].y,idx[$0].z]},confidence:floats("depth",channel:0),labels:(0..<n).map{buffer("labels").contents().assumingMemoryBound(to:SIMD4<UInt32>.self)[$0].w},floatRGB:(0..<n).flatMap{[rgb[$0].x,rgb[$0].y,rgb[$0].z]})
    }
}
