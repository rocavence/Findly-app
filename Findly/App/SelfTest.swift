#if DEBUG
import AppKit

/// End-to-end self-test driven by `scripts/selftest.sh [item]`. Works in a
/// fake folder tree ($FINDLY_HOME), never your real files. Prints PASS/FAIL
/// lines and "SELFTEST OK" when all passed; screenshots go to $FINDLY_SHOTS.
@MainActor
enum SelfTest {
    private static var failures = 0
    private static let env = ProcessInfo.processInfo.environment
    private static var root: URL { URL(fileURLWithPath: env["FINDLY_HOME"] ?? NSTemporaryDirectory() + "findly-selftest") }
    private static var shots: URL? { env["FINDLY_SHOTS"].map { URL(fileURLWithPath: $0) } }
    private static let fm = FileManager.default

    static func run(_ only: String) {
        Task {
            let items: [(String, () async throws -> Void)] = [
                ("reader", reader),
                ("operations", operations),
                ("browser", browser),
                ("windows", windows),
                ("screenshots", screenshots),
            ]
            for (name, test) in items where (only.isEmpty || only == "all") ? name != "screenshots" : only == name {
                makeFixture()
                print("SELFTEST \(name)")
                do { try await test() } catch { check("\(name) threw \(error.localizedDescription)", false) }
            }
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent("Locked").path)
            print(failures == 0 ? "SELFTEST OK" : "SELFTEST FAILED (\(failures))")
            exit(failures == 0 ? 0 : 1)
        }
    }

    // MARK: Items

    /// Same-named files with different extensions both show; hidden files only when asked; errors are told apart.
    private static func reader() throws {
        let items = try DirectoryReader.read(root.appendingPathComponent("Projects"))
        let names = Set(items.map(\.url.lastPathComponent))
        check("report.pdf and report.docx both listed", names.isSuperset(of: ["report.pdf", "report.docx"]))
        check("hidden files skipped", !names.contains(".secret"))
        let hidden = try DirectoryReader.read(root.appendingPathComponent("Projects"), showHidden: true)
        check("hidden files shown when asked", hidden.contains { $0.url.lastPathComponent == ".secret" })
        check("a folder is a folder", items.first { $0.name == "Design" }?.isFolder == true)
        do { _ = try DirectoryReader.read(root.appendingPathComponent("Locked")); check("locked folder fails", false) }
        catch { check("locked folder reports no permission", error == .noPermission) }
        do { _ = try DirectoryReader.read(root.appendingPathComponent("Nope")); check("missing folder fails", false) }
        catch { check("missing folder reports missing", error == .missing) }
        var arrangement = Arrangement(sort: .name, ascending: true, groupByKind: false)
        check("folders first", arrangement.rows(items).first == .item(items.first { $0.name == "Design" }!))
        arrangement.groupByKind = true
        check("grouped starts with the Folders header", arrangement.rows(items).first == .header(.folder))
    }

    /// Rename checks, trash, and copy/move that never overwrites.
    private static func operations() async throws {
        let projects = root.appendingPathComponent("Projects")
        let notes = projects.appendingPathComponent("notes.txt")
        check("slash rejected", FileOperations.validate("a/b", for: notes) == .slash)
        check("empty rejected", FileOperations.validate("  ", for: notes) == .empty)
        check("clash rejected", FileOperations.validate("report.pdf", for: notes) == .taken("report.pdf"))
        let renamed = try FileOperations.rename(notes, to: "Notes.txt")
        check("case-only rename works", fm.fileExists(atPath: renamed.path) && renamed.lastPathComponent == "Notes.txt")
        let design = projects.appendingPathComponent("Design")
        let failed = await FileOperations.transfer([projects.appendingPathComponent("report.pdf")], to: design, .copy)
        check("copy succeeded", failed.isEmpty)
        _ = await FileOperations.transfer([projects.appendingPathComponent("report.pdf")], to: design, .copy)
        check("second copy gets a numbered name", fm.fileExists(atPath: design.appendingPathComponent("report 2.pdf").path))
        check("trash works", FileOperations.trash([design.appendingPathComponent("report 2.pdf")]).isEmpty)
    }

    /// The real browser: loads, expands, keeps expansion across a refresh, and explains empty and locked folders.
    private static func browser() async throws {
        let projects = root.appendingPathComponent("Projects")
        let view = BrowserView(start: projects)
        let window = host(view)
        defer { window.close() }
        try await wait { view.list.outline.numberOfRows > 0 }
        check("folder lists its items", view.list.outline.numberOfRows >= 5)
        let designRow = (0..<view.list.outline.numberOfRows).first { (view.list.outline.item(atRow: $0) as? FileNode)?.item?.name == "Design" }
        check("Design row present", designRow != nil)
        if let designRow, let node = view.list.outline.item(atRow: designRow) {
            view.list.outline.expandItem(node)
            try await wait { view.list.outline.numberOfRows >= 7 }
            check("Design expands in place", view.list.expandedURLs().contains(projects.appendingPathComponent("Design").standardizedFileURL))
            fm.createFile(atPath: projects.appendingPathComponent("new.txt").path, contents: Data("x".utf8))
            try await wait { (0..<view.list.outline.numberOfRows).contains { (view.list.outline.item(atRow: $0) as? FileNode)?.item?.name == "new.txt" } }
            check("a new file appears by itself", true)
            check("expansion survives the refresh", view.list.expandedURLs().contains(projects.appendingPathComponent("Design").standardizedFileURL))
        }
        view.showFolder(root.appendingPathComponent("Empty"))
        try await wait { !view.empty.isHidden }
        check("empty folder says so", view.empty.titleText == String(localized: "This folder is empty"))
        view.showFolder(root.appendingPathComponent("Locked"))
        try await wait { view.empty.titleText == String(localized: "Findly can't open this folder") }
        check("locked folder explains Full Disk Access", true)
    }

    /// Screenshots of the browser and each settings page.
    private static func windows() async throws {
        let view = BrowserView(start: root.appendingPathComponent("Projects"))
        let window = host(view)
        try await wait { view.list.outline.numberOfRows > 0 }
        try await Task.sleep(for: .milliseconds(400))
        snapshot(window, "browser")
        window.close()
        let model = SettingsModel(updates: UpdateChecker()) { [] }
        let settings = SettingsWindow(model: model)
        for page in SettingsPage.allCases {
            settings.show(page)
            try await Task.sleep(for: .milliseconds(400))
            snapshot(settings.nsWindow, "settings-\(page.rawValue)")
        }
        settings.nsWindow.close()
        check("windows drawn", true)
    }

    /// The README and website shots: a believable folder in the real drawer
    /// window and Settings, captured with their shadows by scripts/screenshots.sh.
    private static func screenshots() async throws {
        let projects = root.appendingPathComponent("Projects")
        try? fm.removeItem(at: projects)
        for dir in ["Brand", "Brand/Logos", "Invoices", "Photos"] {
            try fm.createDirectory(at: projects.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        let files = ["Pitch Deck.key", "Q3 Report.pdf", "Moodboard.png", "Interview.m4a", "Launch Film.mov", "Notes.md",
                     "Contract.docx", "Assets.zip", "Brand/Guidelines.pdf", "Brand/Palette.png", "Brand/Logos/Mark.svg"]
        for (i, file) in files.enumerated() {
            let url = projects.appendingPathComponent(file)
            fm.createFile(atPath: url.path, contents: Data(repeating: 0, count: 1_000 * (i + 3) * (i + 7)))
            try? fm.setAttributes([.modificationDate: Date().addingTimeInterval(-Double(i) * 86_000)], ofItemAtPath: url.path)
        }
        let window = DrawerWindow()
        let view = BrowserView(start: projects)
        window.contentView = view
        let screen = NSScreen.main!.visibleFrame
        window.setFrame(NSRect(x: screen.midX - 480, y: screen.midY - 300, width: 960, height: 600), display: true)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        try await wait { view.list.outline.numberOfRows > 5 }
        if let row = (0..<view.list.outline.numberOfRows).first(where: { (view.list.outline.item(atRow: $0) as? FileNode)?.item?.name == "Brand" }),
           let node = view.list.outline.item(atRow: row) {
            view.list.outline.expandItem(node)
            try await wait { view.list.outline.numberOfRows > 13 }
        }
        view.list.select(projects.appendingPathComponent("Q3 Report.pdf"))
        window.makeFirstResponder(view.list.outline)
        // Long enough for the overlay scrollers that flash on showing to fade.
        try await Task.sleep(for: .milliseconds(1500))
        try await capture(window, "drawer")
        // Docked on the right, the way it slides in; for the website's demo.
        window.setFrame(NSRect(x: screen.midX - 380, y: screen.midY - 470, width: 760, height: 940), display: true)
        try await Task.sleep(for: .milliseconds(1500))
        try await capture(window, "drawer-tall.noshadow")
        window.orderOut(nil)

        let settings = SettingsWindow(model: SettingsModel(updates: UpdateChecker()) { [] })
        for page in [SettingsPage.general, .sidebar, .shortcuts] {
            settings.show(page)
            try await Task.sleep(for: .milliseconds(500))
            try await capture(settings.nsWindow, "settings-\(page.rawValue)")
        }
        settings.nsWindow.close()
        print("SCREENSHOTS OK")
    }

    /// Asks scripts/screenshots.sh to capture a window (it has the Screen Recording permission), and waits.
    private static func capture(_ window: NSWindow, _ name: String) async throws {
        guard let shots else { return }
        // Something else may have come to the front while waiting; shots show the active look.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(200))
        try? fm.createDirectory(at: shots, withIntermediateDirectories: true)
        fm.createFile(atPath: shots.appendingPathComponent("\(name).request").path, contents: Data("\(window.windowNumber)".utf8))
        for _ in 0..<100 {
            if fm.fileExists(atPath: shots.appendingPathComponent("\(name).png").path) { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        print("no capture for \(name)")
    }

    // MARK: Helpers

    private static func makeFixture() {
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent("Locked").path)
        try? fm.removeItem(at: root)
        let projects = root.appendingPathComponent("Projects")
        for dir in ["Projects/Design", "Empty", "Locked"] {
            try? fm.createDirectory(at: root.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        for file in ["report.pdf", "report.docx", "notes.txt", "photo.png", "song.mp3", ".secret", "Design/logo.png", "Design/brief.pdf"] {
            fm.createFile(atPath: projects.appendingPathComponent(file).path, contents: Data(file.utf8))
        }
        try? fm.setAttributes([.posixPermissions: 0], ofItemAtPath: root.appendingPathComponent("Locked").path)
    }

    private static func host(_ view: NSView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 900, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        return window
    }

    private static func snapshot(_ window: NSWindow, _ name: String) {
        guard let shots, let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? fm.createDirectory(at: shots, withIntermediateDirectories: true)
        try? rep.representation(using: .png, properties: [:])?.write(to: shots.appendingPathComponent("\(name).png"))
    }

    private struct Timeout: Error {}

    private static func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<50 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw Timeout()
    }

    private static func check(_ name: String, _ ok: Bool) {
        print(ok ? "PASS \(name)" : "FAIL \(name)")
        if !ok { failures += 1 }
    }
}
#endif
