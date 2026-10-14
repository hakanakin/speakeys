import AppKit
import UserNotifications

/// Checks the website for a newer version at most once a day and tells the user about it once.
/// Sends nothing but a plain GET for a small JSON file.
final class UpdateChecker: NSObject, UNUserNotificationCenterDelegate {
    struct Release: Decodable {
        let version: String
        let url: URL
        let notes: String?
    }

    /// Set when a newer version than the running one is published.
    private(set) var available: Release?
    var onAvailableChange: (() -> Void)?

    private static let feedURL = URL(string: "https://speakeys.akins.app/version.json")!
    private static let checkInterval: TimeInterval = 24 * 60 * 60
    private static let pollInterval: TimeInterval = 60 * 60

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    private let settings: Settings
    private var timer: Timer?

    init(settings: Settings) {
        self.settings = settings
        super.init()
    }

    func start() {
        UNUserNotificationCenter.current().delegate = self
        checkIfDue()
        // Macs stay awake for days, so look again every hour whether a day has passed
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in self?.checkIfDue() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// "Check for Updates…" from the menu: always checks and always answers.
    func checkNow() {
        check(userInitiated: true)
    }

    func openDownload() {
        if let url = available?.url { NSWorkspace.shared.open(url) }
    }

    // MARK: Checking

    private func checkIfDue() {
        guard settings.checksForUpdates else { return }
        if let last = settings.lastUpdateCheck, Date().timeIntervalSince(last) < Self.checkInterval { return }
        check(userInitiated: false)
    }

    private func check(userInitiated: Bool) {
        let request = URLRequest(url: Self.feedURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            let release = data.flatMap { try? JSONDecoder().decode(Release.self, from: $0) }
            DispatchQueue.main.async {
                self?.finishCheck(release: release, error: error, userInitiated: userInitiated)
            }
        }.resume()
    }

    private func finishCheck(release: Release?, error: Error?, userInitiated: Bool) {
        guard let release else {
            Log.error("update check failed: \(error.map { "\($0)" } ?? "unreadable version.json")")
            if userInitiated { showAlert(title: "Couldn't check for updates", text: "Please try again later.") }
            return
        }
        settings.lastUpdateCheck = Date()

        let isNewer = release.version.compare(Self.currentVersion, options: .numeric) == .orderedDescending
        available = isNewer ? release : nil
        onAvailableChange?()

        if !isNewer {
            if userInitiated {
                showAlert(title: "You're up to date", text: "Speakeys \(Self.currentVersion) is the latest version.")
            }
        } else if userInitiated {
            showUpdateAlert(release)
        } else if settings.lastNotifiedVersion != release.version {
            settings.lastNotifiedVersion = release.version
            postNotification(release)
        }
    }

    // MARK: Telling the user

    private func postNotification(_ release: Release) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Speakeys \(release.version) is available"
            content.body = release.notes ?? "Click to download the new version."
            content.userInfo = ["url": release.url.absoluteString]
            center.add(UNNotificationRequest(identifier: "update-\(release.version)", content: content, trigger: nil))
        }
    }

    private func showUpdateAlert(_ release: Release) {
        let alert = NSAlert()
        alert.messageText = "Speakeys \(release.version) is available"
        alert.informativeText = (release.notes.map { $0 + "\n\n" } ?? "") + "You have version \(Self.currentVersion)."
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(release.url) }
    }

    private func showAlert(title: String, text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: UNUserNotificationCenterDelegate

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let link = response.notification.request.content.userInfo["url"] as? String, let url = URL(string: link) {
            NSWorkspace.shared.open(url)
        }
        completionHandler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
