import Metal
import Foundation

// Opt-in benchmark instrumentation. Fixed 128 samples; no per-source growth.
final class BatchCounterTiming {
    private let samples:(any MTLCounterSampleBuffer)?
    private var names:[String]=[],start:(cpu:UInt64,gpu:UInt64)=(0,0)
    private(set) var seconds:[String:Double]=[:]
    init(device:any MTLDevice){
        if device.supportsCounterSampling(.atStageBoundary),let set=device.counterSets?.first(where:{$0.name==MTLCommonCounterSet.timestamp.rawValue}){
            let d=MTLCounterSampleBufferDescriptor();d.counterSet=set;d.sampleCount=128;d.storageMode = .shared
            samples=try? device.makeCounterSampleBuffer(descriptor:d)
        }else{samples=nil}
    }
    func begin(device:any MTLDevice){names=[];start=device.sampleTimestamps()}
    func pass(name:String)->MTLComputePassDescriptor {
        let pass=MTLComputePassDescriptor()
        if let samples,names.count<64{pass.sampleBufferAttachments[0].sampleBuffer=samples;pass.sampleBufferAttachments[0].startOfEncoderSampleIndex=names.count*2;pass.sampleBufferAttachments[0].endOfEncoderSampleIndex=names.count*2+1;names.append(name)}
        return pass
    }
    func resolve(device:any MTLDevice){
        let end=device.sampleTimestamps()
        guard let samples,!names.isEmpty,end.cpu>start.cpu,end.gpu>start.gpu,let data=try? samples.resolveCounterRange(0..<names.count*2)else{return}
        let ratio=Double(end.cpu-start.cpu)/Double(end.gpu-start.gpu)/1e9
        for i in names.indices {let a=data.withUnsafeBytes{$0.loadUnaligned(fromByteOffset:i*16,as:UInt64.self)},b=data.withUnsafeBytes{$0.loadUnaligned(fromByteOffset:i*16+8,as:UInt64.self)}
            if a != MTLCounterErrorValue,b != MTLCounterErrorValue,b>a{seconds[names[i],default:0]+=Double(b-a)*ratio}
        }
    }
    func reset(){seconds=[:]}
}
