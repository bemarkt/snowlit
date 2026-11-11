import SwiftUI
import SnowlitCore
import YingxueKit

struct SourceManagementView: View {
    let item: SourceLibraryModel.SavedImport
    let library: SourceLibraryModel
    let management: SourceManagementModel
    let candidateValidator: SourceCandidateValidator
    let authentication: SourceAuthenticationModel
    @State private var adoption: SourceManagementModel.Candidate?
    @State private var showRemoval = false
    @State private var removalExpected: SourceInstallationSnapshot?
    @State private var prepareRequest = 0
    @State private var actionRequest: ActionRequest?
    @State private var showLogin = false
    @State private var loginExpected: SourceInstallationSnapshot?
    @State private var loginRequest = 0

    private struct ActionRequest: Identifiable {
        let id = UUID()
        let action: SourceManagementModel.Action
        let expected: SourceInstallationSnapshot
    }

    private var installed: SourceInstallationSnapshot? {
        library.installations.first { $0.metadata.sourceID.utf8.elementsEqual(item.script.metadata.sourceID.utf8) }
    }

    var body: some View {
        List {
            Section("书源") {
                Text(item.script.metadata.name).font(.title2.bold())
                LabeledContent("候选版本", value: item.script.metadata.scriptVersion)
                LabeledContent("标识", value: item.script.metadata.sourceID).textSelection(.enabled)
                if let installed {
                    LabeledContent("已安装版本", value: installed.metadata.scriptVersion)
                    Text(status(installed)).foregroundStyle(.secondary)
                }
                NavigationLink("查看完整脚本与来源") {
                    SourceScriptDetailView(script: item.script, receipt: item.receipt)
                }
            }
            if let problem = management.problem, adoption == nil {
                Section {
                    Text(problem.message).accessibilityIdentifier("sources.management.failure")
                    Text("错误编号：\(problem.id.uuidString)")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    if let diagnostic = problem.diagnostic {
                        SourceDiagnosticDisclosure(diagnostic: diagnostic)
                    }
                }
            }
            if let installed, installed.pendingCleanup != nil {
                Section("登录数据待清理") {
                    Text("阅读数据已保留。完成清理后才能重新启用或恢复关联。")
                    Button("重试清理") { request(.retryCleanup, installed) }
                        .frame(minHeight: 44).accessibilityIdentifier("sources.cleanup")
                }
            } else if let installed, installed.scriptSHA256 == item.script.sha256, installed.state != .removed {
                Section("管理") {
                    if installed.canExecute && !item.manifest.authentication.isEmpty {
                        if let result = authentication.result(for: installed) { Text(result.message).accessibilityIdentifier("sources.authentication.result") }
                        Button("登录或重新登录网站") { loginExpected = installed; showLogin = true }
                            .frame(minHeight: 44).accessibilityIdentifier("sources.authenticate")
                        if authentication.busy == installed.id { ProgressView("正在准备网站登录…") }
                        if let problem = authentication.problem { Text(problem).accessibilityIdentifier("sources.authentication.failure") }
                        if let diagnostic = authentication.diagnostic {
                            SourceDiagnosticDisclosure(diagnostic: diagnostic)
                        }
                    }
                    Button(installed.state == .enabled ? "停用书源" : "启用书源") {
                        request(installed.state == .enabled ? .disable : .enable, installed)
                    }
                    .frame(minHeight: 44).accessibilityIdentifier("sources.toggle-enabled")
                    Button("退出网站登录") { request(.signOut, installed) }
                        .frame(minHeight: 44).accessibilityIdentifier("sources.sign-out")
                    Button("删除书源", role: .destructive) { removalExpected = installed; showRemoval = true }
                        .frame(minHeight: 44).accessibilityIdentifier("sources.remove")
                }
            } else {
                Section {
                    Text(installed?.state == .removed ? "核对并确认恢复本机保存的书籍关联，验证成功后生效。" : "先核对版本、设置与访问权限；确认后验证，通过才会采用。")
                        .foregroundStyle(.secondary)
                    Button("核对并准备采用") { prepareRequest += 1 }
                        .frame(minHeight: 44).accessibilityIdentifier("sources.prepare")
                }
            }
            if management.isPreparing || management.isChanging {
                Section { ProgressView(management.isPreparing ? "正在准备确认…" : "正在更新书源…") }
            }
        }
        .navigationTitle("管理书源")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(management.isChanging || authentication.busy != nil)
        .task(id: prepareRequest) {
            guard prepareRequest > 0 else { return }
            await management.prepare(importID: item.id)
            adoption = management.candidate
        }
        .task(id: actionRequest?.id) {
            if let actionRequest { await management.perform(actionRequest.action, expected: actionRequest.expected) }
        }
        .task(id: management.changed) { await library.refresh() }
        .task(id: authentication.changed) { await library.refresh() }
        .task(id: loginRequest) {
            if loginRequest > 0, let loginExpected { await authentication.authenticate(expected: loginExpected) }
        }
        .onDisappear { management.cancelPreparation() }
        .sheet(item: $adoption, onDismiss: { management.cancelPreparation() }) { candidate in
            SourceAdoptionView(candidate: candidate, management: management, validator: candidateValidator)
        }
        .confirmationDialog("删除这个书源？", isPresented: $showRemoval, titleVisibility: .visible) {
            if let installed = removalExpected {
                Button("删除书源，保留阅读数据", role: .destructive) { request(.remove, installed) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("本机书籍、目录、阅读进度和已保存正文会保留；网站登录数据会清理。")
        }
        .confirmationDialog("开始网站登录？", isPresented: $showLogin, titleVisibility: .visible) {
            Button("退出原网站会话并登录") { loginRequest += 1 }
            Button("取消", role: .cancel) {}
        } message: {
            Text("每个书源保留一组网站登录。继续会先清理本机保存的网站会话；书架、进度和正文缓存保留。")
        }
    }

    private func request(_ action: SourceManagementModel.Action, _ installation: SourceInstallationSnapshot) {
        actionRequest = .init(action: action, expected: installation)
    }

    private func status(_ installation: SourceInstallationSnapshot) -> String {
        if installation.pendingCleanup != nil { return "登录数据尚待清理" }
        switch installation.state {
        case .enabled: return "已启用"
        case .disabled: return "已停用"
        case .removed: return "已删除，阅读数据保留在本机"
        }
    }
}

private struct SourceAdoptionView: View {
    let candidate: SourceManagementModel.Candidate
    let management: SourceManagementModel
    let validator: SourceCandidateValidator
    @Environment(\.dismiss) private var dismiss
    @State private var allowCredentialRead = false
    @State private var restoreAssociation = false
    @State private var configuration: [SourceSettingValue]
    @State private var acknowledgedChanges: Set<Data> = []
    @State private var confirmRequest = 0

    init(candidate: SourceManagementModel.Candidate, management: SourceManagementModel, validator: SourceCandidateValidator) {
        self.candidate = candidate; self.management = management; self.validator = validator
        _configuration = State(initialValue: candidate.configuration)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("确认版本") {
                    Text(candidate.manifest.name).font(.title2.bold())
                    LabeledContent("版本", value: candidate.manifest.scriptVersion)
                    LabeledContent("标识", value: candidate.manifest.sourceID).textSelection(.enabled)
                    if let previous = candidate.existing {
                        LabeledContent("原版本", value: previous.metadata.scriptVersion)
                    }
                    DisclosureGroup("脚本摘要") {
                        Text(candidate.script.sha256).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    }
                }
                Section("网站访问范围") {
                    if candidate.manifest.origins.isEmpty { Text("未声明网站访问") }
                    ForEach(Array(candidate.manifest.origins.enumerated()), id: \.offset) { _, origin in
                        Text("\(origin.scheme.rawValue)://\(origin.host)\(origin.port.map { ":\($0)" } ?? "")")
                            .textSelection(.enabled)
                    }
                }
                if !candidate.manifest.capabilities.isEmpty || !candidate.manifest.authentication.isEmpty {
                    Section("书源能力") {
                        ForEach(candidate.manifest.capabilities, id: \.self) { capability in
                            Text(capabilityLabel(capability))
                        }
                        ForEach(candidate.manifest.authentication, id: \.self) { authentication in
                            Text(authentication == .web ? "网页登录与验证" : "表单登录")
                        }
                    }
                }
                if candidate.plan?.referenceInputs.isEmpty == false || candidate.plan?.stateInput != nil {
                    Section("已有数据") {
                        Text("采用时将同时更新书源引用或公有状态。已保存正文与阅读位置保留原有身份。")
                            .font(.subheadline)
                    }
                }
                if !candidate.configurationChanges.isEmpty {
                    Section("需要确认的设置变化") {
                        Text("兼容设置已保留。以下旧设置无法直接沿用，请核对新版默认值，并在书源设置中填写需要的新值。只有成功采用后才会替换旧设置。")
                            .font(.subheadline).foregroundStyle(.secondary)
                        ForEach(candidate.configurationChanges) { change in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(change.label).font(.headline)
                                Text(change.previous.key).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                Text(changeReason(change.reason)).font(.subheadline)
                                LabeledContent("旧值", value: settingText(change.previous))
                                if let proposed = change.proposedDefault {
                                    LabeledContent("新版默认值", value: settingText(proposed))
                                    if let selected = configuration.first(where: { Data($0.key.utf8) == change.id }) {
                                        LabeledContent("本次将使用", value: settingText(selected))
                                    }
                                } else {
                                    Text("新版已无此设置，采用成功后将移除旧值。")
                                }
                                Toggle(change.proposedDefault == nil ? "确认移除此设置" : "确认替换为本次填写的值",
                                       isOn: acknowledgementBinding(change.id))
                                    .frame(minHeight: 44)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
                if !candidate.manifest.publicConfiguration.isEmpty {
                    Section("书源设置") {
                        ForEach(Array(candidate.manifest.publicConfiguration.enumerated()), id: \.offset) { _, setting in
                            switch setting {
                            case .text(let field):
                                TextField(field.label, text: textBinding(field.key, initial: field.initial), axis: .vertical)
                                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                            case .boolean(let field):
                                Toggle(field.label, isOn: flagBinding(field.key, initial: field.initial))
                            case .choice(let field):
                                Picker(field.label, selection: textBinding(field.key, initial: field.initial)) {
                                    ForEach(Array(field.choices.enumerated()), id: \.offset) { _, choice in
                                        Text(choice.label).tag(choice.value)
                                    }
                                }
                            }
                        }
                    }
                }
                if candidate.requestsCredentialRead {
                    Section("明文凭据权限") {
                        Toggle("允许此版本读取明文凭据", isOn: $allowCredentialRead)
                            .accessibilityIdentifier("sources.consent-credentials")
                        Text("默认由应用代管凭据。开启后，此书源脚本可以读取已授权的凭据内容；更新版本需要重新确认。")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                if candidate.restoresAssociation {
                    Section("恢复本地关联") {
                        Text("该标识原有 \(candidate.retainedBooks) 本本机书籍。")
                        Toggle("恢复这些书籍与此书源的关联", isOn: $restoreAssociation)
                            .accessibilityIdentifier("sources.consent-restore")
                        Text("网站登录需要重新完成。取消会保留候选和原阅读数据。")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                if let problem = management.problem {
                    Section {
                        Text(problem.message).accessibilityIdentifier("sources.adoption.failure")
                        Text("错误编号：\(problem.id.uuidString)").font(.caption).textSelection(.enabled)
                        if let diagnostic = problem.diagnostic {
                            SourceDiagnosticDisclosure(diagnostic: diagnostic)
                        }
                    }
                }
                Section {
                    Button { confirmRequest += 1 } label: {
                        HStack {
                            if management.isChanging || management.isValidating { ProgressView() }
                            Text(management.isValidating ? "正在验证…" : management.isChanging ? "正在采用…" : "验证并采用此版本")
                        }.frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(management.isChanging || management.isValidating || (candidate.restoresAssociation && !restoreAssociation)
                        || acknowledgedChanges != Set(candidate.configurationChanges.map(\.id)) || management.candidate == nil)
                    .accessibilityIdentifier("sources.confirm-adoption")
                }
            }
            .disabled(management.isChanging || management.isValidating)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("确认书源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { management.cancelPreparation(); dismiss() }
                        .frame(minWidth: 44, minHeight: 44).disabled(management.isChanging)
                }
            }
        }
        .interactiveDismissDisabled()
        .sheet(item: Binding(get: { validator.active }, set: { value in
            if value == nil { validator.cancel() }
        })) { session in
            SourceCandidateView(validator: validator, session: session)
        }
        .task(id: confirmRequest) {
            guard confirmRequest > 0 else { return }
            await management.confirm(candidateID: candidate.id, allowCredentialRead: allowCredentialRead,
                restoreAssociation: restoreAssociation, configuration: configuration,
                acknowledgedConfigurationChanges: acknowledgedChanges)
            if management.candidate == nil && management.problem == nil { dismiss() }
        }
    }

    private func textBinding(_ key: String, initial: String) -> Binding<String> {
        Binding {
            guard let setting = configuration.first(where: { $0.key.utf8.elementsEqual(key.utf8) }),
                  case .text(_, let value) = setting else { return initial }
            return value
        } set: { value in
            configuration.removeAll { $0.key.utf8.elementsEqual(key.utf8) }
            configuration.append(.text(key: key, value: value))
            acknowledgedChanges.remove(Data(key.utf8))
        }
    }

    private func acknowledgementBinding(_ id: Data) -> Binding<Bool> {
        Binding { acknowledgedChanges.contains(id) } set: { accepted in
            if accepted { acknowledgedChanges.insert(id) } else { acknowledgedChanges.remove(id) }
        }
    }

    private func settingText(_ value: SourceSettingValue) -> String {
        switch value {
        case .text(_, let text): text.isEmpty ? "（空）" : text
        case .boolean(_, let flag): flag ? "开启" : "关闭"
        }
    }

    private func changeReason(_ reason: SourceManagementModel.ConfigurationChange.Reason) -> String {
        switch reason {
        case .removed: "新版移除了这个设置。"
        case .typeChanged: "新版改变了这个设置的类型。"
        case .choiceRemoved: "原来选中的选项已不在新版中。"
        }
    }

    private func capabilityLabel(_ capability: YingxueWire.Capability) -> String {
        switch capability {
        case .http: "网站网络请求"
        case .dom: "解析网页内容"
        case .browser: "打开动态网页并提取内容"
        case .publicState: "保存书源公有状态"
        case .credentialsRead: "读取明文凭据（需要下方单独授权）"
        }
    }

    private func flagBinding(_ key: String, initial: Bool) -> Binding<Bool> {
        Binding {
            guard let setting = configuration.first(where: { $0.key.utf8.elementsEqual(key.utf8) }),
                  case .boolean(_, let value) = setting else { return initial }
            return value
        } set: { value in
            configuration.removeAll { $0.key.utf8.elementsEqual(key.utf8) }
            configuration.append(.boolean(key: key, value: value))
            acknowledgedChanges.remove(Data(key.utf8))
        }
    }
}

struct SourceDiagnosticDisclosure: View {
    let diagnostic: SourceDiagnostic

    var body: some View {
        DisclosureGroup("诊断报告（可分享）") {
            Text(diagnostic.shareableText)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
            ShareLink(item: diagnostic.shareableText) {
                Label("分享诊断报告", systemImage: "square.and.arrow.up")
            }
            .frame(minHeight: 44)
        }
        .accessibilityIdentifier("source.diagnostic")
    }
}
