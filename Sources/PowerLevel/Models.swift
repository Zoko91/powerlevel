import Foundation

enum DeviceKind: Int, CaseIterable, Sendable {
    case headset = 0
    case mouse = 1
    case keyboard = 2

    var symbolName: String {
        switch self {
        case .headset: "headphones"
        case .mouse: "computermouse"
        case .keyboard: "keyboard"
        }
    }

    var fallbackName: String {
        switch self {
        case .headset: "Headset"
        case .mouse: "Mouse"
        case .keyboard: "Keyboard"
        }
    }
}

enum ChargingState: Equatable, Sendable {
    case discharging
    case charging
    case full
    case unknown
}

struct DeviceBattery: Equatable, Sendable {
    let kind: DeviceKind
    var name: String
    var percentage: Int?
    var charging: ChargingState
    var isOnline: Bool
    var lastUpdated: Date?

    static func offline(_ kind: DeviceKind, name: String? = nil) -> DeviceBattery {
        DeviceBattery(
            kind: kind,
            name: name ?? kind.fallbackName,
            percentage: nil,
            charging: .unknown,
            isOnline: false,
            lastUpdated: nil
        )
    }
}
