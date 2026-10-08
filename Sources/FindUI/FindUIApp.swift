import SearchBackend
import SwiftUI

@main
struct FindUIApp: App {
    @NSApplicationDelegateAdaptor(FindUIApplicationDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SearchSettingsHost(windows: appDelegate.windows)
        }
        .windowResizability(.contentMinSize)
        .commands { SearchWindowCommands(windows: appDelegate.windows) }
    }
}

private struct SearchSettingsHost: View {
    @ObservedObject var windows: SearchWindowManager
    var body: some View {
        SettingsView(viewModel: windows.activeViewModel ?? windows.settingsFallback)
    }
}
