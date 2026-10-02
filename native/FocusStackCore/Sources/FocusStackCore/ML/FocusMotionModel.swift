import CoreML
import Foundation
import Metal
import QuartzCore

public struct MotionModelTiming:Codable,Sendable {
    public let backend:MotionInferenceBackend,loadMS:Double,coldMS:Double,warmMS:Double
    public let measurements:[InferenceBackendMeasurement]
    public let rejectedBackends:[String]
}
// Exclusively owned by the stack actor; fixed 12×256² input and 7×256² masks.
// The result's last four channels are ownership probabilities, never RGB.
final class FocusMotionModel {
    private let model:MLModel,compiled:URL
    let timing:MotionModelTiming
    static func compile()throws->URL {
        guard let url=Bundle.module.url(forResource:"FocusMotionNetV1",withExtension:"mlpackage",subdirectory:"Models")else{throw NativeError.resource("FocusMotionNetV1 resource missing")}
        return try MLModel.compileModel(at:url)
    }
    init(units:MotionInferenceBackend? = nil)throws {
        let start=CACurrentMediaTime(),url=try Self.compile();compiled=url
        do {
            let input=try MLMultiArray(shape:[1,12,256,256],dataType:.float32)
            let calibration=input.dataPointer.assumingMemoryBound(to:Float.self)
            for i in 0..<65536{let r:Float=0.4+0.15*sin(Float(i%256)*0.07+Float(i/256)*0.11)
                for c in 0..<12{calibration[c*65536+i]=c<4 ? r+Float(c)*0.005:(c==7 ? 0.25:(c==9 ? 0.1:0.01))}}
            let provider=try MLDictionaryFeatureProvider(dictionary:["features":MLFeatureValue(multiArray:input)])
            let neural=MLHardwareInspector().neuralEngineDetected
            let candidates=units.map{[$0]} ?? [.cpu,.cpuANE,.all,.cpuGPU]
            var selectedModel:MLModel?,selectedBackend:MotionInferenceBackend?,measurements=[InferenceBackendMeasurement](),cold:[MotionInferenceBackend:Double]=[:],oracle:[Float]?,rejected=[String]()
            for backend in candidates where backend != .metalML && (backend != .cpuANE || neural){
                do {
                let configuration=MLModelConfiguration()
                configuration.computeUnits=switch backend{case .cpu:.cpuOnly;case .cpuGPU:.cpuAndGPU;case .cpuANE:.cpuAndNeuralEngine;default:.all}
                let candidate=try MLModel(contentsOf:url,configuration:configuration)
                let first=CACurrentMediaTime();let result=try candidate.prediction(from:provider);cold[backend]=(CACurrentMediaTime()-first)*1000
                guard let array=result.featureValue(for:"probabilities")?.multiArrayValue,array.count==7*65536,array.dataType == .float32,array.strides.map(\.intValue)==[458752,65536,256,1]else{throw NativeError.invalid("Motion model calibration layout")}
                let calibrationValues=Array(UnsafeBufferPointer(start:array.dataPointer.assumingMemoryBound(to:Float.self),count:array.count))
                guard calibrationValues.allSatisfy({$0.isFinite&&$0>=0&&$0<=1})else{throw NativeError.invalid("Nonfinite calibration output")}
                if let oracle{guard zip(calibrationValues,oracle).allSatisfy({abs($0-$1)<=0.02})else{throw NativeError.invalid("Backend calibration exceeds CPU tolerance")}}else{oracle=calibrationValues}
                var values=[Double]()
                for _ in 0..<5{let t=CACurrentMediaTime();_ = try candidate.prediction(from:provider);values.append((CACurrentMediaTime()-t)*1000)}
                measurements.append(.init(backend:backend,medianMS:values.sorted()[2],validated:true))
                let best=InferenceBackendSelection.choose(measurements,neuralEngine:neural,metalML:false)
                if best==backend{selectedModel=candidate;selectedBackend=backend}
                }catch{rejected.append("\(backend.rawValue): \(error.localizedDescription)")}
            }
            guard let selected=selectedBackend,let loaded=selectedModel else{throw NativeError.unavailable("No validated inference backend")}
            model=loaded;timing=MotionModelTiming(backend:selected,loadMS:(CACurrentMediaTime()-start)*1000,coldMS:cold[selected]!,warmMS:measurements.first{$0.backend==selected}!.medianMS,measurements:measurements,rejectedBackends:rejected)
        }catch{try? FileManager.default.removeItem(at:url);throw error}
    }
    deinit{try? FileManager.default.removeItem(at:compiled)}
    func predict(features:any MTLBuffer,output:any MTLBuffer)throws {
        guard features.length>=12*65536*4,output.length>=7*65536*4 else{throw NativeError.invalid("Motion inference buffer extent")}
        let input=try MLMultiArray(dataPointer:features.contents(),shape:[1,12,256,256],dataType:.float32,strides:[786432,65536,256,1],deallocator:nil)
        let result=try model.prediction(from:MLDictionaryFeatureProvider(dictionary:["features":MLFeatureValue(multiArray:input)]))
        guard let array=result.featureValue(for:"probabilities")?.multiArrayValue,array.count==7*65536 else{throw NativeError.invalid("Motion model output extent")}
        let out=output.contents().assumingMemoryBound(to:Float.self)
        if array.dataType == .float32,array.strides.map(\.intValue)==[458752,65536,256,1]{memcpy(out,array.dataPointer,array.count*4)}
        else{for c in 0..<7{for y in 0..<256{for x in 0..<256{out[c*65536+y*256+x]=array[[0,NSNumber(value:c),NSNumber(value:y),NSNumber(value:x)]].floatValue}}}}
        guard (0..<7*65536).allSatisfy({out[$0].isFinite&&out[$0]>=0&&out[$0]<=1})else{throw NativeError.invalid("Nonfinite motion probabilities")}
    }
}
public enum FocusMotionModelResource {
    public static func compile()throws->URL{try FocusMotionModel.compile()}
    public static func sourcePackage()throws->URL{guard let url=Bundle.module.url(forResource:"FocusMotionNetV1",withExtension:"mlpackage",subdirectory:"Models")else{throw NativeError.resource("Model source package missing")};return url}
}

