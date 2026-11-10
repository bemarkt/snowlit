import Foundation
import SnowlitCore
import YingxueKit

typealias SourceInvocation = @MainActor (YingxueWire.OperationInput, SourceInstallationSnapshot) async throws -> YingxueWire.OperationReply

enum SourceBrowsingFailure: Error {
    case source(YingxueWire.OperationError), invalidReply, repeatedCursor
}

struct SourceBrowsingProblem: Identifiable {
    let id = UUID()
    let message: String
    let needsAuthentication: Bool

    init(_ error: any Error, fallback: String = "未能完成书源访问，请重试。已保存的阅读数据会保留。") {
        if case SourceBrowsingFailure.source(let error) = error, error.code == .needsAuthentication {
            message = "网站需要登录。请到书源管理完成登录，再重试。"; needsAuthentication = true
        } else if error is CatalogAssembly.Failure || error is LibraryModelError {
            message = "网站目录不完整或已变化，请重新获取。原有本地目录会保留。"; needsAuthentication = false
        } else {
            message = fallback; needsAuthentication = false
        }
    }
}

func checkedSourceReply(_ reply: YingxueWire.OperationReply, operation: YingxueWire.OperationName,
                        installation: SourceInstallationSnapshot) throws {
    _ = try YingxueWireCodec.encode(reply)
    guard reply.operation == operation,
          reply.context.installationID == installation.id.rawValue.uuidString.lowercased(),
          reply.context.scriptSHA256 == installation.scriptSHA256,
          reply.context.configurationRevision == installation.revision,
          reply.context.sessionRevision == installation.revision else { throw SourceBrowsingFailure.invalidReply }
    if case .failure(let reply) = reply { throw SourceBrowsingFailure.source(reply.error) }
}
