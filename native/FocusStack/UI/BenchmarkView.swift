import FocusStackCore
import SwiftUI

struct BenchmarkView: View {
    let report: BenchmarkReport
    var body: some View {
        GroupBox("Benchmark · \(report.tileWidth) × \(report.tileHeight) RGB16") {
            VStack(alignment: .leading,spacing: 5) {
                Text(String(format: "Upload %.3f ms · luminance %.3f ms · Sobel/Tenengrad %.3f ms · readback %.3f ms",report.uploadMS,report.luminanceMS,report.focusMS,report.readbackMS))
                Text(String(format: "GPU total %.3f ms · pipeline wall %.3f ms · CPU reference %.3f ms",report.gpuTotalMS,report.pipelineWallMS,report.cpuReferenceMS))
                Text(String(format: "Peak RSS %.1f MiB · Metal allocation %.1f MiB",Double(report.memory.lifetimePeakBytes)/1048576,Double(report.metalAllocatedBytes)/1048576))
                Text("CPU validation passed; exact uint16 passthrough. \(report.timingMethod)").foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity,alignment: .leading).padding(8)
        }
    }
}
