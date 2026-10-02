import FocusStackCore
import FusionCore
import FusionProject
import FusionAI
import Foundation
import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor
@Observable final class AppState {
    var project:FusionProjectDocument?
    var productManifest:FusionManifest?
    var workspaceMode="STACK"
    var viewerOverlay="Final"
    var comparisonMode="Final"
    var previewImage:NSImage?
    var sourcePreview:NSImage?
    var selectedProvenance:PixelProvenance?
    var pointX=0
    var pointY=0
    var selectedSource=0
    var selectedFinding=0
    var brushSize=32
    var previewRegion:TileDescriptor?
    var sourceAvailability:[String]=[]
    private let productWorkflow=FusionWorkflow()
    var hardware = HardwareReport.collect()
    var log = "V3 product foundation ready. Source-Faithful mode; AI defaults Off for review."
    var stackURLs: [URL] = []
    var quality = StackQuality.maximum
    var aiMode = AIDeghostMode.off
    var stackProgress = 0.0
    var stackReport: NativeStackReport?
    var exportDiagnostics=false
    var diagnosticDirectory:URL?
    var registrationDiagnostics:RegistrationDiagnostics?
    var overlayMotion=true
    var diagnosticMap="ownership_map"
    var metadata: ImageMetadata?
    var benchmark: BenchmarkReport?
    var busy = false
    private var scheduler: TileScheduler?
    private var task: Task<Void,Never>?
    func append(_ message: String) {
        log += "\n" + message
        // Bounded status history.
        if log.count > 16000 { log = String(log.suffix(12000)) }
    }
    func loadTIFF() {
        guard !busy else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.tiff]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        busy = true
        task = Task {
            defer { busy = false }
            do {
                let result = try await Task.detached { try TIFFInspector.inspect(url) }.value
                metadata = result; append(result.summary)
                let backend = try await Task.detached { try LibTIFFTileProvider(url:url).metadata() }.value
                append(backend.summary)
            } catch { append(error.localizedDescription) }
            hardware = HardwareReport.collect()
        }
    }
    func loadStack() {
        guard !busy else { return }
        let panel=NSOpenPanel();panel.allowedContentTypes=[.tiff];panel.allowsMultipleSelection=true
        guard panel.runModal() == .OK else{return};stackURLs=panel.urls.sorted{$0.lastPathComponent<$1.lastPathComponent};project=nil;productManifest=nil;previewImage=nil;sourcePreview=nil;selectedProvenance=nil;sourceAvailability=[];selectedSource=0;workspaceMode="STACK";append("Loaded \(stackURLs.count) TIFF sources in filename order; first source is registration/reference owner.")
    }
    func runStack() {
        guard !busy,!stackURLs.isEmpty else{return}
        let panel=NSSavePanel();panel.allowedContentTypes=[.tiff];panel.nameFieldStringValue="FocusStack-Native.tif"
        guard panel.runModal() == .OK,let output=panel.url else{return}
        let inputs=stackURLs,quality=quality,ai=aiMode,debug=exportDiagnostics ? output.deletingPathExtension().appendingPathExtension("diagnostics"):nil;busy=true;stackProgress=0;registrationDiagnostics=nil;diagnosticDirectory=nil
        task=Task{
            defer{busy=false}
            do{
                let projectURL=output.deletingPathExtension().appendingPathExtension("fusionproject")
                let (document,productReport)=try await productWorkflow.run(inputs:inputs,output:output,projectURL:projectURL,quality:quality,aiMode:ai,diagnosticDirectory:debug){[weak self] message,fraction in
                    Task{@MainActor in self?.stackProgress=fraction;self?.append(message)}
                }
                let report=productReport.engine;project=document;productManifest=await document.manifest;pointX=report.width/2;pointY=report.height/2;await refreshPreview()
                stackReport=report;diagnosticDirectory=debug;registrationDiagnostics=report.alignment.last?.diagnostics;append("Completed \(report.width)×\(report.height) RGB16: \(String(format:"%.2f",report.totalSeconds)) s; full output pixels and exact ICC validated.")
                if let model=report.modelTiming {append("Motion backend: \(model.backend.rawValue), calibrated warm \(String(format:"%.2f",model.warmMS)) ms. Photographic RGB comes exclusively from captured frames.")}
            }catch{if let rejected=error as? RegistrationRejected{registrationDiagnostics=rejected.diagnostics};append(error.localizedDescription)}
            hardware=HardwareReport.collect()
        }
    }
    func cancel(){task?.cancel()}
    func runGPU(size: Int) {
        guard !busy else { return }; busy = true
        task = Task {
            defer { busy = false }
            do {
                if scheduler == nil { scheduler = try TileScheduler() }
                let report = try await scheduler!.processPrototype(provider: SyntheticTileProvider(),
                    descriptor: TileDescriptor(width: size,height: size))
                benchmark = report
                append("\(size)² RGB16 validated. GPU \(String(format: "%.3f", report.gpuTotalMS)) ms; luminance error \(report.luminanceMaxError).")
            } catch { append(error.localizedDescription) }
            hardware = HardwareReport.collect()
        }
    }
}

