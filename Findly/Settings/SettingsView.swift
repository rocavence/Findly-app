import Carbon.HIToolbox
import Combine
import SwiftUI

enum SettingsPage: String, CaseIterable {
    case general, drawer, sidebar, shortcuts, permissions, about

    var title: String {
        switch self {
        case .general: String(localized: "General")
        case .drawer: String(localized: "Drawer")
        case .sidebar: String(localized: "Sidebar")
        case .shortcuts: String(localized: "Shortcuts")
        case .permissions: String(localized: "Permissions")
        case .about: String(localized: "About")
        }
    }

    var icon: Reicon {
        switch self {
        case .general: .setting2
        case .drawer: .sidebarRight
        case .sidebar: .sidebar
        case .shortcuts: .keyboard
        case .permissions: .shieldCheck
        case .about: .infoCircle
        }
    }
}

/// What the settings card reads from the running app.
@MainActor
@Observable
final class SettingsModel {
    var page: SettingsPage = .general
    let updates: UpdateChecker
    /// Shortcuts macOS refused to register.
    var hotkeyFailures: Set<HotkeyAction>
    @ObservationIgnored var currentFailures: () -> Set<HotkeyAction> = { [] }
    @ObservationIgnored var resetSize: () -> Void = {}

    init(updates: UpdateChecker, failures: @escaping () -> Set<HotkeyAction>) {
        self.updates = updates
        self.currentFailures = failures
        hotkeyFailures = failures()
    }
}

/// Hosts `SettingsView` with the traffic lights over the card. Built when
/// opened and released when closed.
@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    let model: SettingsModel
    var onClose: () -> Void = {}
    private let window: NSWindow
    private var token: NSObjectProtocol?

    init(model: SettingsModel) {
        self.model = model
        let host = NSHostingView(rootView: SettingsView(model: model))
        host.sizingOptions = []
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                          styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = String(localized: "Settings")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        super.init()
        window.contentView = host
        window.delegate = self
        window.setFrame(NSRect(x: 0, y: 0, width: 900, height: 600), display: false)
        token = NotificationCenter.default.addObserver(forName: .findlyHotkeysRegistered, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self.map { $0.model.hotkeyFailures = $0.model.currentFailures() } }
        }
    }

    func windowWillClose(_ notification: Notification) {
        // A recorder still listening must let go of the hotkeys.
        NotificationCenter.default.post(name: .findlyHotkeyRecordingEnded, object: nil)
        if let token { NotificationCenter.default.removeObserver(token) }
        DispatchQueue.main.async { [weak self] in
            self?.window.contentView = nil
            self?.onClose()
        }
    }

    func show(_ page: SettingsPage) {
        model.page = page
        if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    var nsWindow: NSWindow { window }
}

/// The settings card shared with Flione, Wunder, Gamely and Configgy:
/// 900 × 600, a 184-wide column of pages, a hairline, then the page.
struct SettingsView: View {
    @Bindable var model: SettingsModel
    @AppStorage(Accent.key) private var accent: Accent = .findly

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Settings").textStyle(.title).foregroundStyle(Palette.ink)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.horizontal, Spacing.s8)
                    .padding(.bottom, Spacing.s20)
                VStack(alignment: .leading, spacing: Spacing.s2) {
                    ForEach(SettingsPage.allCases, id: \.self) { page in
                        PageRow(page: page, selected: page == model.page, accent: accent) { model.page = page }
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(width: 184, alignment: .leading)
            .padding(.trailing, Spacing.s16)

            Palette.hairline.frame(width: 1).padding(.vertical, -Spacing.s32)

            VStack(alignment: .leading, spacing: 0) {
                Text(model.page.title).textStyle(.heading).foregroundStyle(Palette.ink)
                    .accessibilityAddTraits(.isHeader)
                    .frame(height: 36, alignment: .leading)
                    .padding(.bottom, Spacing.s4)
                ScrollView {
                    Group {
                        switch model.page {
                        case .general: GeneralPage()
                        case .drawer: DrawerPage(model: model)
                        case .sidebar: SidebarPage()
                        case .shortcuts: ShortcutsPage(model: model)
                        case .permissions: PermissionsPage()
                        case .about: AboutPage(updates: model.updates)
                        }
                    }
                    .padding(.bottom, Spacing.s24)
                }
                .scrollIndicators(.never)
                .scrollBounceBehavior(.basedOnSize)
                .mask {
                    VStack(spacing: 0) {
                        Color.black
                        LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 28)
                    }
                }
            }
            .padding(.leading, Spacing.s24)
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Spacing.s32)
        .padding(.top, Spacing.s32 + Spacing.s8)
        .padding(.bottom, Spacing.s32)
        .frame(width: 900, height: 600)
        .background {
            ZStack {
                Palette.background
                RadialGradient(colors: [accent.color.opacity(0.08), .clear], center: .top, startRadius: 0, endRadius: 420)
            }
            .ignoresSafeArea()
        }
        .tint(accent.color)
    }
}

