import SwiftUI

/// One setting: its name and a line on what it does on the left, its control
/// on the right; rows are divided by a hairline. Every row is at least the same
/// height, so pages line up.
struct SettingRow<Control: View>: View {
    let title: String
    var detail: String?
    /// An app icon in front of the name.
    var image: NSImage?
    @ViewBuilder let control: Control

    var body: some View {
        HStack(alignment: .center, spacing: Spacing.s24) {
            if let image {
                Image(nsImage: image).resizable().frame(width: 32, height: 32)
                    .padding(.trailing, -Spacing.s12)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: Spacing.s4) {
                Text(title).textStyle(.subheading).foregroundStyle(Palette.ink)
                if let detail {
                    Text(detail).textStyle(.body).foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            control
        }
        .frame(minHeight: 40)
        .padding(.vertical, Spacing.s16)
        .overlay(alignment: .bottom) { Palette.hairline.frame(height: 1) }
        .accessibilityElement(children: .combine)
    }
}

struct SettingToggle: View {
    let title: String
    var detail: String?
    @Binding var isOn: Bool

    var body: some View {
        SettingRow(title: title, detail: detail) {
            Toggle(isOn: $isOn) { Text(title) }.labelsHidden().toggleStyle(PillSwitchStyle())
        }
    }
}

/// A switch in the accent colour. The system's switch greys out when the window
/// isn't in front; this one keeps its colour.
struct PillSwitchStyle: ToggleStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            Capsule()
                .fill(configuration.isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(Palette.hover))
                .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: configuration.isOn ? 0 : 1))
                .frame(width: 42, height: 24)
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Circle().fill(.white)
                        .shadow(color: .black.opacity(0.2), radius: 1.5, y: 1).padding(3)
                }
                .animation(reduceMotion ? nil : Motion.micro, value: configuration.isOn)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label } }
    }
}

/// A button on the right of a row: a faint wash of the accent.
struct PillButton: View {
    let title: String
    var icon: Reicon?
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    init(_ title: String, icon: Reicon? = nil, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.s4) {
                if let icon { IconView(icon, size: 14) }
                Text(title).textStyle(.bodyEmphasis)
            }
            .foregroundStyle(.accentText)
            .padding(.horizontal, Spacing.s16)
            .frame(height: 32)
            .background(.tint.opacity(hovering && isEnabled ? 0.2 : 0.12), in: RoundedRectangle(cornerRadius: Radius.ui, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.45)
        .onHover { hovering = $0 }
        .animation(Motion.micro, value: hovering)
    }
}

/// A menu on the right of a row (current value and a chevron), styled as `PillButton`.
struct PillMenu<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [(Value, String)]

    var body: some View {
        Menu {
            Picker(selection: $selection) {
                ForEach(options, id: \.0) { Text($0.1).tag($0.0) }
            } label: { Text(title) }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: Spacing.s4) {
                if let current = options.first(where: { $0.0 == selection }) { Text(current.1) }
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .textStyle(.bodyEmphasis)
            .foregroundStyle(.accentText)
            .padding(.horizontal, Spacing.s12)
            .frame(height: 32)
            .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: Radius.ui, style: .continuous))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(Text(title))
    }
}

/// A short paragraph that closes a page or explains it.
struct Note: View {
    let text: String
    var icon: Reicon?

    init(_ text: String, icon: Reicon? = nil) {
        self.text = text
        self.icon = icon
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.s8) {
            if let icon { IconView(icon, size: 14).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 } }
            Text(text).textStyle(.body).foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(2)
        }
        .padding(.vertical, Spacing.s16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