extension AppState {
    func openProject(){
        guard !busy else{return};let panel=NSOpenPanel();panel.canChooseFiles=false;panel.canChooseDirectories=true;panel.treatsFilePackagesAsDirectories=true
        guard panel.runModal() == .OK,let url=panel.url else{return};busy=true
        task=Task{defer{busy=false};do{let document=try FusionProjectDocument.open(directory:url);project=document;productManifest=await document.manifest;stackURLs=productManifest!.sources.map(\.url);pointX=productManifest!.width/2;pointY=productManifest!.height/2;sourceAvailability=[];for i in stackURLs.indices{sourceAvailability.append(String(describing:try await document.availability(sourceIndex:i)))};await refreshPreview();append("Project reopened. Missing/changed sources require verified relink.")}catch{append(error.localizedDescription)}}
    }
    func relinkSource(){
        guard !busy,let project else{return};let panel=NSOpenPanel();panel.allowedContentTypes=[.tiff];guard panel.runModal() == .OK,let url=panel.url else{return};busy=true
        task=Task{defer{busy=false};do{try await project.relink(sourceIndex:selectedSource,to:url);productManifest=await project.manifest;stackURLs=productManifest!.sources.map(\.url);sourceAvailability=[];for i in stackURLs.indices{sourceAvailability.append(String(describing:try await project.availability(sourceIndex:i,verifyHash:false)))};await refreshPreview();append("Source identity verified and relinked.")}catch{append(error.localizedDescription)}}
    }
    func refreshPreview()async {
        guard let project,let m=productManifest,m.complete else{return}
        do {
            let w=min(512,m.width),h=min(512,m.height),x=max(0,min(m.width-w,pointX-w/2)),y=max(0,min(m.height-h,pointY-h/2)),region=try TileDescriptor(x:x,y:y,width:w,height:h)
            previewRegion=region;let data=try await project.preview(region:region)
            selectedProvenance=try await project.inspect(x:max(0,min(m.width-1,pointX)),y:max(0,min(m.height-1,pointY)))
            let profile=try await Task.detached{try LibTIFFTileProvider(url:m.outputURL ?? m.sources[0].url).metadata().icc}.value
            previewImage=Self.display(data.0,profile:profile,overlay:viewerOverlay,evidence:data.1)
            if comparisonMode != "Final"{let source=try await productWorkflow.previewSource(project:project,index:max(0,min(m.sources.count-1,selectedSource)),region:region);sourcePreview=Self.display(source,profile:profile,overlay:"Final",evidence:nil)}else{sourcePreview=nil}
        }catch{append(error.localizedDescription)}
    }
    static func display(_ tile:RGB16Tile,profile:Data?,overlay:String,evidence:ProductEvidenceTile?)->NSImage? {
        let d=tile.descriptor;var pixels=[UInt8](repeating:255,count:d.pixelCount*4)
        for i in 0..<d.pixelCount{
            if overlay=="Final" || evidence==nil {for c in 0..<3{pixels[i*4+c]=UInt8(tile.rgba[i*4+c]>>8)}}
            else {
                let word=evidence!.words[i],p=PixelProvenance(word:word);var value:Double=0
                if (overlay=="Motion Map" && p.motionProbability==nil)||(overlay=="Registration Confidence" && p.registrationConfidence==nil){pixels[i*4]=128;pixels[i*4+1]=128;pixels[i*4+2]=128;continue}
                switch overlay{case "Source Map":value=Double(p.primarySource%13)/12;case "Motion Map":value=p.motionProbability ?? 0;case "Focus Confidence":value=p.focusConfidence;case "Registration Confidence":value=p.registrationConfidence ?? 0;case "Manual Overrides":value=p.manualEdit ? 1:0;case "Coverage":value=p.coverageConfidence;case "QA":value=p.artifactFlags==0 ? 0:1;default:value=p.uncertainty.reviewRisk}
                pixels[i*4]=UInt8(clamping:Int(value*255));pixels[i*4+1]=UInt8(clamping:Int((1-value)*255));pixels[i*4+2]=0
            }
        }
        let space=overlay=="Final" ? (profile.flatMap{CGColorSpace(iccData:$0 as CFData)} ?? CGColorSpaceCreateDeviceRGB()):CGColorSpaceCreateDeviceRGB()
        guard let provider=CGDataProvider(data:Data(pixels) as CFData),let image=CGImage(width:d.width,height:d.height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:d.width*4,space:space,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.noneSkipLast.rawValue),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent)else{return nil}
        return NSImage(cgImage:image,size:NSSize(width:d.width,height:d.height))
    }
    func inspectLocation(x:Int,y:Int){pointX=x;pointY=y;task=Task{await refreshPreview()}}
    func applyOwnership(_ action:OwnershipAction,region:PixelRegion?=nil){
        guard !busy,let project,let m=productManifest,m.complete else{return};let x=max(0,min(pointX-brushSize/2,m.width-brushSize)),y=max(0,min(pointY-brushSize/2,m.height-brushSize))
        let area=region ?? PixelRegion(x:x,y:y,width:min(brushSize,m.width),height:min(brushSize,m.height));busy=true
        task=Task{defer{busy=false};do{var edits=m.overrides;edits.append(OwnershipConstraint(region:area,action:action));let result=try await productWorkflow.edit(project:project,constraints:edits,affected:area);productManifest=await project.manifest;await refreshPreview();append("Local edit: \(result.recomputedTiles) tiles, \(String(format:"%.2f",result.seconds)) s. RGB remains captured-source; export re-encodes TIFF.")}catch{append(error.localizedDescription)}}
    }
    func clearOverride(){applyOwnership(.auto)}
    func reviewFinding(_ action:String){
        guard !busy,let project,let m=productManifest,m.findings.indices.contains(selectedFinding)else{return};let finding=m.findings[selectedFinding]
        busy=true
        task=Task{defer{busy=false};do{
            // Record the review before recomputation replaces findings in this region.
            try await project.review(id:finding.id,action:action)
            if action=="acceptAuto"{
                let edits=m.overrides+[OwnershipConstraint(region:finding.boundingRegion,action:.auto)]
                _ = try await productWorkflow.edit(project:project,constraints:edits,affected:finding.boundingRegion)
            }
            productManifest=await project.manifest;await refreshPreview()
        }catch{append(error.localizedDescription)}}
    }
    func jumpFinding(_ offset:Int){guard let m=productManifest,!m.findings.isEmpty else{return};selectedFinding=(selectedFinding+offset+m.findings.count)%m.findings.count;let f=m.findings[selectedFinding];inspectLocation(x:f.boundingRegion.x+f.boundingRegion.width/2,y:f.boundingRegion.y+f.boundingRegion.height/2)}
    func exportProject(){
        guard !busy,let project else{return};let panel=NSSavePanel();panel.allowedContentTypes=[.tiff];panel.nameFieldStringValue="FocusStack-Edited.tif";guard panel.runModal() == .OK,let output=panel.url else{return};busy=true
        task=Task{defer{busy=false};do{let r=try await productWorkflow.export(project:project,to:output);productManifest=await project.manifest;append("Exported validated RGB16 TIFF and technical audit; \(r.outputBytes) bytes.")}catch{append(error.localizedDescription)}}
    }
}
