import FocusStackCore
import SwiftUI

struct HardwareView: View {
    let report: HardwareReport
    func gib(_ bytes: UInt64) -> String { String(format: "%.2f GiB",Double(bytes)/1073741824) }
    var body: some View {
        GroupBox("Hardware & acceleration") {
            Grid(alignment: .leading,horizontalSpacing: 30,verticalSpacing: 7) {
                GridRow { Text("Mac"); Text("\(report.model) · \(report.chip)") }
                GridRow { Text("Unified memory"); Text(report.metal?.unifiedMemory == true ? gib(report.physicalBytes) : "Unknown") }
                GridRow { Text("Metal GPU"); Text(report.metal?.deviceName ?? "Unavailable") }
                GridRow { Text("Recommended max working set"); Text(gib(report.metal?.recommendedWorkingSet ?? 0)) }
                GridRow { Text("App memory headroom"); Text(gib(report.recommendedBudget)) }
                GridRow { Text("Metal allocated"); Text(gib(report.metal?.currentAllocatedBytes ?? 0)) }
                GridRow { Text("Process RSS"); Text(gib(report.memory.residentBytes)) }
                GridRow { Text("Core ML devices"); Text(report.ml.devices.joined(separator: ", ")) }
                GridRow { Text("Neural Engine detected"); Text(report.ml.neuralEngineDetected ? "Yes; model placement untested" : "Unavailable") }
                GridRow { Text("Metal 4 / tensors / ML encoder"); Text("\(report.metal?.metal4 == true ? "Yes" : "No") / \(report.metal?.tensor == true ? "Yes" : "No") / \(report.metal?.machineLearningEncoder == true ? "Yes" : "No")") }
                GridRow { Text("Model"); Text("No production model loaded.") }
                GridRow { Text("Vision"); Text("Experimental optical-flow API available") }
            }.frame(maxWidth: .infinity,alignment: .leading).padding(8)
        }
    }
}
