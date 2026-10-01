import CoreML
import Foundation
import QuartzCore

public enum PrototypeComputeUnits:String,Codable,Sendable,CaseIterable {case all,cpu,cpuGPU,cpuANE
    var units:MLComputeUnits{switch self{case .all:.all;case .cpu:.cpuOnly;case .cpuGPU:.cpuAndGPU;case .cpuANE:.cpuAndNeuralEngine}}
}
public struct PrototypeInferenceReport:Codable,Sendable {
    public let configuration:String,loadMS:Double,warmupMS:Double,meanInferenceMS:Double,minInferenceMS:Double,iterations:Int
    public let memory:MemorySnapshot,minimum:Float,maximum:Float,torchMaxError:Float?
}
public struct PrototypeInference:Sendable {public let probabilities:[Float],report:PrototypeInferenceReport}
public actor MotionPrototypeRunner {
    private var model:MLModel?
    private var loadMS=0.0,configuration=PrototypeComputeUnits.all
    public init(){}
    public func load(url:URL,units:PrototypeComputeUnits = .all)throws {
        let start=CACurrentMediaTime(),config=MLModelConfiguration();config.computeUnits=units.units
        model=try MLModel(contentsOf:url,configuration:config);loadMS=(CACurrentMediaTime()-start)*1000;configuration=units
    }
    public func predict(features:[Float],iterations:Int=1,torchExpected:[Float]?=nil)throws->PrototypeInference {
        guard let model,features.count==5*256*256,iterations>0,iterations<=1000 else{throw NativeError.invalid("Prototype expects 1×5×256×256 Float32; model must be loaded")}
        let input=try MLMultiArray(shape:[1,5,256,256],dataType:.float32)
        _ = features.withUnsafeBytes{memcpy(input.dataPointer,$0.baseAddress!,$0.count)}
        let provider=try MLDictionaryFeatureProvider(dictionary:["features":MLFeatureValue(multiArray:input)])
        func execute()throws->[Float]{
            let result=try model.prediction(from:provider)
            guard let value=result.featureValue(for:"probabilities")?.multiArrayValue,value.count==2*256*256 else{throw NativeError.invalid("Invalid motion-mask output")}
            // Respect strides; Core ML does not promise contiguous output arrays.
            var out=[Float](repeating:0,count:2*256*256)
            for c in 0..<2{for y in 0..<256{for x in 0..<256{out[c*65536+y*256+x]=value[[0,NSNumber(value:c),NSNumber(value:y),NSNumber(value:x)]].floatValue}}};return out
        }
        let warm=CACurrentMediaTime();_ = try model.prediction(from:provider);let warmup=(CACurrentMediaTime()-warm)*1000
        var times=[Double](),last:[Float]=[]
        for i in 0..<iterations {let start=CACurrentMediaTime(),output=try model.prediction(from:provider);times.append((CACurrentMediaTime()-start)*1000)
            if i==iterations-1,let value=output.featureValue(for:"probabilities")?.multiArrayValue {
                if value.strides.map(\.intValue)==[131072,65536,256,1],value.dataType == .float32 {last=Array(UnsafeBufferPointer(start:value.dataPointer.assumingMemoryBound(to:Float.self),count:value.count))}
                else{last=try execute()}
            }
        }
        guard last.count==131072,last.allSatisfy({$0.isFinite&&$0>=0&&$0<=1}),torchExpected == nil || torchExpected?.count==last.count else{throw NativeError.invalid("Invalid prototype probabilities or expected extent")}
        let error=torchExpected.map{expected in zip(last,expected).map{abs($0-$1)}.max() ?? 0}
        guard error == nil || error! <= 0.01 else{throw NativeError.invalid("Core ML differs from PyTorch fixture: \(error!)")}
        return PrototypeInference(probabilities:last,report:PrototypeInferenceReport(configuration:configuration.rawValue,loadMS:loadMS,warmupMS:warmup,meanInferenceMS:times.reduce(0,+)/Double(times.count),minInferenceMS:times.min()!,iterations:iterations,memory:MemoryMonitor.snapshot(),minimum:last.min() ?? 0,maximum:last.max() ?? 0,torchMaxError:error))
    }
}
