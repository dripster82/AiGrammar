import Foundation
import ServiceManagement

/// Start AiGrammar automatically at login, via the modern SMAppService API (macOS 13+). Registers
/// the app bundle itself as a login item.
enum LaunchAtLogin {
    static var isEnabled: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                switch (newValue, SMAppService.mainApp.status) {
                case (true, let s) where s != .enabled:
                    try SMAppService.mainApp.register()
                    Log.write("Launch at login: enabled")
                case (false, .enabled):
                    try SMAppService.mainApp.unregister()
                    Log.write("Launch at login: disabled")
                default:
                    break
                }
            } catch {
                Log.write("Launch at login toggle failed: \(error.localizedDescription)")
            }
        }
    }
}
