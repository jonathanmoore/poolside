import SwiftUI

@main
struct PoolsideApp: App {
    @State private var store: PoolStore = {
        #if DEBUG
        // Launch with -demo for sample data that never touches the pool (screenshots, demos).
        if ProcessInfo.processInfo.arguments.contains("-demo") { return .preview }
        #endif
        return PoolStore()
    }()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
        }
    }
}

struct RootView: View {
    @Environment(PoolStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if store.login == nil {
                SignInView()
            } else {
                DashboardView()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: store.resume()
            case .background: store.suspend()
            default: break
            }
        }
        .onAppear { store.resume() }
    }
}
