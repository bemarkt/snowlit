import SwiftUI
import YingxueKit

/// Attach at the operation's presentation surface. Dismissal targets the model
/// captured by that sheet, so a delayed dismiss cannot close a newer form.
struct SourceFormPresentation: ViewModifier {
    let session: SourceFormSession

    func body(content: Content) -> some View {
        let presented = session.form
        return content.sheet(item: Binding(get: { presented }, set: { value in
            if value == nil { presented?.invalidate() }
        })) { model in
            SourceFormView(model: model)
        }
    }
}

struct SourceFormView: View {
    let model: SourceFormModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Data?
    @State private var submitRequest = 0
    @State private var cancelRequest = 0

    var body: some View {
        NavigationStack {
            ScrollViewReader { scroll in
                Form {
                    Section("书源") {
                        Text(model.sourceName).font(.headline)
                        Text(model.sourceID).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        Text("提交后仍需书源验证网站登录状态。")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    Section(model.form.title) {
                        ForEach(Array(model.form.fields.enumerated()), id: \.offset) { index, field in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(field.formLabel + (field.formRequired ? "（必填）" : "（选填）"))
                                    .font(.subheadline)
                                switch field {
                                case .publicText:
                                    Text("普通文本，将发送给此书源").font(.caption).foregroundStyle(.secondary)
                                case .secret:
                                    Text("秘密字段，由应用代管").font(.caption).foregroundStyle(.secondary)
                                }
                                Group {
                                    switch field {
                                    case .publicText:
                                        TextField(field.formLabel, text: binding(field.formKey))
                                    case .secret:
                                        SecureField(field.formLabel, text: binding(field.formKey))
                                    }
                                }
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                                .frame(minHeight: 44).focused($focused, equals: Data(field.formKey.utf8))
                                .accessibilityIdentifier("sources.form.field.\(index)")
                            }
                            .id(Data(field.formKey.utf8))
                        }
                    }
                    .disabled(model.phase != .editing)
                    if !model.form.credentialOrigins.isEmpty {
                        Section("凭据使用网站") {
                            Text(model.allowsCredentialRead
                                ? "此版本已获明文读取权限，可以读取提交的秘密字段。"
                                : "此版本未获明文读取权限，凭据由应用代填。")
                                .font(.subheadline).foregroundStyle(.secondary)
                            ForEach(Array(model.form.credentialOrigins.enumerated()), id: \.offset) { _, origin in
                                Text("\(origin.scheme.rawValue)://\(origin.host)\(origin.port.map { ":\($0)" } ?? "")")
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    if let message = model.message {
                        Section {
                            Text(message).accessibilityIdentifier("sources.form.failure")
                            if model.phase == .cancelling {
                                Button("重试清理") { cancelRequest += 1 }.frame(minHeight: 44)
                            }
                        }
                    }
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: focused) { _, key in
                    if let key { withAnimation { scroll.scrollTo(key, anchor: .center) } }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    focused = nil; submitRequest += 1
                } label: {
                    HStack {
                        if model.phase == .submitting || model.phase == .cancelling { ProgressView() }
                        Text(model.phase == .submitting ? "正在提交…" : model.phase == .cancelling ? "正在取消…" : "提交")
                    }.frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent).disabled(model.phase != .editing)
                .accessibilityIdentifier("sources.form.submit")
                .padding(.horizontal).padding(.vertical, 8).background(.bar)
            }
            .navigationTitle("网站表单")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { focused = nil; cancelRequest += 1 }
                        .frame(minWidth: 44, minHeight: 44)
                        .disabled(model.phase == .cancelling || model.isFinished)
                        .accessibilityIdentifier("sources.form.cancel")
                }
            }
        }
        .interactiveDismissDisabled()
        .task(id: submitRequest) {
            if submitRequest > 0 { await model.submit() }
        }
        .task(id: cancelRequest) {
            guard cancelRequest > 0 else { return }
            if model.phase == .cancelling { await model.retryCancellation() }
            else { await model.cancel() }
        }
        .onChange(of: model.isFinished) { _, finished in if finished { dismiss() } }
        .onDisappear { model.invalidate() }
    }

    private func binding(_ key: String) -> Binding<String> {
        Binding { model.value(for: key) } set: { model.setValue($0, for: key) }
    }
}
