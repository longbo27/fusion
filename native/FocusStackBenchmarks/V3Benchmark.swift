import Foundation
import FusionProject
import FusionCore

extension BenchmarkMain {
    static func v3(_ args:[String])async throws->Bool {
        if args.count>4,["--v3-stack","--v3-identity","--v3-auto"].contains(args[1]){
            let output=URL(fileURLWithPath:args[2]),project=URL(fileURLWithPath:args[3]),inputs=args.dropFirst(4).map{URL(fileURLWithPath:$0)}
            let(_,report)=try await FusionWorkflow().run(inputs:inputs,output:output,projectURL:project,aiMode:args[1]=="--v3-auto" ? .auto:.off,suppliedTransforms:args[1]=="--v3-identity" ? inputs.map{_ in SimilarityTransform()}:nil){message,fraction in print(String(format:"%.1f%% %@",fraction*100,message));fflush(stdout)}
            try printJSON(report);return true
        }
        if args.count==3,args[1]=="--v3-inspect" {
            let doc=try FusionProjectDocument.open(directory:URL(fileURLWithPath:args[2])),m=await doc.manifest
            try printJSON(await doc.inspect(x:m.width/2,y:m.height/2));try printJSON(m.report);try printJSON(m.coverage);print("Project bytes \(try FusionWorkflow.directoryBytes(doc.directory)), findings \(m.findings.count)");return true
        }
        if args.count==4,args[1]=="--v3-export" {
            let doc=try FusionProjectDocument.open(directory:URL(fileURLWithPath:args[3]))
            let start=Date.timeIntervalSinceReferenceDate
            try printJSON(await FusionWorkflow().export(project:doc,to:URL(fileURLWithPath:args[2])))
            print("Export wall seconds \(Date.timeIntervalSinceReferenceDate-start)");try printJSON(MemoryMonitor.snapshot());return true
        }
        if args.count==6,args[1]=="--v3-edit" {
            let doc=try FusionProjectDocument.open(directory:URL(fileURLWithPath:args[2])),x=Int(args[3])!,y=Int(args[4])!,source=Int(args[5])!,m=await doc.manifest,region=PixelRegion(x:x,y:y,width:32,height:32)
            let c=m.overrides+[OwnershipConstraint(region:region,action:.source(source))]
            try printJSON(await FusionWorkflow().edit(project:doc,constraints:c,affected:region));try printJSON(await doc.inspect(x:x+16,y:y+16));return true
        }
        return false
    }
}
