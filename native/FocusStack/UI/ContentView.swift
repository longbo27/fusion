import FocusStackCore
import SwiftUI
import AppKit

struct ContentView: View {
    @Bindable var state: AppState
    var body: some View {
        VStack(alignment: .leading,spacing: 16) {
            Text("FocusStack Native").font(.largeTitle).fontWeight(.semibold)
            Text("V3 · Source-Faithful workspace").foregroundStyle(.secondary)
            TabView {
                WorkspaceView(state:state).tabItem{Label("Workspace",systemImage:"viewfinder")}
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
                                Toggle("Export bounded diagnostic previews",isOn:$state.exportDiagnostics).disabled(state.busy)
                                if let r=state.registrationDiagnostics{Text("Registration confidence \(String(format:"%.3f",r.registrationConfidence)) · ambiguous: \(r.registrationAmbiguous ? "yes":"no")")}
                                Text("Ambiguous registration is rejected. Parallax remains a limitation.").font(.caption).foregroundStyle(.secondary)
                                Text("AI predicts masks and captured-source ownership. Review motion boundaries; bokeh and blurred silhouettes remain difficult.").font(.caption).foregroundStyle(.secondary)
                                if state.busy{ProgressView(value:state.stackProgress);Button("Cancel"){state.cancel()}}
                                if let report=state.stackReport{Text("\(report.width)×\(report.height) · \(String(format:"%.2f",report.totalSeconds)) s · peak RSS \(report.memory.lifetimePeakBytes/1048576) MiB")}
                            }.padding(6)
                        }
                        if let directory=state.diagnosticDirectory {
                            GroupBox("Diagnostic preview") {
                                VStack {
                                    HStack{Picker("Map",selection:$state.diagnosticMap){Text("Ownership").tag("ownership_map");Text("Focus confidence").tag("focus_confidence");Text("Motion probability").tag("motion_probability")};Toggle("Motion overlay",isOn:$state.overlayMotion)}
                                    if let image=NSImage(contentsOf:directory.appendingPathComponent(state.diagnosticMap+".png")) {
                                        ZStack {
                                            Image(nsImage:image).resizable().scaledToFit()
                                            if state.overlayMotion,let mask=NSImage(contentsOf:directory.appendingPathComponent("motion_mask.png")){Image(nsImage:mask).resizable().scaledToFit().colorMultiply(.red).blendMode(.screen).opacity(0.5)}
                                        }.frame(maxHeight:320)
                                    }
                                    Text("Bounded 8-bit diagnostic preview; full-resolution photographic output remains RGB16.").font(.caption)
                                }
                            }
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
                        Text("Motion model: FocusMotionNetV1, 124,327 parameters, 12 candidate channels and 7 mask/ownership outputs. Core ML backend selected by local calibration. Compute plans describe preferred devices; no physical runtime trace is claimed.")
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
