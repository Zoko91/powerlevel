import Foundation
import IOKit
import IOKit.hid

final class CorsairMonitor {
    private static let vendorID = 0x1B1C
    private static let productID = 0x0A97 // CORSAIR HS80 MAX WIRELESS Gaming Receiver
    private static let usagePage = 0xFF42

    private static let propBatteryLevel: UInt8 = 0x0F
    private static let propChargeState: UInt8 = 0x10

    private enum PendingQuery {
        case batteryLevel
        case chargeState
    }

    private let manager: IOHIDManager
    private var device: IOHIDDevice?
    private var reportBuffer: UnsafeMutableBufferPointer<UInt8>?

    private var pendingQuery: PendingQuery?
    private var battery = DeviceBattery.offline(.headset, name: "CORSAIR HS80 MAX")

    var onUpdate: ((DeviceBattery) -> Void)?

    init() {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [String: Any] = [
            kIOHIDVendorIDKey as String: Self.vendorID,
            kIOHIDProductIDKey as String: Self.productID,
            kIOHIDPrimaryUsagePageKey as String: Self.usagePage
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)

        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, dev in
            guard let context else { return }
            MainActor.assumeIsolated {
                let monitor = Unmanaged<CorsairMonitor>.fromOpaque(context).takeUnretainedValue()
                monitor.attachDevice(dev)
            }
        }, ctx)

        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, dev in
            guard let context else { return }
            MainActor.assumeIsolated {
                let monitor = Unmanaged<CorsairMonitor>.fromOpaque(context).takeUnretainedValue()
                monitor.detachDevice(dev)
            }
        }, ctx)

        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    func stop() {
        if let dev = device {
            IOHIDDeviceClose(dev, IOOptionBits(kIOHIDOptionsTypeNone))
            device = nil
        }
        reportBuffer?.deallocate()
        reportBuffer = nil
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    func refresh() {
        guard device != nil else { return }
        pendingQuery = .batteryLevel
        sendGetProperty(Self.propBatteryLevel)
    }

    private func attachDevice(_ dev: IOHIDDevice) {
        guard device == nil else { return }
        guard IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else { return }

        let buf = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: 64)
        buf.initialize(repeating: 0)
        reportBuffer = buf
        device = dev

        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(
            dev,
            buf.baseAddress!,
            buf.count,
            { context, _, _, _, _, report, length in
                guard let context, length >= 6 else { return }
                let buffer = UnsafeBufferPointer(start: report, count: length)
                MainActor.assumeIsolated {
                    let monitor = Unmanaged<CorsairMonitor>.fromOpaque(context).takeUnretainedValue()
                    monitor.handleReport(buffer)
                }
            },
            ctx
        )
        IOHIDDeviceScheduleWithRunLoop(dev, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

        refresh()
    }

    private func detachDevice(_ dev: IOHIDDevice) {
        guard let current = device, CFEqual(current, dev) else { return }
        IOHIDDeviceClose(current, IOOptionBits(kIOHIDOptionsTypeNone))
        device = nil
        reportBuffer?.deallocate()
        reportBuffer = nil
        pendingQuery = nil

        battery = .offline(.headset, name: "CORSAIR HS80 MAX")
        onUpdate?(battery)
    }

    private func sendGetProperty(_ propertyID: UInt8) {
        guard let dev = device else { return }
        var report = [UInt8](repeating: 0, count: 64)
        report[0] = 0x02 // HID Report ID
        report[1] = 0x09 // Bragi subdevice 1 (wireless headset)
        report[2] = 0x02 // GET_PROPERTY
        report[3] = propertyID

        report.withUnsafeBytes { raw in
            _ = IOHIDDeviceSetReport(
                dev,
                kIOHIDReportTypeOutput,
                CFIndex(0x02),
                raw.baseAddress!.assumingMemoryBound(to: UInt8.self),
                report.count
            )
        }
    }

    private func handleReport(_ bytes: UnsafeBufferPointer<UInt8>) {
        guard bytes.count >= 6 else { return }
        // Bragi response from subdevice 1: [0x01, 0x01, cmd, ...]
        guard bytes[0] == 0x01, bytes[1] == 0x01 else { return }

        let cmd = bytes[2]

        // Async event pushed by headset: [0x01, 0x01, 0x01, propID, valLo, valHi]
        if cmd == 0x01 {
            let propID = bytes[3]
            if propID == Self.propBatteryLevel {
                let raw = Int(bytes[4]) | (Int(bytes[5]) << 8)
                let pct = max(0, min(100, (raw + 5) / 10))
                battery.percentage = pct
                battery.isOnline = true
                battery.lastUpdated = Date()
                onUpdate?(battery)
            } else if propID == Self.propChargeState {
                battery.charging = parseChargeState(bytes[4])
                battery.lastUpdated = Date()
                onUpdate?(battery)
            }
            return
        }

        // GET_PROPERTY response: [0x01, 0x01, 0x02, status, valLo, valHi]
        guard cmd == 0x02, let query = pendingQuery else { return }
        pendingQuery = nil

        let status = bytes[3]
        guard status == 0x00 else {
            // Headset is off or disconnected from receiver
            battery = .offline(.headset, name: "CORSAIR HS80 MAX")
            onUpdate?(battery)
            return
        }

        switch query {
        case .batteryLevel:
            let raw = Int(bytes[4]) | (Int(bytes[5]) << 8)
            let pct = max(0, min(100, (raw + 5) / 10))
            battery.percentage = pct
            battery.isOnline = true
            battery.lastUpdated = Date()
            onUpdate?(battery)
            // Immediately query charge state next
            pendingQuery = .chargeState
            sendGetProperty(Self.propChargeState)

        case .chargeState:
            battery.charging = parseChargeState(bytes[4])
            battery.lastUpdated = Date()
            onUpdate?(battery)
        }
    }

    private func parseChargeState(_ value: UInt8) -> ChargingState {
        switch value {
        case 1: .charging
        case 2: .discharging
        case 3: .full
        default: .unknown
        }
    }
}
