import FocusStackCore
import SwiftUI

struct ContentView: View {
    @Bindable var state: AppState
    var body: some View {
        VStack(alignment: .leading,spacing: 16) {
            Text("FocusStack Native").font(.largeTitle).fontWeight(.semibold)
            Text("Native V2 Foundation").foregroundStyle(.secondary)
            TabView {
                ScrollView {
                    VStack(alignment: .leading,spacing: 18) {
                        HardwareView(report: state.hardware)
                        GroupBox("Pipeline") {
                            HStack {
                                Button("Load TIFF") { state.loadTIFF() }
                                Button("Run GPU test") { state.runGPU(size: 512) }
                                Button("Run benchmark") { state.runGPU(size: 2048) }
                                if state.busy { ProgressView().controlSize(.small) }
                                Spacer()
                            }.padding(6).disabled(state.busy)
                        }
                        if let report = state.benchmark { BenchmarkView(report: report) }
                    }.padding(.vertical,12)
                }.tabItem { Label("Pipeline",systemImage: "square.stack.3d.up") }
                ScrollView {
                    VStack(alignment: .leading) {
                        Text(state.hardware.text).font(.system(.body,design: .monospaced)).textSelection(.enabled)
                        Text("Build SDK: \(Bundle.main.object(forInfoDictionaryKey: "DTSDKName") as? String ?? "see LOCAL_HARDWARE.md") · Xcode build: \(Bundle.main.object(forInfoDictionaryKey: "DTXcodeBuild") as? String ?? "unknown") · Swift 6 language mode · deployment macOS 14.0")
                        Text("Vision optical flow: API available, experimental bounded tiles only.")
                        Text("GPU pipeline: 1 tile in flight, reusable RGBA16Uint textures and Float32 buffers.")
                        Text("Maximum 2048²; backend texture allocation validates dimensions. Working estimate 128 bytes/pixel including CPU validation.")
                    }.frame(maxWidth: .infinity,alignment: .leading).padding()
                }.tabItem { Label("Developer / Diagnostics",systemImage: "wrench.and.screwdriver") }
            }
            GroupBox("Status / log") {
                ScrollView { Text(state.log).font(.system(.caption,design: .monospaced))
                    .textSelection(.enabled).frame(maxWidth: .infinity,alignment: .leading) }
                .frame(height: 120)
            }
        }.padding(24)
    }
}
