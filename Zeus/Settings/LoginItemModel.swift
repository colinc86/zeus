import Observation
import ServiceManagement

/// Reflects the operating system's login-item status, including consent revoked in System Settings.
@MainActor
@Observable
final class LoginItemModel {
    private(set) var status = SMAppService.mainApp.status
    private(set) var error: String?
    private(set) var isUpdating = false
    var enabled: Bool { status == .enabled || status == .requiresApproval }

    func refresh() { status = SMAppService.mainApp.status }
    func setEnabled(_ enabled: Bool) async {
        guard !isUpdating else { return }
        isUpdating = true
        defer { isUpdating = false; refresh() }
        error = nil
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try await SMAppService.mainApp.unregister() }
        } catch { self.error = error.localizedDescription }
    }
    func openLoginSettings() { SMAppService.openSystemSettingsLoginItems() }
}
