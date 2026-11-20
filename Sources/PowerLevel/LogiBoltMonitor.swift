import Foundation
import IOKit
import IOKit.hid

final class LogiBoltMonitor {
    private static let vendorID = 0x046D
    private static let productID = 0xC548 // Logi Bolt Receiver
    private static let usagePage = 0xFF00

    private static let swIDGetFeature: UInt8 = 0x0A
    private static let swIDGetBattery: UInt8 = 0x0B

    private struct SlotInfo {
        var kind: DeviceKind
        var name: String
        var batteryFeatureIndex: UInt8?
    }

    private let manager: IOHIDManager
    private var device: IOHIDDevice?
    private var reportBuffer: UnsafeMutableBufferPointer<UInt8>?

    private var slots: [UInt8: SlotInfo] = [:]
    private var batteries: [DeviceKind: DeviceBattery] = [
        .mouse: .offline(.mouse, name: "Logitech Mouse"),
        .keyboard: .offline(.keyboard, name: "Logitech Keyboard")
    ]

    var onUpdate: (([DeviceKind: DeviceBattery]) -> Void)?

    var hasOnlineDevice: Bool {
        batteries.values.contains { $0.isOnline && $0.percentage != nil }
    }

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
                let monitor = Unmanaged<LogiBoltMonitor>.fromOpaque(context).takeUnretainedValue()
                monitor.attachDevice(dev)
            }
        }, ctx)

        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, dev in
            guard let context else { return }
            MainActor.assumeIsolated {
                let monitor = Unmanaged<LogiBoltMonitor>.fromOpaque(context).takeUnretainedValue()
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
        if slots.isEmpty {
            discoverPairedSlots()
        } else {
            for (slot, info) in slots {
                queryBattery(slot: slot, featureIndex: info.batteryFeatureIndex)
            }
        }
    }

    private func attachDevice(_ dev: IOHIDDevice) {
        guard device == nil else { return }
        guard IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else { return }

        let buf = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: 32)
        buf.initialize(repeating: 0)
        reportBuffer = buf
        device = dev

        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(
            dev,
            buf.baseAddress!,
            buf.count,
            { context, _, _, _, _, report, length in
                guard let context, length >= 7 else { return }
                let buffer = UnsafeBufferPointer(start: report, count: length)
                MainActor.assumeIsolated {
                    let monitor = Unmanaged<LogiBoltMonitor>.fromOpaque(context).takeUnretainedValue()
                    monitor.handleReport(buffer)
                }
            },
            ctx
        )
        IOHIDDeviceScheduleWithRunLoop(dev, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

        slots.removeAll()
        discoverPairedSlots()
    }

    private func detachDevice(_ dev: IOHIDDevice) {
        guard let current = device, CFEqual(current, dev) else { return }
        IOHIDDeviceClose(current, IOOptionBits(kIOHIDOptionsTypeNone))
        device = nil
        reportBuffer?.deallocate()
        reportBuffer = nil
        slots.removeAll()

        batteries[.mouse] = .offline(.mouse, name: batteries[.mouse]?.name)
        batteries[.keyboard] = .offline(.keyboard, name: batteries[.keyboard]?.name)
        onUpdate?(batteries)
    }

    private func discoverPairedSlots() {
        // Query Bolt receiver register 0xB5 for pairing info (0x50 + slot) and name (0x60 + slot)
        for slot: UInt8 in 1...6 {
            sendShort([0x10, 0xFF, 0x83, 0xB5, 0x50 + slot, 0x00, 0x00])
            sendShort([0x10, 0xFF, 0x83, 0xB5, 0x60 + slot, 0x01, 0x00])
        }
    }

    private func queryBattery(slot: UInt8, featureIndex: UInt8?) {
        if let featureIndex {
            // Unified Battery (0x1004) function 1: get_status
            sendLong([0x11, slot, featureIndex, (1 << 4) | Self.swIDGetBattery])
        } else {
            // Root (0x0000) function 0: getFeature(0x1004 = Unified Battery)
            sendLong([0x11, slot, 0x00, Self.swIDGetFeature, 0x10, 0x04])
        }
    }

    private func sendShort(_ payload: [UInt8]) {
        guard let dev = device else { return }
        var report = payload
        if report.count < 7 {
            report.append(contentsOf: repeatElement(0, count: 7 - report.count))
        }
        report.withUnsafeBytes { raw in
            _ = IOHIDDeviceSetReport(
                dev,
                kIOHIDReportTypeOutput,
                CFIndex(0x10),
                raw.baseAddress!.assumingMemoryBound(to: UInt8.self),
                7
            )
        }
    }

    private func sendLong(_ payload: [UInt8]) {
        guard let dev = device else { return }
        var report = payload
        if report.count < 20 {
            report.append(contentsOf: repeatElement(0, count: 20 - report.count))
        }
        report.withUnsafeBytes { raw in
            _ = IOHIDDeviceSetReport(
                dev,
                kIOHIDReportTypeOutput,
                CFIndex(0x11),
                raw.baseAddress!.assumingMemoryBound(to: UInt8.self),
                20
            )
        }
    }

    private func handleReport(_ bytes: UnsafeBufferPointer<UInt8>) {
        guard bytes.count >= 7 else { return }
        let reportID = bytes[0]
        let slot = bytes[1]

        // 1. Bolt receiver 0xB5 pairing info & device name responses (long report, device 0xFF)
        if reportID == 0x11 && slot == 0xFF && bytes[2] == 0x83 && bytes[3] == 0xB5 {
            let sub = bytes[4]
            if sub >= 0x51 && sub <= 0x56 {
                let targetSlot = sub - 0x50
                let typeByte = bytes[5]
                let isLinked = (typeByte & 0x40) == 0
                let rawType = typeByte & 0x0F
                guard isLinked else { return }

                let kind: DeviceKind? = switch rawType {
                case 0x01: .keyboard
                case 0x02, 0x08, 0x09: .mouse
                default: nil
                }
                guard let kind else { return }

                if slots[targetSlot] == nil {
                    slots[targetSlot] = SlotInfo(kind: kind, name: kind.fallbackName, batteryFeatureIndex: nil)
                } else {
                    slots[targetSlot]?.kind = kind
                }
                queryBattery(slot: targetSlot, featureIndex: slots[targetSlot]?.batteryFeatureIndex)
            } else if sub >= 0x61 && sub <= 0x66 && bytes.count >= 8 {
                let targetSlot = sub - 0x60
                let nameLen = Int(bytes[6])
                let end = min(7 + nameLen, bytes.count)
                if nameLen > 0, end > 7,
                   let name = String(bytes: bytes[7..<end], encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !name.isEmpty,
                   var info = slots[targetSlot] {
                    info.name = name
                    slots[targetSlot] = info
                    if var bat = batteries[info.kind] {
                        bat.name = name
                        batteries[info.kind] = bat
                        onUpdate?(batteries)
                    }
                }
            }
            return
        }

        // 2. Device connection / disconnection notification (short report 0x10, subID 0x41)
        if reportID == 0x10 && bytes[2] == 0x41 && (1...6).contains(slot) {
            if let info = slots[slot] {
                let linkLost = (bytes[4] & 0x40) != 0
                if linkLost {
                    batteries[info.kind] = .offline(info.kind, name: info.name)
                    onUpdate?(batteries)
                } else {
                    queryBattery(slot: slot, featureIndex: info.batteryFeatureIndex)
                }
            } else {
                // New or previously undiscovered slot just connected
                discoverPairedSlots()
            }
            return
        }

        // 2b. HID++ 1.0 error (0x8F) for a known slot (e.g. 0x09 = ERR_RESOURCE_ERROR when device is off)
        if reportID == 0x10 && bytes[2] == 0x8F, let info = slots[slot] {
            let errCode = bytes[5]
            if errCode == 0x09 || errCode == 0x04 {
                if batteries[info.kind]?.isOnline == true {
                    batteries[info.kind] = .offline(info.kind, name: info.name)
                    onUpdate?(batteries)
                }
            }
            return
        }

        // 3. HID++ 2.0 responses for a known slot
        guard reportID == 0x11, var info = slots[slot] else { return }
        let featureIndex = bytes[2]
        let funcAndSw = bytes[3]
        let swID = funcAndSw & 0x0F
        let fn = (funcAndSw & 0xF0) >> 4

        // Root GetFeature(0x1004) response
        if featureIndex == 0x00 && swID == Self.swIDGetFeature {
            let discoveredIndex = bytes[4]
            if discoveredIndex != 0 {
                info.batteryFeatureIndex = discoveredIndex
                slots[slot] = info
                queryBattery(slot: slot, featureIndex: discoveredIndex)
            }
            return
        }

        // Unified Battery (0x1004) response (fn 1, swID 0x0B) or async event (fn 0, swID 0x00)
        if let batIdx = info.batteryFeatureIndex, featureIndex == batIdx,
           (fn == 1 && swID == Self.swIDGetBattery) || (fn == 0 && swID == 0x00) {
            let pct = max(0, min(100, Int(bytes[4])))
            let charging: ChargingState = switch bytes[6] {
            case 0: .discharging
            case 1, 2: .charging
            case 3: .full
            default: .unknown
            }

            batteries[info.kind] = DeviceBattery(
                kind: info.kind,
                name: info.name,
                percentage: pct,
                charging: charging,
                isOnline: true,
                lastUpdated: Date()
            )
            onUpdate?(batteries)
        }
    }
}
