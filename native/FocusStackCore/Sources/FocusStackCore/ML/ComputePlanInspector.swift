import CoreML
import Foundation

public struct OperationPlacement: Sendable {
    public let operation: String
    public let preferred: String
    public let supported: [String]
    public let estimatedCostWeight: Double?
}
public actor ComputePlanInspector {
    public init() {}
    public func inspect(compiledModelURL: URL,computeUnits:PrototypeComputeUnits = .all) async throws -> [OperationPlacement] {
        guard #available(macOS 14.4, iOS 17.4, *) else { throw NativeError.unavailable("MLComputePlan requires macOS 14.4") }
        let configuration=MLModelConfiguration();configuration.computeUnits=computeUnits.units
        let plan = try await MLComputePlan.load(contentsOf: compiledModelURL, configuration: configuration)
        var reports: [OperationPlacement] = []
        func visit(_ block: MLModelStructure.Program.Block) {
            for operation in block.operations {
                let usage = plan.deviceUsage(for: operation)
                reports.append(OperationPlacement(operation: operation.operatorName,
                    preferred: usage.map { MLHardwareInspector.label($0.preferred) } ?? "unknown",
                    supported: usage?.supported.map { MLHardwareInspector.label($0) } ?? [],
                    estimatedCostWeight: plan.estimatedCost(of: operation)?.weight))
                for nested in operation.blocks { visit(nested) }
            }
        }
        func visitStructure(_ structure: MLModelStructure) {
        switch structure {
        case .program(let program):
            for (_, function) in program.functions { visit(function.block) }
        case .neuralNetwork(let network):
            for layer in network.layers {
                let usage = plan.deviceUsage(for: layer)
                reports.append(OperationPlacement(operation: layer.name,
                    preferred: usage.map { MLHardwareInspector.label($0.preferred) } ?? "unknown",
                    supported: usage?.supported.map { MLHardwareInspector.label($0) } ?? [],estimatedCostWeight: nil))
            }
        case .pipeline(let pipeline): for submodel in pipeline.subModels { visitStructure(submodel) }
        case .unsupported: break
        @unknown default: break
        }
        }
        visitStructure(plan.modelStructure)
        return reports
    }
}
