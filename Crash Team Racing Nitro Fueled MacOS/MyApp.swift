import SwiftUI

@main
struct MyApp: App {
    @State private var store = LauncherStore()

    var body: some Scene {
        WindowGroup("CTR Nitro-Fueled") {
            ContentView(store: store)
                .frame(minWidth: 880, minHeight: 580)
        }
        .defaultSize(width: 1020, height: 680)
        .commands {
            CommandMenu("Game") {
                Button("Play CTR Nitro-Fueled") {
                    store.launchGame()
                }
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(!store.canLaunchGame)

                Button("Stop Running Game") {
                    store.stopRunningProcess()
                }
                .keyboardShortcut(".", modifiers: [.command])
                .disabled(!store.isGameRunning)

                Divider()

                Button("Clear Compiled Shader Cache") {
                    store.clearShaderCacheNow()
                }

                Button("Refresh System & Game Folders") {
                    store.refreshAllState()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }
    }
}
