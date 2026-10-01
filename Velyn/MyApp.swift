import SwiftUI

@main struct MyApp: App {
    @AppStorage(L10n.preferenceKey) private var language = AppLanguage.system.rawValue
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.locale,Locale(identifier: (AppLanguage(rawValue: language) ?? .system).resolvedCode()))
                #if DEBUG
                .task {
                    if ProcessInfo.processInfo.arguments.contains("--gain-benchmark") {
                        await GainMapBenchmark.shared.runBundled()
                    }
                }
                #endif
        }
    }
}
