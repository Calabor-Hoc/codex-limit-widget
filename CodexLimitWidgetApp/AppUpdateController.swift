import AppKit
import Combine
import Foundation

struct AppUpdateRelease: Equatable, Sendable {
    let version: String
    let pageURL: URL
}

/// Maestro builds are maintained manually. No release fetching, downloading,
/// archive extraction, installer script, or app replacement is implemented here.
@MainActor
final class AppUpdateController: ObservableObject {
    enum Phase: Equatable { case idle }
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var availableRelease: AppUpdateRelease? = nil

    static let projectURL = URL(string: "https://github.com/Calabor-Hoc/codex-limit-widget")!

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "--"
    }

    var isUpdateAvailable: Bool { false }
    var isBusy: Bool { false }
    var menuActionTitle: String { "Open Maestro project" }
    var menuStatusText: String? { nil }
    var settingsStatusText: String {
        "Maestro Limit is updated manually from its own project. Automatic update checks, downloads, and installation are disabled."
    }

    func start() {}
    // Keep the existing popover interface inert; it cannot install any app.
    func installAvailableUpdate() async {}
    func openReleasePage() { NSWorkspace.shared.open(Self.projectURL) }
}
