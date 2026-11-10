import Foundation

/// Bundled execution candidate. Platform owners provide a mounted WebKit view;
/// neither these programs nor the source receive a database or credential store.
public struct SourceExecutionProgram: Sendable {
    public let bootstrap: String
    public let parent: String
    let methods: [String]

    public init() throws {
        guard let worker = Bundle.module.url(forResource: "worker", withExtension: "js", subdirectory: "SourceExecution"),
              let parent = Bundle.module.url(forResource: "parent", withExtension: "js", subdirectory: "SourceExecution") else {
            throw Failure.missingProgram
        }
        bootstrap = try String(contentsOf: worker, encoding: .utf8)
        self.parent = try String(contentsOf: parent, encoding: .utf8)
        methods = GeneratedModulePolicy.hostMethods
    }

    private enum Failure: Error { case missingProgram }
}
