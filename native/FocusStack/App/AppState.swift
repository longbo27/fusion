import FocusStackCore
import Foundation
import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor
@Observable final class AppState {
    var hardware = HardwareReport.collect()
    var log = "Native V2.2 ready. Candidate motion model available; AI defaults Off for review."
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
        guard panel.runModal() == .OK else{return};stackURLs=panel.urls.sorted{$0.lastPathComponent<$1.lastPathComponent};append("Loaded \(stackURLs.count) TIFF sources in filename order; first source is registration/reference owner.")
    }
    func runStack() {
        guard !busy,!stackURLs.isEmpty else{return}
        let panel=NSSavePanel();panel.allowedContentTypes=[.tiff];panel.nameFieldStringValue="FocusStack-Native.tif"
        guard panel.runModal() == .OK,let output=panel.url else{return}
        let inputs=stackURLs,quality=quality,ai=aiMode,debug=exportDiagnostics ? output.deletingPathExtension().appendingPathExtension("diagnostics"):nil;busy=true;stackProgress=0;registrationDiagnostics=nil;diagnosticDirectory=nil
        task=Task{
            defer{busy=false}
            do{
                let report=try await NativeStackEngine().run(inputs:inputs,output:output,quality:quality,aiMode:ai,debugDirectory:debug){[weak self] message,fraction in
                    Task{@MainActor in self?.stackProgress=fraction;self?.append(message)}
                }
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