private struct PageRow: View {
    let page: SettingsPage
    let selected: Bool
    let accent: Accent
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.s8) {
                IconView(page.icon, weight: selected ? .filled : .outline, size: 16).frame(width: 20)
                Text(page.title).textStyle(selected ? .bodyEmphasis : .body).lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(selected ? AnyShapeStyle(accent.onAccent) : AnyShapeStyle(Palette.ink.opacity(0.82)))
            .padding(.horizontal, Spacing.s8)
            .frame(height: 32)
            .background(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(hovering ? Palette.hover : .clear),
                        in: RoundedRectangle(cornerRadius: Radius.ui, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: Radius.ui, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - General

private struct GeneralPage: View {
    @State private var language = AppLanguage.saved
    @State private var loginEnabled = LoginItem.isEnabled
    @State private var loginError: String?
    @AppStorage(AppAppearance.key) private var appearance: AppAppearance = .system
    @AppStorage(Accent.key) private var accent: Accent = .findly

    var body: some View {
        VStack(spacing: 0) {
            SettingRow(title: String(localized: "Language"),
                       detail: language == AppLanguage.launched ? nil : String(localized: "Takes effect when Findly opens again.")) {
                HStack(spacing: Spacing.s8) {
                    if language != AppLanguage.launched {
                        PillButton(String(localized: "Reopen")) { AppLanguage.relaunch() }
                    }
                    PillMenu(title: String(localized: "Language"), selection: $language, options: AppLanguage.allCases.map { ($0, $0.title) })
                }
            }
            .onChange(of: language) { AppLanguage.save(language) }
            SettingRow(title: String(localized: "Appearance"), detail: String(localized: "For the drawer and Findly's windows.")) {
                PillMenu(title: String(localized: "Appearance"), selection: $appearance, options: AppAppearance.allCases.map { ($0, $0.title) })
            }
            .onChange(of: appearance) { AppAppearance.apply(appearance) }
            SettingRow(title: String(localized: "Accent Color"), detail: String(localized: "Marks what's chosen and what's on.")) {
                PillMenu(title: String(localized: "Accent Color"), selection: $accent, options: Accent.allCases.map { ($0, $0.title) })
            }
            SettingRow(title: String(localized: "Launch at Login"), detail: loginDetail) {
                HStack(spacing: Spacing.s8) {
                    if LoginItem.needsApproval || loginError != nil {
                        PillButton(String(localized: "Open Login Items")) { LoginItem.openSystemSettings() }
                    }
                    Toggle(isOn: Binding(get: { loginEnabled }, set: { on in
                        loginError = LoginItem.setEnabled(on)
                        loginEnabled = LoginItem.isEnabled
                    })) { Text("Launch at Login") }
                    .labelsHidden().toggleStyle(PillSwitchStyle())
                }
            }
        }
    }

    private var loginDetail: String {
        if let loginError { return String(localized: "Couldn't turn this on: \(loginError)") }
        if LoginItem.needsApproval { return String(localized: "macOS is waiting for your OK in System Settings › Login Items.") }
        return String(localized: "Start Findly when you log in, so the shortcut always works.")
    }
}

// MARK: - Drawer

private struct DrawerPage: View {
    let model: SettingsModel
    @State private var defaultEdge = Defaults.defaultEdge.map(EdgeChoice.edge) ?? .last
    @State private var autoPark = Defaults.autoPark
    @State private var mouseNav = Defaults.mouseNavEnabled
    @State private var showHidden = Defaults.showHidden

    enum EdgeChoice: Hashable {
        case last
        case edge(ScreenEdge)
    }

    var body: some View {
        VStack(spacing: 0) {
            SettingRow(title: String(localized: "Open On"), detail: String(localized: "Where the toggle shortcut opens the drawer. The edge shortcuts always open on their own edge.")) {
                PillMenu(title: String(localized: "Open On"), selection: $defaultEdge, options: [
                    (EdgeChoice.last, String(localized: "Last Edge Used")),
                    (.edge(.right), String(localized: "Right")), (.edge(.left), String(localized: "Left")),
                    (.edge(.top), String(localized: "Top")), (.edge(.bottom), String(localized: "Bottom")),
                ])
            }
            .onChange(of: defaultEdge) {
                if case .edge(let e) = defaultEdge { Defaults.defaultEdge = e } else { Defaults.defaultEdge = nil }
            }
            SettingToggle(title: String(localized: "Slide Away When You Switch Apps"),
                          detail: String(localized: "The drawer closes when another app comes to the front. Off, it stays until you close it."),
                          isOn: $autoPark)
                .onChange(of: autoPark) { Defaults.autoPark = autoPark }
            SettingToggle(title: String(localized: "Mouse Side Buttons Go Back and Forward"),
                          detail: String(localized: "As in a web browser."), isOn: $mouseNav)
                .onChange(of: mouseNav) { Defaults.mouseNavEnabled = mouseNav }
            SettingToggle(title: String(localized: "Show Hidden Files"),
                          detail: String(localized: "Files whose names start with a dot. ⌘⇧. in the drawer switches this too."), isOn: $showHidden)
                .onChange(of: showHidden) { Defaults.showHidden = showHidden }
            SettingRow(title: String(localized: "Size"),
                       detail: String(localized: "Drag the drawer's inner edge to resize it. Width and height are remembered separately, up to 85% of the screen.")) {
                PillButton(String(localized: "Reset Size")) { model.resetSize() }
            }
        }
    }
}

// MARK: - Sidebar

/// Which of Finder's sidebar items the drawer shows, like Finder's Settings › Sidebar.
private struct SidebarPage: View {
    @State private var hidden = Defaults.hiddenSidebarItems
    @State private var syncFinder = Defaults.syncFinderSidebar
    private let groups = Self.choices()
    /// What Finder hides, shown (read-only) while synced.
    private let finderHidden = FinderSidebar.finderHidden(FinderSidebar.allSections())

    struct Choice: Identifiable {
        enum Icon { case symbol(String), template(NSImage), image(NSImage) }
        let id: String   // SidebarItem.key
        let title: String
        let icon: Icon
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s24) {
            SettingToggle(title: String(localized: "Same as Finder"),
                          detail: String(localized: "Show what Finder's sidebar shows. Findly checks Finder's settings every time the drawer opens."),
                          isOn: $syncFinder)
                .onChange(of: syncFinder) {
                    Defaults.syncFinderSidebar = syncFinder
                    NotificationCenter.default.post(name: .findlySidebarChanged, object: nil)
                }
            Text(syncFinder
                 ? String(localized: "To change these, use Finder › Settings › Sidebar.")
                 : String(localized: "Choose what the drawer's sidebar shows. Favorites and Tags come from Finder, in Finder's order."))
                .textStyle(.body).foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(groups, id: \.title) { group in
                VStack(alignment: .leading, spacing: 0) {
                    Text(group.title).textStyle(.caption).foregroundStyle(Palette.faint)
                        .accessibilityAddTraits(.isHeader)
                        .padding(.bottom, Spacing.s4)
                    ForEach(group.choices) { choice in row(choice) }
                }
            }
        }
    }

    private func row(_ choice: Choice) -> some View {
        HStack(spacing: Spacing.s12) {
            Group {
                switch choice.icon {
                case .symbol(let name): Image(systemName: name).foregroundStyle(.tint)
                case .template(let image): Image(nsImage: image).renderingMode(.template).foregroundStyle(.tint)
                case .image(let image): Image(nsImage: image)
                }
            }
            .frame(width: 20).accessibilityHidden(true)
            Text(choice.title).textStyle(.body).foregroundStyle(Palette.ink).lineLimit(1)
            Spacer(minLength: 0)
            Toggle(isOn: Binding(get: { !(syncFinder ? finderHidden : hidden).contains(choice.id) }, set: { on in
                if on { hidden.remove(choice.id) } else { hidden.insert(choice.id) }
                Defaults.hiddenSidebarItems = hidden
                NotificationCenter.default.post(name: .findlySidebarChanged, object: nil)
            })) { Text(choice.title) }
            .labelsHidden().toggleStyle(PillSwitchStyle())
            .disabled(syncFinder)
        }
        .opacity(syncFinder ? 0.55 : 1)
        .frame(height: 44)
        .overlay(alignment: .bottom) { Palette.hairline.frame(height: 1) }
    }

    /// Finder's items, except volumes, which are turned on and off by kind as in Finder.
    private static func choices() -> [(title: String, choices: [Choice])] {
        FinderSidebar.allSections().map { section in
            guard section.kind != .locations else {
                return (section.title, SidebarItem.VolumeKind.allCases.map { Choice(id: $0.key, title: $0.title, icon: .symbol($0.symbol)) })
            }
            return (section.title, section.items.map { item in
                let icon: Choice.Icon
                switch item.target {
                case .tag: icon = .image(SidebarCell.tagDot(item.tagColor))
                case .folder(let url):
                    if let provided = item.providerSymbol?.image { icon = .template(provided) }
                    else { icon = item.symbol.map { .symbol($0) } ?? .image(FileIcons.icon(for: url)) }
                }
                return Choice(id: item.key, title: item.title, icon: icon)
            })
        }
    }
}

// MARK: - Shortcuts

private struct ShortcutsPage: View {
    let model: SettingsModel
    @State private var recording: HotkeyAction?
    @State private var message: String?
    @State private var monitor: Any?
    @State private var version = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(HotkeyAction.allCases, id: \.self) { action in
                SettingRow(title: action.localizedTitle, detail: detail(for: action)) {
                    HStack(spacing: Spacing.s8) {
                        if Defaults.hotkey(for: action) != action.defaultHotkey {
                            Button(String(localized: "Reset")) { set(nil, for: action) }
                                .buttonStyle(.plain).foregroundStyle(.accentText).textStyle(.caption)
                        }
                        RecorderButton(text: recording == action ? String(localized: "Type a shortcut…") : Defaults.hotkey(for: action).displayString,
                                       active: recording == action,
                                       label: String(localized: "Shortcut for \(action.localizedTitle)")) {
                            recording == action ? stop() : start(action)
                        }
                    }
                }
                .id("\(action.rawValue)-\(version)")
            }
            Note(message ?? String(localized: "A shortcut needs ⌘, ⌃ or ⌥. Press Esc to cancel. The toggle shortcut is ⌃` by default; VS Code uses it for its terminal, so it won't reach Findly while VS Code is in front."),
                 icon: message == nil ? .infoCircle : .warning)
        }
        .onDisappear { stop() }
    }

    private func detail(for action: HotkeyAction) -> String? {
        if model.hotkeyFailures.contains(action) {
            return String(localized: "Another app is using this shortcut, so it doesn't reach Findly. Choose a different one.")
        }
        return action == .toggle ? String(localized: "Opens and closes the drawer.") : nil
    }

    private func start(_ action: HotkeyAction) {
        stop()
        message = nil
        recording = action
        NotificationCenter.default.post(name: .findlyHotkeyRecordingBegan, object: nil)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if Int(event.keyCode) == kVK_Escape { stop(); return nil }
            let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
            guard !mods.intersection([.command, .control, .option]).isEmpty else {
                message = String(localized: "Add ⌘, ⌃ or ⌥ to the shortcut.")
                return nil
            }
            guard Hotkey.isKnownKeyCode(UInt32(event.keyCode)) else {
                message = String(localized: "Findly can't use that key. Try a letter, number, arrow or punctuation key.")
                return nil
            }
            let hotkey = Hotkey(keyCode: UInt32(event.keyCode), carbonModifiers: Hotkey.carbonModifiers(from: mods))
            if let other = HotkeyAction.allCases.first(where: { $0 != action && Defaults.hotkey(for: $0) == hotkey }) {
                message = String(localized: "\(hotkey.displayString) is already used for “\(other.localizedTitle)”.")
                return nil
            }
            if hotkey.isSystemShortcut {
                message = String(localized: "macOS uses \(hotkey.displayString). Choose a different one, or turn it off in System Settings › Keyboard › Keyboard Shortcuts.")
                return nil
            }
            set(hotkey, for: action)
            stop()
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        let wasRecording = recording != nil
        monitor = nil
        recording = nil
        if wasRecording { NotificationCenter.default.post(name: .findlyHotkeyRecordingEnded, object: nil) }
    }

    private func set(_ hotkey: Hotkey?, for action: HotkeyAction) {
        Defaults.setHotkey(hotkey, for: action)
        NotificationCenter.default.post(name: .findlyHotkeysChanged, object: nil)
        version += 1
    }
}

