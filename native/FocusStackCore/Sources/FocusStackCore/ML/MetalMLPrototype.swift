import Foundation
import Metal
import QuartzCore

public struct MetalMLPrototypeReport:Codable,Sendable {
    public let setupMS:Double,tensorSetupMS:Double,dispatchEncodingMS:Double,synchronizationWaitMS:Double,mlGPUMS:Double?,endToEndMS:Double,modelFunction:String,heapBytes:Int,bindings:[String],torchMaxError:Float,minimum:Float,maximum:Float
}
// Metal invokes feedback on its own thread; the lock protects these scalar diagnostics.
private final class MLCommitFeedback: @unchecked Sendable {
    private let lock=NSLock();private var duration:Double?,failure:String?
    let completed=DispatchSemaphore(value:0)
    func record(start:Double,end:Double,error:String?){lock.lock();duration=end>start ? (end-start)*1000:nil;failure=error;lock.unlock();completed.signal()}
    func snapshot()->(Double?,String?){lock.lock();defer{lock.unlock()};return(duration,failure)}
}
public enum MetalMLPrototype {
    #if compiler(>=6.2)
    @available(macOS 26,iOS 26,*)
    public static func run(package:URL,features:[Float],expected:[Float])throws->MetalMLPrototypeReport {
        guard features.count==5*65536,expected.count==2*65536 else{throw NativeError.invalid("Metal ML fixture extent mismatch")}
        let setup=CACurrentMediaTime(),context=try MetalContext(),device=context.device
        guard context.capabilities.machineLearningEncoder,context.capabilities.tensor,
              let queue=device.makeMTL4CommandQueue(),let allocator=device.makeCommandAllocator(),let command=device.makeCommandBuffer(),let event=device.makeSharedEvent()else{throw NativeError.unavailable("Metal 4 ML resources unavailable")}
        let library=try device.makeLibrary(URL:package)
        guard let function=library.functionNames.first else{throw NativeError.invalid("No Metal ML model function")}
        let compiler=try device.makeCompiler(descriptor:MTL4CompilerDescriptor()),fd=MTL4LibraryFunctionDescriptor();fd.library=library;fd.name=function
        let pd=MTL4MachineLearningPipelineDescriptor();pd.machineLearningFunctionDescriptor=fd;let options=MTL4PipelineOptions();options.shaderReflection = .bindingInfo;pd.options=options
        let pipeline=try compiler.makeMachineLearningPipelineState(descriptor:pd)
        let bindings=pipeline.reflection?.bindings ?? []
        let descriptions=bindings.map{"\($0.name) index \($0.index) access \($0.access.rawValue) type \($0.type.rawValue)"}
        guard let inputBinding=bindings.first(where:{$0.access == .readOnly}),let outputBinding=bindings.first(where:{$0.access == .writeOnly})else{throw NativeError.invalid("Unknown model tensor binding contract: \(descriptions)")}
        func extents(_ a:[Int])->MTLTensorExtents{var values=a;return values.withUnsafeMutableBufferPointer{MTLTensorExtents(__rank:$0.count,values:$0.baseAddress!)!}}
        func tensor(_ channels:Int)throws->(any MTLBuffer,any MTLTensor){
            guard let b=device.makeBuffer(length:channels*65536*4,options:.storageModeShared)else{throw NativeError.resource("Tensor backing allocation failed")}
            let d=MTLTensorDescriptor();d.dimensions=extents([256,256,channels,1]);d.strides=extents([1,256,65536,channels*65536]);d.dataType = .float32;d.usage=[.compute,.machineLearning];d.storageMode = .shared
            return(b,try b.makeTensor(descriptor:d,offset:0))
        }
        let tensorStart=CACurrentMediaTime()
        let(inputBuffer,inputTensor)=try tensor(5),(outputBuffer,outputTensor)=try tensor(2)
        let tensorSetupMS=(CACurrentMediaTime()-tensorStart)*1000
        guard let original=device.makeBuffer(length:features.count*4,options:.storageModeShared),let checked=device.makeBuffer(length:expected.count*4,options:.storageModeShared)else{throw NativeError.resource("Fixture buffer allocation failed")}
        _ = features.withUnsafeBytes{memcpy(original.contents(),$0.baseAddress!,$0.count)}
        let tableDescriptor=MTL4ArgumentTableDescriptor();tableDescriptor.maxBufferBindCount=max(inputBinding.index,outputBinding.index)+1
        let table=try device.makeArgumentTable(descriptor:tableDescriptor);table.setResource(inputTensor.gpuResourceID,bufferIndex:inputBinding.index);table.setResource(outputTensor.gpuResourceID,bufferIndex:outputBinding.index)
        let hd=MTLHeapDescriptor();hd.size=max(4096,pipeline.intermediatesHeapSize);hd.storageMode = .private
        guard let heap=device.makeHeap(descriptor:hd)else{throw NativeError.resource("ML intermediates heap unavailable")}
        let rd=MTLResidencySetDescriptor();rd.initialCapacity=5;let residency=try device.makeResidencySet(descriptor:rd)
        residency.addAllocation(inputTensor);residency.addAllocation(outputTensor);residency.addAllocation(heap);residency.commit();queue.addResidencySet(residency)
        let computeLibrary=try device.makeLibrary(source:"#include <metal_stdlib>\nusing namespace metal;\nkernel void bridge(device const float*a [[buffer(0)]],device float*b [[buffer(1)]],uint i [[thread_position_in_grid]]){b[i]=a[i];}",options:nil)
        let compute=try device.makeComputePipelineState(function:computeLibrary.makeFunction(name:"bridge")!)
        func encodeCopy(_ c:any MTLCommandBuffer,_ src:any MTLBuffer,_ dst:any MTLBuffer,_ count:Int)throws{
            guard let e=c.makeComputeCommandEncoder()else{throw NativeError.resource("Bridge compute encoder unavailable")};e.setComputePipelineState(compute);e.setBuffer(src,offset:0,index:0);e.setBuffer(dst,offset:0,index:1);e.dispatchThreads(MTLSize(width:count,height:1,depth:1),threadsPerThreadgroup:MTLSize(width:32,height:1,depth:1));e.endEncoding()
        }
        let setupMS=(CACurrentMediaTime()-setup)*1000,start=CACurrentMediaTime()
        guard let before=context.queue.makeCommandBuffer(),let after=context.queue.makeCommandBuffer()else{throw NativeError.resource("Bridge command buffers unavailable")}
        try encodeCopy(before,original,inputBuffer,features.count);before.encodeSignalEvent(event,value:1);before.commit()
        let encodingStart=CACurrentMediaTime()
        command.beginCommandBuffer(allocator:allocator)
        try MetalMLBridge(capabilities:context.capabilities).encode(command:command,pipeline:pipeline,arguments:table,intermediates:heap);command.endCommandBuffer()
        let dispatchEncodingMS=(CACurrentMediaTime()-encodingStart)*1000,feedback=MLCommitFeedback(),commitOptions=MTL4CommitOptions()
        commitOptions.addFeedbackHandler{value in feedback.record(start:value.gpuStartTime,end:value.gpuEndTime,error:value.error?.localizedDescription)}
        queue.waitForEvent(event,value:1);queue.commit([command],options:commitOptions);queue.signalEvent(event,value:2)
        after.encodeWaitForEvent(event,value:2);try encodeCopy(after,outputBuffer,checked,expected.count);after.commit();let waitStart=CACurrentMediaTime();after.waitUntilCompleted()
        let synchronizationWaitMS=(CACurrentMediaTime()-waitStart)*1000,endToEndMS=(CACurrentMediaTime()-start)*1000
        _=feedback.completed.wait(timeout:.now()+1);let(mlGPUMS,failure)=feedback.snapshot()
        guard failure == nil else{throw NativeError.resource("Metal ML dispatch failed: \(failure!)")}
        guard before.status == .completed,after.status == .completed else{throw NativeError.resource(after.error?.localizedDescription ?? "Metal ML bridge execution failed")}
        let out=checked.contents().assumingMemoryBound(to:Float.self),values=Array(UnsafeBufferPointer(start:out,count:expected.count))
        let error=zip(values,expected).map{abs($0-$1)}.max() ?? 0
        guard values.allSatisfy({$0.isFinite&&$0>=0&&$0<=1}),error<0.02 else{throw NativeError.invalid("Metal ML output failed fixture validation: \(error)")}
        return MetalMLPrototypeReport(setupMS:setupMS,tensorSetupMS:tensorSetupMS,dispatchEncodingMS:dispatchEncodingMS,synchronizationWaitMS:synchronizationWaitMS,mlGPUMS:mlGPUMS,endToEndMS:endToEndMS,modelFunction:function,heapBytes:pipeline.intermediatesHeapSize,bindings:descriptions,torchMaxError:error,minimum:values.min()!,maximum:values.max()!)
    }
    #endif
}
