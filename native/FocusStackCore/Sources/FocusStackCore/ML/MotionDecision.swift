import CoreML
import Metal
import Foundation

public enum AIDeghostMode:String,CaseIterable,Codable,Sendable {case off,auto,high
    public var threshold:Float{self == .high ? 0.65:0.90}
}
// Retained solely for V2.1 fixture compatibility; production uses FocusMotionModel.
// Synchronously owned by the developer benchmark. Uses shared Metal storage directly as
// Core ML input; physical Core ML transfers/placement are not promised by this API.
final class MotionDecisionModel {
    private let model:MLModel
    private let compiled:URL
    init()throws {
        let url=try Self.compiledURL();compiled=url
        do{model=try MLModel(contentsOf:url,configuration:CoreMLRunner.configuration())}
        catch{try? FileManager.default.removeItem(at:url);throw error}
    }
    deinit{try? FileManager.default.removeItem(at:compiled)}
    static func compiledURL()throws->URL {
        guard let source=Bundle.module.url(forResource:"FocusMotionNetProto",withExtension:"mlpackage",subdirectory:"Models")else{throw NativeError.resource("Motion prototype resource missing")}
        return try MLModel.compileModel(at:source)
    }
    func predict(features:any MTLBuffer,output:any MTLBuffer)throws {
        let input=try MLMultiArray(dataPointer:features.contents(),shape:[1,5,256,256],dataType:.float32,strides:[327680,65536,256,1],deallocator:nil)
        let provider=try MLDictionaryFeatureProvider(dictionary:["features":MLFeatureValue(multiArray:input)])
        let result=try model.prediction(from:provider)
        guard let array=result.featureValue(for:"probabilities")?.multiArrayValue,array.count==131072 else{throw NativeError.invalid("Motion decision extent mismatch")}
        let out=output.contents().assumingMemoryBound(to:Float.self)
        if array.dataType == .float32,array.strides.map(\.intValue)==[131072,65536,256,1]{memcpy(out,array.dataPointer,131072*4)}
        else{for c in 0..<2{for y in 0..<256{for x in 0..<256{out[c*65536+y*256+x]=array[[0,NSNumber(value:c),NSNumber(value:y),NSNumber(value:x)]].floatValue}}}}
        guard (0..<131072).allSatisfy({out[$0].isFinite&&out[$0]>=0&&out[$0]<=1})else{throw NativeError.invalid("Nonfinite motion probabilities")}
    }
}
public enum MotionPrototypeResource {
    public static func compile()throws->URL{try MotionDecisionModel.compiledURL()}
}
