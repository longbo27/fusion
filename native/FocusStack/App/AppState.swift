import FocusStackCore
import Foundation
import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor
@Observable final class AppState {
    var hardware = HardwareReport.collect()
    var log = "Native foundation ready. No production model loaded."
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
                append("Metadata only. Large TIFF tile decode is gated until a bounded backend exists.")
            } catch { append(error.localizedDescription) }
            hardware = HardwareReport.collect()
        }
    }
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
