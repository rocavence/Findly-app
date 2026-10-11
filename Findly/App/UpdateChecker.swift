import Foundation

/// Once a day, asks GitHub for the newest release. Nothing downloads by itself:
/// a newer version shows up in the menu and in Settings › About, and opens its
/// page when chosen.
@MainActor
@Observable
final class UpdateChecker {
    struct Release: Equatable, Sendable {
        var version: String
        var page: URL
    }

    enum State: Equatable {
        case idle, checking, upToDate, failed
        case available(Release)
    }

    static let releases = URL(string: "https://github.com/rocavence/Findly-app/releases/latest")!
    private static let api = URL(string: "https://api.github.com/repos/rocavence/Findly-app/releases/latest")!
    private static let checkedKey = "Findly.updateCheckedAt"

    private(set) var state: State = .idle
    @ObservationIgnored var onChange: () -> Void = {}

    var available: Release? {
        if case .available(let release) = state { release } else { nil }
    }

    static var current: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }

    func checkIfDue() {
        let last = UserDefaults.standard.object(forKey: Self.checkedKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 86_400 else { return }
        Task { await check() }
    }

    /// Asks GitHub now. A quiet (daily) check that fails leaves the state alone.
    func check(manual: Bool = false) async {
        if manual { state = .checking }
        struct Latest: Decodable { var tag_name: String; var html_url: URL; var draft: Bool; var prerelease: Bool }
        var request = URLRequest(url: Self.api, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let latest = try? JSONDecoder().decode(Latest.self, from: data), !latest.draft, !latest.prerelease else {
            if manual { state = .failed }
            return
        }
        UserDefaults.standard.set(Date(), forKey: Self.checkedKey)
        let version = latest.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        state = Self.isNewer(version, than: Self.current)
            ? .available(Release(version: version, page: latest.html_url))
            : (manual ? .upToDate : .idle)
        onChange()
    }

    /// 0.10.0 is newer than 0.9.2; a missing part counts as 0.
    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }
}