private struct RecorderButton: View {
    let text: String
    let active: Bool
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: 13, weight: .medium, design: active ? .default : .rounded))
                .foregroundStyle(active ? AnyShapeStyle(.accentText) : AnyShapeStyle(Palette.ink))
                .frame(minWidth: 96)
                .padding(.horizontal, Spacing.s12)
                .frame(height: 32)
                .background(active ? AnyShapeStyle(.tint.opacity(0.12)) : AnyShapeStyle(Palette.hover),
                            in: RoundedRectangle(cornerRadius: Radius.ui, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.ui, style: .continuous)
                    .strokeBorder(active ? AnyShapeStyle(.tint) : AnyShapeStyle(Palette.hairline), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text(text))
    }
}

// MARK: - Permissions

private struct PermissionsPage: View {
    @State private var granted = FullDiskAccess.isGranted
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingRow(title: String(localized: "Full Disk Access"),
                       detail: granted
                        ? String(localized: "On. Findly can open every folder you can.")
                        : String(localized: "Off. Desktop, Documents, Downloads, external drives and some other folders can't be opened until it's on.")) {
                HStack(spacing: Spacing.s8) {
                    if granted {
                        IconView(.checkCircle, weight: .filled, size: 18).foregroundStyle(Palette.good)
                            .accessibilityLabel(Text("On"))
                    } else {
                        PillButton(String(localized: "Open System Settings")) { FullDiskAccess.openSettings() }
                    }
                }
            }
            Note(String(localized: "In System Settings › Privacy & Security › Full Disk Access, turn on Findly. This page updates by itself. Findly never sends anything anywhere; the only network request is the daily update check to GitHub."),
                 icon: .lock)
        }
        .onReceive(timer) { _ in granted = FullDiskAccess.isGranted }
    }
}

