import AppKit

/// Shared building blocks for the Settings window — layout tokens plus the
/// row/section/help components every pane uses. One grid for label/control
/// placement keeps the control column at the same x on every page
/// (previously each page's rows started wherever its labels ended).
///
/// Components (per the refactor brief): `SettingsLayout` (the page grid
/// tokens), `LabeledSettingRow`, `SettingsSection`, `SettingsHelpText`,
/// `HardwareAvailabilityNotice`.
enum SettingsLayout {
    static let sidebarWidth: CGFloat = 190
    static let contentPadding: CGFloat = 24
    /// Fixed label column of every LabeledSettingRow.
    static let labelColumn: CGFloat = 180
    static let labelControlGap: CGFloat = 16
    /// Standard popup/field width (popups that need more pass their own).
    static let controlWidth: CGFloat = 240
    static let rowSpacing: CGFloat = 10
    static let sectionSpacing: CGFloat = 24
    static let titleTopInset: CGFloat = 20
    static let titleBodyGap: CGFloat = 14
    static let pageSize = NSSize(width: 900, height: 680)
    static let minPageSize = NSSize(width: 680, height: 520)
    /// Bottom padding so the last row never sits against the window edge.
    static let bottomPadding: CGFloat = 20
}

/// One settings form row: a fixed label column, a wider gutter, then the
/// control — so labels of different lengths never shift the controls.
final class LabeledSettingRow: NSStackView {
    init(_ label: String, control: NSView, controlWidth: CGFloat? = nil) {
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .centerY
        spacing = SettingsLayout.labelControlGap
        translatesAutoresizingMaskIntoConstraints = false
        let l = NSTextField(labelWithString: label)
        l.font = .systemFont(ofSize: 13)
        l.translatesAutoresizingMaskIntoConstraints = false
        addArrangedSubview(l)
        addArrangedSubview(control)
        control.translatesAutoresizingMaskIntoConstraints = false
        var constraints = [
            l.widthAnchor.constraint(equalToConstant: SettingsLayout.labelColumn),
            l.centerYAnchor.constraint(equalTo: centerYAnchor),
        ]
        if let w = controlWidth {
            constraints.append(control.widthAnchor.constraint(equalToConstant: w))
        }
        NSLayoutConstraint.activate(constraints)
    }

    required init?(coder: NSCoder) { fatalError("no xib") }
}

/// Section headings — plain, flat text (no card, no recessed pill), with
/// the shared section spacing applied to whatever precedes them.
enum SettingsSection {
    static func label(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 13, weight: .semibold)
        return l
    }

    /// Append a section heading to a form stack, leaving 24 pt before it
    /// and the standard row gap after it.
    static func add(to body: NSStackView, _ text: String) {
        if let last = body.arrangedSubviews.last {
            body.setCustomSpacing(SettingsLayout.sectionSpacing, after: last)
        }
        let l = label(text)
        body.addArrangedSubview(l)
        body.setCustomSpacing(8, after: l)
    }
}

/// Quieter helper text that sits below a control or section.
enum SettingsHelpText {
    static func label(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.textColor = .secondaryLabelColor
        l.font = .systemFont(ofSize: 11)
        return l
    }
}

/// The "hardware unavailable" strip at the top of the Quartet page — one
/// clear message instead of per-control error text.
final class HardwareAvailabilityNotice: NSView {
    init(text: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        let icon = NSTextField(labelWithString: "⚠︎")
        icon.textColor = .secondaryLabelColor
        icon.font = .systemFont(ofSize: 12)
        icon.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: text)
        label.textColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: 11)
        label.translatesAutoresizingMaskIntoConstraints = false

        addSubview(icon)
        addSubview(label)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 18),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("no xib") }
}
