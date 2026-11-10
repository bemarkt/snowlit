import SwiftUI
import SnowlitCore

struct LibraryRootView: View {
    let sources: SourceLibraryModel
    let management: SourceManagementModel
    let candidateValidator: SourceCandidateValidator
    let runtime: SourceRuntime
    let authentication: SourceAuthenticationModel
    let search: SourceSearchModel
    let shelf: LibraryShelfModel
    let backup: BackupModel
    let makeBook: @MainActor (SourceSearchModel.Item) -> SourceBookModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView {
            LibraryShelfView(model: shelf)
                .tabItem { Label("书架", systemImage: "books.vertical") }
            SourceSearchView(model: search, sources: sources, makeBook: makeBook)
                .tabItem { Label("搜索", systemImage: "magnifyingglass") }
            SourceLibraryView(model: sources, management: management, candidateValidator: candidateValidator,
                authentication: authentication)
                .tabItem { Label("书源", systemImage: "network") }
            NavigationStack { BackupView(model: backup) }
                .tabItem { Label("备份", systemImage: "externaldrive") }
        }
        .background {
            if let session = runtime.active {
                SourceExecutionContainer(session: session).id(session.id).allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .sheet(item: Binding(get: { runtime.presentation }, set: { value in
            if value == nil { runtime.cancel() }
        })) { session in
            SourceExecutionView(session: session, cancel: { runtime.cancel() },
                retryCleanup: { try await runtime.retryCleanup() }, mountsSession: false)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { runtime.cancel(); candidateValidator.cancel(); search.cancel() }
        }
    }
}
