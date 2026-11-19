import AppKit

final class StatusBarController: NSObject, NSMenuDelegate {
    private struct DisplaySnapshot: Equatable {
        var percentage: Int?
        var charging: ChargingState
        var isOnline: Bool
    }

    private let statusItem: NSStatusItem
    private let onRefresh: () -> Void
    private var devices: [DeviceKind: DeviceBattery] = [:]
    private var lastRendered: [DeviceKind: DisplaySnapshot] = [:]

    private let menu = NSMenu()
    private let textFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)

    // Pre-built template SF Symbols (allocated once for the entire app lifetime)
    private let cachedIcons: [DeviceKind: (image: NSImage, bounds: CGRect)]
    private let cachedBolt: (image: NSImage, bounds: CGRect)?

    private static let launchAgentLabel = "com.powerlevel.app"
    private static var launchAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(launchAgentLabel).plist")
    }

    private lazy var timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    init(onRefresh: @escaping () -> Void) {
        self.onRefresh = onRefresh
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 12.5, weight: .medium, scale: .medium)
        let boltConfig = NSImage.SymbolConfiguration(pointSize: 9.5, weight: .bold, scale: .small)

        var icons: [DeviceKind: (NSImage, CGRect)] = [:]
        for kind in DeviceKind.allCases {
            if let built = Self.buildSymbol(name: kind.symbolName, config: symbolConfig, targetHeight: 13, capHeight: textFont.capHeight) {
                icons[kind] = built
            }
        }
        self.cachedIcons = icons
        self.cachedBolt = Self.buildSymbol(name: "bolt.fill", config: boltConfig, targetHeight: 10, capHeight: textFont.capHeight)

        super.init()

        self.menu.delegate = self
        self.statusItem.menu = menu

        for kind in DeviceKind.allCases {
            devices[kind] = .offline(kind)
        }

        renderButtonIfNeeded()
    }

    func update(_ battery: DeviceBattery) {
        devices[battery.kind] = battery
        renderButtonIfNeeded()
    }

    func update(_ batch: [DeviceKind: DeviceBattery]) {
        for (kind, battery) in batch {
            devices[kind] = battery
        }
        renderButtonIfNeeded()
    }

    private func renderButtonIfNeeded() {
        var current: [DeviceKind: DisplaySnapshot] = [:]
        for kind in DeviceKind.allCases {
            let state = devices[kind] ?? .offline(kind)
            current[kind] = DisplaySnapshot(
                percentage: state.percentage,
                charging: state.charging,
                isOnline: state.isOnline
            )
        }
        guard current != lastRendered else { return }
        lastRendered = current

        guard let button = statusItem.button else { return }
        let result = NSMutableAttributedString()

        for (index, kind) in DeviceKind.allCases.enumerated() {
            if index > 0 {
                result.append(NSAttributedString(string: "   ", attributes: [.font: textFont]))
            }

            let state = devices[kind] ?? .offline(kind)
            let isLow = (state.percentage ?? 100) <= 20 && state.charging != .charging

            if let icon = cachedIcons[kind] {
                let attachment = NSTextAttachment()
                attachment.image = icon.image
                attachment.bounds = icon.bounds
                result.append(NSAttributedString(attachment: attachment))
            }

            if state.charging == .charging, let bolt = cachedBolt {
                result.append(NSAttributedString(string: "\u{200A}", attributes: [.font: textFont]))
                let attachment = NSTextAttachment()
                attachment.image = bolt.image
                attachment.bounds = bolt.bounds
                result.append(NSAttributedString(attachment: attachment))
            }

            let labelText: String = if let pct = state.percentage {
                " \(pct)%"
            } else {
                " —"
            }

            var attrs: [NSAttributedString.Key: Any] = [.font: textFont]
            if isLow {
                attrs[.foregroundColor] = NSColor.systemRed
            } else if !state.isOnline && state.percentage == nil {
                attrs[.foregroundColor] = NSColor.tertiaryLabelColor
            }
            result.append(NSAttributedString(string: labelText, attributes: attrs))
        }

        button.attributedTitle = result
        button.image = nil
    }

    private static func buildSymbol(
        name: String,
        config: NSImage.SymbolConfiguration,
        targetHeight: CGFloat,
        capHeight: CGFloat
    ) -> (NSImage, CGRect)? {
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil),
              let configured = base.withSymbolConfiguration(config) else {
            return nil
        }
        configured.isTemplate = true

        let size = configured.size
        guard size.height > 0 else { return nil }

        let scale = min(1.0, targetHeight / size.height)
        let drawWidth = (size.width * scale).rounded(.toNearestOrEven)
        let drawHeight = (size.height * scale).rounded(.toNearestOrEven)
        let yOffset = ((capHeight - drawHeight) / 2.0).rounded(.toNearestOrEven)

        return (configured, CGRect(x: 0, y: yOffset, width: drawWidth, height: drawHeight))
    }

    // MARK: - NSMenuDelegate (menu is only built when clicked)

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        for kind in DeviceKind.allCases {
            let state = devices[kind] ?? .offline(kind)
            let statusText: String = if let pct = state.percentage {
                switch state.charging {
                case .charging: "\(pct)% (Charging)"
                case .full: "\(pct)% (Full)"
                case .discharging, .unknown: "\(pct)%"
                }
            } else {
                "Offline"
            }

            let item = NSMenuItem(title: "\(state.name) — \(statusText)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            item.image = cachedIcons[kind]?.image
            if let updated = state.lastUpdated {
                item.toolTip = "Updated at \(timeFormatter.string(from: updated))"
            }
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let refreshItem = NSMenuItem(title: "Refresh Now", action: #selector(handleRefresh), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let launchItem = NSMenuItem(
            title: "Launch at Login",
            action: #selector(toggleLaunchAtLogin),
            keyEquivalent: ""
        )
        launchItem.target = self
        launchItem.state = isLaunchAtLoginEnabled ? .on : .off
        menu.addItem(launchItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit PowerLevel", action: #selector(handleQuit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    private var isLaunchAtLoginEnabled: Bool {
        FileManager.default.fileExists(atPath: Self.launchAgentURL.path)
    }

    @objc private func handleRefresh() {
        onRefresh()
    }

    @objc private func toggleLaunchAtLogin() {
        let fm = FileManager.default
        let url = Self.launchAgentURL

        if fm.fileExists(atPath: url.path) {
            try? fm.removeItem(at: url)
        } else {
            let executablePath = Bundle.main.executablePath
                ?? "/Applications/PowerLevel.app/Contents/MacOS/PowerLevel"
            let plist: [String: Any] = [
                "Label": Self.launchAgentLabel,
                "ProgramArguments": [executablePath],
                "RunAtLoad": true,
                "KeepAlive": false,
                "LimitLoadToSessionType": "Aqua"
            ]
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    @objc private func handleQuit() {
        NSApp.terminate(nil)
    }
}
