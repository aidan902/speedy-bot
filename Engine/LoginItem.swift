// Launch at login through SMAppService (macOS 13+). No helper bundle, no entitlement, no sandbox needed.
import ServiceManagement

public enum LoginItem {
    public static var status: SMAppService.Status { SMAppService.mainApp.status }

    public static var statusText: String {
        switch status {
        case .notRegistered: return "notRegistered"
        case .enabled: return "enabled"
        case .requiresApproval: return "requiresApproval"   // user switched it off in System Settings > General > Login Items
        case .notFound: return "notFound"
        @unknown default: return "unknown"
        }
    }

    /// Call from the running .app (the main bundle is what gets registered). The system shows a "Login Item Added" notification.
    public static func set(enabled: Bool) throws {
        if enabled {
            if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
        } else {
            if SMAppService.mainApp.status != .notRegistered { try SMAppService.mainApp.unregister() }
        }
    }

    public static func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}
