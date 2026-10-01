import Foundation
import Metal
import QuartzCore

protocol MotionGPUExecutor {
    func predict(features:any MTLBuffer,output:any MTLBuffer)throws
}
#if compiler(>=6.2)
// Optional compiled package supplied by the host. One persistent tensor/heap set,
// one dispatch at a time, GPU event ordering and GPU-only feature/mask copies.
@available(macOS 26,iOS 26,*)
final class MetalMotionExecutor:MotionGPUExecutor {
    private let context:MetalContext,queue:any MTL4CommandQueue,allocator:any MTL4CommandAllocator,command:any MTL4CommandBuffer,event:any MTLSharedEvent
    private let input:any MTLBuffer,output:any MTLBuffer,inputTensor:any MTLTensor,outputTensor:any MTLTensor
    private let table:any MTL4ArgumentTable,pipeline:any MTL4MachineLearningPipelineState,heap:any MTLHeap,residency:any MTLResidencySet
    private var sequence:UInt64=0
    init(package:URL)throws {
        context=try MetalContext();let device=context.device
        guard context.capabilities.machineLearningEncoder,context.capabilities.tensor,let q=device.makeMTL4CommandQueue(),let a=device.makeCommandAllocator(),let c=device.makeCommandBuffer(),let e=device.makeSharedEvent()else{throw NativeError.unavailable("Metal ML unavailable")}
        queue=q;allocator=a;command=c;event=e
        let library=try device.makeLibrary(URL:package)
        guard let name=library.functionNames.first else{throw NativeError.invalid("No model function")}
        let compiler=try device.makeCompiler(descriptor:MTL4CompilerDescriptor()),function=MTL4LibraryFunctionDescriptor();function.library=library;function.name=name
        let descriptor=MTL4MachineLearningPipelineDescriptor();descriptor.machineLearningFunctionDescriptor=function;let options=MTL4PipelineOptions();options.shaderReflection = .bindingInfo;descriptor.options=options
        pipeline=try compiler.makeMachineLearningPipelineState(descriptor:descriptor)
        guard let ib=pipeline.reflection?.bindings.first(where:{$0.access == .readOnly}),let ob=pipeline.reflection?.bindings.first(where:{$0.access == .writeOnly})else{throw NativeError.invalid("Model binding contract unavailable")}
        func extents(_ a:[Int])->MTLTensorExtents{var values=a;return values.withUnsafeMutableBufferPointer{MTLTensorExtents(__rank:$0.count,values:$0.baseAddress!)!}}
        func tensor(_ channels:Int)throws->(any MTLBuffer,any MTLTensor){
            guard let buffer=device.makeBuffer(length:channels*65536*4,options:.storageModeShared)else{throw NativeError.resource("Metal ML tensor allocation")}
            let d=MTLTensorDescriptor();d.dimensions=extents([256,256,channels,1]);d.strides=extents([1,256,65536,channels*65536]);d.dataType = .float32;d.usage=[.compute,.machineLearning];d.storageMode = .shared
            return(buffer,try buffer.makeTensor(descriptor:d,offset:0))
        }
        (input,inputTensor)=try tensor(12);(output,outputTensor)=try tensor(7)
        let td=MTL4ArgumentTableDescriptor();td.maxBufferBindCount=max(ib.index,ob.index)+1;table=try device.makeArgumentTable(descriptor:td)
        table.setResource(inputTensor.gpuResourceID,bufferIndex:ib.index);table.setResource(outputTensor.gpuResourceID,bufferIndex:ob.index)
        let hd=MTLHeapDescriptor();hd.size=max(4096,pipeline.intermediatesHeapSize);hd.storageMode = .private
        guard let h=device.makeHeap(descriptor:hd)else{throw NativeError.resource("ML heap allocation")};heap=h
        let rd=MTLResidencySetDescriptor();rd.initialCapacity=3;residency=try device.makeResidencySet(descriptor:rd);residency.addAllocation(inputTensor);residency.addAllocation(outputTensor);residency.addAllocation(heap);residency.commit();queue.addResidencySet(residency)
    }
    func predict(features:any MTLBuffer,output destination:any MTLBuffer)throws {
        guard features.length>=input.length,destination.length>=output.length,let before=context.queue.makeCommandBuffer(),let after=context.queue.makeCommandBuffer(),let b=before.makeBlitCommandEncoder()else{throw NativeError.resource("Metal ML bridge buffers unavailable")}
        sequence+=2;let signal=sequence-1
        b.copy(from:features,sourceOffset:0,to:input,destinationOffset:0,size:input.length);b.endEncoding();before.encodeSignalEvent(event,value:signal);before.commit()
        allocator.reset();command.beginCommandBuffer(allocator:allocator)
        try MetalMLBridge(capabilities:context.capabilities).encode(command:command,pipeline:pipeline,arguments:table,intermediates:heap);command.endCommandBuffer()
        let feedback=MLCommitFeedback(),options=MTL4CommitOptions();options.addFeedbackHandler{f in feedback.record(start:f.gpuStartTime,end:f.gpuEndTime,error:f.error?.localizedDescription)}
        queue.waitForEvent(event,value:signal);queue.commit([command],options:options);queue.signalEvent(event,value:sequence)
        // Explicit event wait precedes the result-copy encoder.
        after.encodeWaitForEvent(event,value:sequence)
        guard let copy=after.makeBlitCommandEncoder()else{throw NativeError.resource("Metal ML result bridge unavailable")}
        copy.copy(from:output,sourceOffset:0,to:destination,destinationOffset:0,size:output.length);copy.endEncoding();after.commit();after.waitUntilCompleted()
        guard feedback.completed.wait(timeout:.now()+5) == .success,feedback.snapshot().1==nil,before.status == .completed,after.status == .completed else{throw NativeError.resource("Metal ML dispatch failed")}
    }
}
#endif
