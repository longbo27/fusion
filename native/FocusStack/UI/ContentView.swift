import FocusStackCore
import SwiftUI

struct ContentView: View {
    @Bindable var state: AppState
    var body: some View {
        VStack(alignment: .leading,spacing: 16) {
            Text("FocusStack Native").font(.largeTitle).fontWeight(.semibold)
            Text("Native V2.1 · Production I/O and Metal core").foregroundStyle(.secondary)
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
                        GroupBox("Focus stack") {
                            VStack(alignment:.leading) {
                                HStack{Button("Load Stack"){state.loadStack()};Text("\(state.stackURLs.count) sources");Button("Stack to TIFF"){state.runStack()}.disabled(state.stackURLs.isEmpty)}.disabled(state.busy)
                                HStack{
                                    Picker("Quality",selection:$state.quality){Text("Standard").tag(StackQuality.standard);Text("High").tag(StackQuality.high);Text("Maximum").tag(StackQuality.maximum)}
                                    Picker("AI Deghost",selection:$state.aiMode){ForEach(AIDeghostMode.allCases,id:\.self){Text($0.rawValue.capitalized).tag($0)}}
                                    Text("Hardware: Auto")
                                }.disabled(state.busy)
                                Text("Registration is experimental; repeated patterns and parallax need review.").font(.caption).foregroundStyle(.secondary)
                                Text("AI: synthetic motion-mask prototype; Off recommended for photographic evaluation.").font(.caption).foregroundStyle(.secondary)
                                if state.busy{ProgressView(value:state.stackProgress);Button("Cancel"){state.cancel()}}
                                if let report=state.stackReport{Text("\(report.width)×\(report.height) · \(String(format:"%.2f",report.totalSeconds)) s · peak RSS \(report.memory.lifetimePeakBytes/1048576) MiB")}
                            }.padding(6)
                        }
                        if let report = state.benchmark { BenchmarkView(report: report) }
                    }.padding(.vertical,12)
                }.tabItem { Label("Pipeline",systemImage: "square.stack.3d.up") }
                ScrollView {
                    VStack(alignment: .leading) {
                        Text(state.hardware.text).font(.system(.body,design: .monospaced)).textSelection(.enabled)
                        Text("Build SDK: \(Bundle.main.object(forInfoDictionaryKey: "DTSDKName") as? String ?? "see LOCAL_HARDWARE.md") · Xcode build: \(Bundle.main.object(forInfoDictionaryKey: "DTXcodeBuild") as? String ?? "unknown") · Swift 6 language mode · deployment macOS 14.0")
                        Text("Vision optical flow: API available, experimental bounded tiles only.")
                        Text("Production pipeline: bounded libtiff ROI, one tile in flight, Float32 focus/depth/multiband. Shared macOS/iOS/iPadOS engine.")
                        Text("Motion model: 3,194 parameters, masks only; Core ML .all, independent Metal ML experiment available in benchmark tool. No definitive runtime device trace is claimed.")
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
