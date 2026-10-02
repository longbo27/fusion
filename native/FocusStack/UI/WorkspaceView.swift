import SwiftUI
import AppKit
import FusionCore
import FusionProject

struct WorkspaceView:View {
    @Bindable var state:AppState
    var body:some View {
        VStack {
            HStack {
                Picker("Workspace",selection:$state.workspaceMode){ForEach(["STACK","REVIEW","EDIT","EXPORT"],id:\.self){Text($0)}}.pickerStyle(.segmented)
                Button("Load Sources"){state.loadStack()}.disabled(state.busy)
                Button("Process"){state.runStack()}.disabled(state.busy||state.stackURLs.isEmpty)
                Button("Open Project"){state.openProject()};Button("Export"){state.exportProject()}.disabled(state.project==nil||state.busy)
            }
            HSplitView {
                VStack(alignment:.leading) {
                    Text("Sources").font(.headline)
                    List(selection:$state.selectedSource){ForEach(Array(state.stackURLs.enumerated()),id:\.offset){i,url in Text("Frame \(i+1) · \(url.lastPathComponent)").tag(i)}}
                    Button("Relink selected source"){state.relinkSource()}.disabled(state.project==nil||state.busy)
                    if state.sourceAvailability.indices.contains(state.selectedSource){Text(state.sourceAvailability[state.selectedSource]).font(.caption)}
                }.frame(minWidth:150,idealWidth:190,maxWidth:260)
                VStack {
                    Picker("Overlay",selection:$state.viewerOverlay){ForEach(["Final","Source Map","Motion Map","Focus Confidence","AI Uncertainty","Registration Confidence","Manual Overrides","Coverage","QA"],id:\.self){Text($0)}}
                    Picker("Compare",selection:$state.comparisonMode){ForEach(["Final","Split","Blink","Source"],id:\.self){Text($0)}}
                    if let image=state.previewImage {
                        HStack(spacing:2){
                            if !["Source","Blink"].contains(state.comparisonMode){ROIImageView(image:image,region:state.previewRegion,select:state.inspectLocation)}
                            if let source=state.sourcePreview,state.comparisonMode=="Split"||state.comparisonMode=="Source"{ROIImageView(image:source,region:state.previewRegion,select:state.inspectLocation)}
                            if state.comparisonMode=="Blink",let source=state.sourcePreview{TimelineView(.periodic(from:.now,by:0.6)){context in ROIImageView(image:Int(context.date.timeIntervalSince1970/0.6)%2==0 ? image:source,region:state.previewRegion,select:state.inspectLocation)}}
                        }
                    }else{ContentUnavailableView("Load or open a stack",systemImage:"square.stack.3d.up",description:Text("Source-Faithful mode uses captured frames and real-source blending."))}
                    HStack{Text("x");TextField("x",value:$state.pointX,format:.number).frame(width:70);Text("y");TextField("y",value:$state.pointY,format:.number).frame(width:70);Button("Inspect"){state.inspectLocation(x:state.pointX,y:state.pointY)}}
                    HStack{Button("Reference"){state.selectedSource=0;state.comparisonMode="Split"};Button("Best Focus"){state.selectedSource=state.selectedProvenance?.bestFocusCandidate ?? 0;state.comparisonMode="Split"};Button("Candidate 2"){state.selectedSource=state.selectedProvenance?.secondaryCandidate ?? 0;state.comparisonMode="Split"};Button("Candidate 3"){state.selectedSource=state.selectedProvenance?.thirdCandidate ?? 0;state.comparisonMode="Split"}}
                    Text("Bounded 512px ROI · 8-bit display preview only · RGB16 export retains ICC").font(.caption)
                }.frame(minWidth:320,maxWidth:.infinity)
                ScrollView {
                    VStack(alignment:.leading,spacing:10) {
                        Text("Source Provenance").font(.headline)
                        if let p=state.selectedProvenance {
                            Text("Primary owner/guide: Frame \(p.primarySource+1)")
                            Text("Secondary candidate: Frame \(p.secondaryCandidate+1)")
                            Text(p.contributionDescription).font(.caption)
                            if let weight=p.primaryContribution{Text("Hard ownership: \(weight*100,format:.number.precision(.fractionLength(1)))%")}
                            Text("Decision: \(String(describing:p.mode))")
                            Text("Focus confidence: \(p.focusConfidence*100,format:.number.precision(.fractionLength(1)))%")
                            Text("Motion: \(p.motionProbability.map{String(format:"%.1f%%",$0*100)} ?? "not evaluated")")
                            Text("Registration: \(p.registrationConfidence.map{String(format:"%.1f%%",$0*100)} ?? "not measured")")
                            Text("Manual edit: \(p.manualEdit ? "Yes":"No")")
                            Text(p.uncertainty.status).font(.headline)
                            Text("Coverage evidence: \(p.coverageConfidence*100,format:.number.precision(.fractionLength(1)))% · uncalibrated")
                        }
                        if let m=state.productManifest {
                            Text("Source-Faithful: \(m.complete && m.report.sourceFaithful ? "YES":"incomplete") · generative photographic pixels: \(m.report.generativePhotographicPixels)")
                            Text("Real-source blend: \(m.report.percentage(m.report.realSourceBlend),format:.number.precision(.fractionLength(1)))%")
                            Text("Hard ownership: \(m.report.percentage(m.report.hardOwnership),format:.number.precision(.fractionLength(1)))% · AI ownership: \(m.report.percentage(m.report.aiOwnership),format:.number.precision(.fractionLength(1)))%")
                            Text("Reference fallback: \(m.report.percentage(m.report.referenceFallback),format:.number.precision(.fractionLength(1)))%")
                            Text("Manual: \(m.report.percentage(m.report.manuallyOverridden),format:.number.precision(.fractionLength(1)))% · low confidence: \(m.report.percentage(m.report.lowConfidence),format:.number.precision(.fractionLength(1)))%")
                            Text("Coverage evidence ≥ threshold: \(m.coverage.coveragePercent,format:.number.precision(.fractionLength(1)))%")
                            Text("\(m.findings.filter{!$0.reviewed}.count) retained regions require review")
                            Text("History: \(m.history.count) logical operations")
                            if state.workspaceMode=="REVIEW" {
                                HStack{Button("Previous"){state.jumpFinding(-1)};Button("Next"){state.jumpFinding(1)}}
                                ForEach(Array(m.findings.enumerated()),id:\.element.id){i,f in Button("\(f.type.rawValue) · \(String(format:"%.2f",f.severity))"){state.selectedFinding=i;state.jumpFinding(0)}}
                                Button("Accept Auto"){state.reviewFinding("acceptAuto")};Button("Ignore Finding"){state.reviewFinding("ignore")};Button("Mark Reviewed"){state.reviewFinding("markReviewed")}
                            }
                        }
                        if state.workspaceMode=="EDIT" {
                            Stepper("Region \(state.brushSize)px",value:$state.brushSize,in:8...128,step:8)
                            Button("Use Auto"){state.applyOwnership(.auto)};Button("Use Best Focus"){state.applyOwnership(.bestFocus)};Button("Use Reference"){state.applyOwnership(.reference)};Button("Use Selected Source"){state.applyOwnership(.source(state.selectedSource))};Button("Exclude Selected Source"){state.applyOwnership(.exclude(state.selectedSource))};Button("Lock Ownership"){state.applyOwnership(.lock(state.selectedProvenance?.primarySource ?? 0))};Button("Clear Override"){state.clearOverride()}
                        }
                        Text("Coverage/QA are heuristic review aids. V2.2 photographic AI limitations remain.").font(.caption).foregroundStyle(.secondary)
                    }.padding(8)
                }.frame(minWidth:240,idealWidth:280,maxWidth:380).disabled(state.busy)
            }
        }.onChange(of:state.viewerOverlay){Task{await state.refreshPreview()}}.onChange(of:state.comparisonMode){Task{await state.refreshPreview()}}.onChange(of:state.selectedSource){Task{await state.refreshPreview()}}
    }
}

private struct ROIImageView:View {
    let image:NSImage,region:TileDescriptor?
    let select:(Int,Int)->Void
    private let coordinateID=UUID()
    var body:some View {
        GeometryReader{g in
            let aspect=image.size.width/image.size.height,w=min(g.size.width,g.size.height*aspect),h=w/aspect
            Image(nsImage:image).resizable().frame(width:w,height:h).position(x:g.size.width/2,y:g.size.height/2)
                .onTapGesture(coordinateSpace:.named(coordinateID)){point in
                    guard let r=region,w>0,h>0 else{return}
                    let left=(g.size.width-w)/2,top=(g.size.height-h)/2
                    let x=point.x-left,y=point.y-top
                    guard x>=0,y>=0,x<w,y<h else{return}
                    select(r.x+Int(x/w*Double(r.width)),r.y+Int(y/h*Double(r.height)))
                }
        }.coordinateSpace(name:coordinateID).frame(minHeight:200)
    }
}
