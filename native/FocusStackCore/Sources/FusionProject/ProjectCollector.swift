import Foundation
import FusionCore

/// Called sequentially by the processing actor. Lock protects snapshots and
/// prevents ownership assumptions from escaping through Sendable callbacks.
final class ProjectCollector:@unchecked Sendable {
    private let lock=NSLock(),directory:URL
    private var blocks=[ProvenanceBlock](),findings=[ArtifactFinding](),report=SourceFaithfulReport(),coverage=CoverageSummary()
    init(directory:URL){self.directory=directory}
    func add(_ tile:ProductEvidenceTile,_ output:RGB16Tile)throws {
        lock.lock();defer{lock.unlock()}
        let block=try ProvenanceStorage.write(tile,to:directory);blocks.append(block);report.merge(block.summary);coverage.merge(block.coverage)
        findings+=ArtifactSentinel.inspect(tile,output:output)
        // Fixed review queue cap, no unbounded pixel/component collection.
        if findings.count>512{findings=Array(findings.sorted{$0.severity==$1.severity ? $0.id<$1.id:$0.severity>$1.severity}.prefix(512))}
    }
    func result()->([ProvenanceBlock],[ArtifactFinding],SourceFaithfulReport,CoverageSummary){lock.lock();defer{lock.unlock()};return(blocks,findings,report,coverage)}
}