// Synchronous session, exclusively owned by a processing actor or benchmark.
// Reuses one loaded model across all bounded patches; no source-indexed tensors.
public final class MotionInferenceSession {
    private let model:FocusMotionModel
    private var executor:(any MotionGPUExecutor)?
    public private(set) var timing:MotionModelTiming
    public init(backend:MotionInferenceBackend? = nil,metalPackage:URL? = nil)throws{
        model=try FocusMotionModel(units:backend == .metalML ? nil:backend)
        var selected:(any MotionGPUExecutor)?,report=model.timing
        #if compiler(>=6.2)
        if let metalPackage, #available(macOS 26,iOS 26,*) {
            let start=CACurrentMediaTime()
            do {
                let candidate=try MetalMotionExecutor(package:metalPackage),context=try MetalContext()
                guard let input=context.device.makeBuffer(length:12*65536*4,options:.storageModeShared),let cpu=context.device.makeBuffer(length:7*65536*4,options:.storageModeShared),let gpu=context.device.makeBuffer(length:7*65536*4,options:.storageModeShared)else{throw NativeError.resource("Metal calibration buffers")}
                let values=input.contents().assumingMemoryBound(to:Float.self)
                for i in 0..<65536{let r:Float=0.4+0.15*sin(Float(i%256)*0.07+Float(i/256)*0.11);for c in 0..<12{values[c*65536+i]=c<4 ? r+Float(c)*0.005:(c==7 ? 0.25:(c==9 ? 0.1:0.01))}}
                try model.predict(features:input,output:cpu)
                let first=CACurrentMediaTime();try candidate.predict(features:input,output:gpu);let cold=(CACurrentMediaTime()-first)*1000
                let a=cpu.contents().assumingMemoryBound(to:Float.self),b=gpu.contents().assumingMemoryBound(to:Float.self)
                guard (0..<7*65536).allSatisfy({b[$0].isFinite && b[$0]>=0 && b[$0]<=1 && abs(a[$0]-b[$0])<=0.02})else{throw NativeError.invalid("Metal backend calibration tolerance")}
                var times=[Double]();for _ in 0..<5{let t=CACurrentMediaTime();try candidate.predict(features:input,output:gpu);times.append((CACurrentMediaTime()-t)*1000)}
                let warm=times.sorted()[2],measurements=report.measurements+[InferenceBackendMeasurement(backend:.metalML,medianMS:warm,validated:true)]
                let best=InferenceBackendSelection.choose(measurements,neuralEngine:MLHardwareInspector().neuralEngineDetected,metalML:true)
                if best == .metalML || backend == .metalML{selected=candidate}
                report=MotionModelTiming(backend:selected == nil ? report.backend:.metalML,loadMS:report.loadMS+(CACurrentMediaTime()-start)*1000,coldMS:selected == nil ? report.coldMS:cold,warmMS:selected == nil ? report.warmMS:warm,measurements:measurements,rejectedBackends:report.rejectedBackends)
            }catch{report=MotionModelTiming(backend:report.backend,loadMS:report.loadMS,coldMS:report.coldMS,warmMS:report.warmMS,measurements:report.measurements,rejectedBackends:report.rejectedBackends+["metalML: \(error.localizedDescription)"])}
        }
        #endif
        if backend == .metalML && selected == nil{throw NativeError.unavailable("Requested Metal ML package unavailable or invalid")}
        executor=selected;timing=report
    }
    public func apply(to pipeline:ProductionMetalPipeline,region:TileDescriptor,mode:AIDeghostMode)throws {
        guard mode != .off else{return}
        for y in stride(from:0,to:region.height,by:208){for x in stride(from:0,to:region.width,by:208){
            let features=try pipeline.candidateFeatures(x:x,y:y)
            if let executor{
                do{try executor.predict(features:features,output:pipeline.motionOutput)}
                catch{
                    self.executor=nil
                    timing=MotionModelTiming(backend:model.timing.backend,loadMS:timing.loadMS,coldMS:model.timing.coldMS,warmMS:model.timing.warmMS,measurements:timing.measurements,rejectedBackends:timing.rejectedBackends+["Metal runtime fallback: \(error.localizedDescription)"])
                    try model.predict(features:features,output:pipeline.motionOutput)
                }
            }else{try model.predict(features:features,output:pipeline.motionOutput)}
            try pipeline.scatterMotion(x:x,y:y)
        }}
        try pipeline.applyMotion(mode:mode)
    }
}