// MARK: - About

private struct AboutPage: View {
    let updates: UpdateChecker

    private var version: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "") b\(info?["CFBundleVersion"] as? String ?? "")"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s24) {
            DeveloperCard().padding(.top, Spacing.s16)
            HStack(spacing: Spacing.s16) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Spacing.s4) {
                    Text(verbatim: "Findly").textStyle(.subheading).foregroundStyle(Palette.ink)
                    Text("A Finder-style drawer that slides in from any edge of the screen.").textStyle(.body).foregroundStyle(Palette.muted)
                    Text("Version \(version)").textStyle(.caption).foregroundStyle(Palette.faint)
                    updateRow.padding(.top, Spacing.s2)
                }
            }
            section(String(localized: "Why Findly"), [
                String(localized: "Grabbing a file meant finding a Finder window behind everything else, or opening a new one and clicking down to the folder again."),
                String(localized: "Findly keeps Finder's list one shortcut away, on every Space and over full-screen apps, and slides away when you're done. Drag a file out of it into whatever you're working on."),
            ])
            VStack(alignment: .leading, spacing: Spacing.s12) {
                heading(String(localized: "Thanks"))
                credit("Reicon", url: "https://github.com/dqev/reicon", detail: String(localized: "The toolbar and settings icons."))
                credit("XcodeGen", url: "https://github.com/yonaskolb/XcodeGen", detail: String(localized: "Generates the Xcode project."))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var updateRow: some View {
        HStack(spacing: Spacing.s8) {
            switch updates.state {
            case .checking:
                ProgressView().controlSize(.small)
                Text("Checking for updates…").textStyle(.caption).foregroundStyle(Palette.muted)
            case .available(let release):
                Text("Findly \(release.version) is available").textStyle(.caption).foregroundStyle(Palette.ink)
                Button(String(localized: "Download")) { NSWorkspace.shared.open(release.page) }
                    .buttonStyle(.plain).foregroundStyle(.accentText).textStyle(.caption)
            case .upToDate:
                Text("Findly is up to date.").textStyle(.caption).foregroundStyle(Palette.muted)
                checkButton
            case .failed:
                Text("Couldn't check for updates.").textStyle(.caption).foregroundStyle(Palette.muted)
                checkButton
            case .idle:
                checkButton
            }
        }
    }

    private var checkButton: some View {
        Button(String(localized: "Check for Updates")) { Task { await updates.check(manual: true) } }
            .buttonStyle(.plain).foregroundStyle(.accentText).textStyle(.caption)
    }

    private func heading(_ title: String) -> some View {
        Text(title).textStyle(.micro).textCase(.uppercase).foregroundStyle(Palette.muted)
    }

    private func section(_ title: String, _ paragraphs: [String]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s8) {
            heading(title)
            ForEach(paragraphs, id: \.self) { paragraph in
                Text(paragraph).textStyle(.body).foregroundStyle(Palette.ink.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true).lineSpacing(3)
            }
        }
    }

    private func credit(_ name: String, url: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s4) {
            Link(destination: URL(string: url)!) {
                HStack(spacing: Spacing.s4) {
                    Text(verbatim: name).textStyle(.bodyEmphasis)
                    IconView(.arrowUpRight, size: 11)
                }
                .foregroundStyle(.accentText)
            }
            .buttonStyle(.plain)
            Text(detail).textStyle(.body).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The author card shared with Flione, Wunder, Configgy and Gamely.
private struct DeveloperCard: View {
    @State private var hovering = false

    var body: some View {
        Link(destination: URL(string: "https://github.com/rocavence")!) {
            HStack(spacing: Spacing.s12) {
                Image("DeveloperAvatar").resizable().frame(width: 42, height: 42).clipShape(Circle()).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Spacing.s2) {
                    Text(verbatim: "@rocavence").font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.ink)
                    Text("Author · GitHub").font(.system(size: 12.5)).foregroundStyle(Palette.muted)
                }
            }
            .padding(.leading, Spacing.s8)
            .padding(.trailing, Spacing.s16)
            .padding(.vertical, Spacing.s8)
            .overlay(Capsule().strokeBorder(Palette.hairline))
            .background { if hovering { Capsule().fill(Palette.background).shadow(color: .black.opacity(0.2), radius: 12, y: 6) } }
            .offset(y: hovering ? -2 : 0)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.2), value: hovering)
        .accessibilityLabel("rocavence on GitHub")
    }
}
