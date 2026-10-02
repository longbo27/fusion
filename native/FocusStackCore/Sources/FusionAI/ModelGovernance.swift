@_exported import FusionCore
import Foundation

public struct ModelGovernance:Codable,Sendable {
    public private(set) var version="FocusMotionNetV1",architectureVersion="compact-encoder-decoder-v1"
    public private(set) var trainingCodeCommit="caa8c698f86d568a29bf1246ed3777c3487b5e60"
    public private(set) var weightsSHA256="c49e48292e89160623e07a7fbe6fa2c1de08dd26c70573a2b7906d4a86c87435"
    public private(set) var datasetProvenance="Locally generated synthetic scenes; no scraped images or private photographic training examples. Generator/library licensing recorded separately."
    public private(set) var syntheticFraction=1.0,realFraction=0.0,evaluationVersion="heldout-2211001-native-policy"
    public private(set) var conversion="coremltools 9, ML Program, FP16 mask internals / Float32 IO"
    public private(set) var qualityStatus="Motion IoU/recall targets remain unmet; photographer review required."
    public private(set) var modelSHA256:String="unavailable"
    public private(set) var packageHashDefinition="SHA-256 of sorted relative path UTF-8 + exact file bytes for every source-package file"
    public init(){
        if let url=try? FocusMotionModelResource.sourcePackage(),let e=FileManager.default.enumerator(at:url,includingPropertiesForKeys:[.isRegularFileKey]){
            let files=e.compactMap{$0 as? URL}.filter{(try? $0.resourceValues(forKeys:[.isRegularFileKey]).isRegularFile)==true}.sorted{$0.path<$1.path};var bytes=Data()
            for file in files{guard let data=try? Data(contentsOf:file)else{return};bytes.append(Data(file.path.dropFirst(url.path.count+1).utf8));bytes.append(data)}
            modelSHA256=TechnicalHash.data(bytes)
        }
    }
}
public enum ProductFeatureStatus:String,Codable,Sendable {case available,extensionPoint,ipReviewRequired="IP_REVIEW_REQUIRED"}
public struct ProductFeature:Codable,Sendable {
    public let name:String,status:ProductFeatureStatus
    public static let future:[Self] = ["Computational refocusing","Selective post-capture depth of field","Automatic focus-bracketing guidance","Live/video all-focus fusion","Camera-control focus acquisition","Depth-from-focus capture automation"].map{Self(name:$0,status:.ipReviewRequired)} + ["Exposure fusion/HDR","Noise stacking","Burst fusion","Astro stacking","Panorama","Super resolution","Video/image sequence fusion"].map{Self(name:$0,status:.extensionPoint)}
}
