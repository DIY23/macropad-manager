import Foundation
import IOKit
import IOKit.hid
import Combine

// MARK: - A connected device

struct ConnectedDevice: Identifiable, Hashable {
    let id: String                  // registry id, stable per physical port
    let name: String
    let vendorID: UInt16
    let productID: UInt16
    let serial: String
    let model: DeviceModel?
    let usagePage: Int
    let isWritable: Bool            // vendor config interface, not the keyboard one

    static func == (a: ConnectedDevice, b: ConnectedDevice) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

// MARK: - HID transport (IOKit, no third-party dependencies)

final class HIDTransport: ObservableObject {
    static let configUsagePage = 0xFF00
    static let knownVendorIDs: [UInt16] = [0x514C, 0x1189]

    @Published private(set) var devices: [ConnectedDevice] = []
    @Published private(set) var lastError: String?

    private var manager: IOHIDManager?
    private var handles: [String: IOHIDDevice] = [:]

    init() { start() }

    deinit { stop() }

    func start() {
        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        // One dictionary per vendor: kIOHIDVendorIDKey takes a single number,
        // not an array, so the array form silently matches nothing.
        let matching: [[String: Any]] = Self.knownVendorIDs.map { [kIOHIDVendorIDKey: Int($0)] }
        IOHIDManagerSetDeviceMatchingMultiple(m, matching as CFArray)

        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(m, { ctx, _, _, device in
            guard let ctx else { return }
            Unmanaged<HIDTransport>.fromOpaque(ctx).takeUnretainedValue().added(device)
        }, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(m, { ctx, _, _, device in
            guard let ctx else { return }
            Unmanaged<HIDTransport>.fromOpaque(ctx).takeUnretainedValue().removed(device)
        }, ctx)

        IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = m

        // Devices already present
        if let set = IOHIDManagerCopyDevices(m) as? Set<IOHIDDevice> {
            for d in set { added(d) }
        }
    }

    func stop() {
        if let m = manager {
            IOHIDManagerUnscheduleFromRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDManagerClose(m, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        manager = nil
        handles.removeAll()
        devices = []
    }

    private func intProperty(_ d: IOHIDDevice, _ key: String) -> Int? {
        (IOHIDDeviceGetProperty(d, key as CFString) as? NSNumber)?.intValue
    }

    private func stringProperty(_ d: IOHIDDevice, _ key: String) -> String? {
        IOHIDDeviceGetProperty(d, key as CFString) as? String
    }

    private func added(_ d: IOHIDDevice) {
        let vid = UInt16(truncatingIfNeeded: intProperty(d, kIOHIDVendorIDKey) ?? 0)
        let pid = UInt16(truncatingIfNeeded: intProperty(d, kIOHIDProductIDKey) ?? 0)
        let page = intProperty(d, kIOHIDPrimaryUsagePageKey) ?? 0
        let usage = intProperty(d, kIOHIDPrimaryUsageKey) ?? 0
        let serial = stringProperty(d, kIOHIDSerialNumberKey) ?? ""
        let location = intProperty(d, kIOHIDLocationIDKey) ?? 0

        // We only care about the vendor configuration interface. The keyboard
        // interface (usage page 1) is TCC-gated and must never be touched.
        guard page == Self.configUsagePage || (page >= 0xFF00 && usage != 0) else { return }

        let regID = "\(vid)-\(pid)-\(location)-\(page)"
        let model = DeviceModel.model(forVendor: vid, product: pid)
        let name = stringProperty(d, kIOHIDProductKey) ?? model?.displayName ?? "Macropad"

        handles[regID] = d
        let conn = ConnectedDevice(id: regID,
                                   name: name,
                                   vendorID: vid,
                                   productID: pid,
                                   serial: serial,
                                   model: model,
                                   usagePage: page,
                                   isWritable: page == Self.configUsagePage)
        DispatchQueue.main.async {
            if !self.devices.contains(where: { $0.id == regID }) {
                self.devices.append(conn)
            }
        }
    }

    private func removed(_ d: IOHIDDevice) {
        DispatchQueue.main.async {
            let gone = self.handles.filter { CFEqual($0.value, d) }.map(\.key)
            for k in gone { self.handles.removeValue(forKey: k) }
            self.devices.removeAll { gone.contains($0.id) }
        }
    }

    // MARK: raw report

    /// Sends one 64-byte payload under report ID 3 on the vendor interface.
    func send(_ report: [UInt8], to deviceID: String) throws {
        guard let dev = handles[deviceID] else { throw DriverError.deviceGone }
        let openResult = IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openResult == kIOReturnSuccess || openResult == kIOReturnExclusiveAccess else {
            throw DriverError.openFailed(openResult)
        }
        var buf = report
        if buf.count < 65 { buf += Array(repeating: 0, count: 65 - buf.count) }
        let payload = Array(buf[1..<65])          // report ID travels separately
        let rc = payload.withUnsafeBufferPointer { p -> IOReturn in
            IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, 3, p.baseAddress!, 64)
        }
        guard rc == kIOReturnSuccess else { throw DriverError.writeFailed(rc) }
    }
}

// MARK: - Errors

enum DriverError: LocalizedError {
    case deviceGone
    case openFailed(IOReturn)
    case writeFailed(IOReturn)
    case unsupportedModel(String)
    case nothingToWrite

    var errorDescription: String? {
        switch self {
        case .deviceGone: return "The macropad is no longer connected."
        case .openFailed(let r): return String(format: "Could not open the device (0x%08X).", r)
        case .writeFailed(let r): return String(format: "The device rejected a report (0x%08X).", r)
        case .unsupportedModel(let m): return "No driver for \(m) yet."
        case .nothingToWrite: return "There is nothing to write."
        }
    }
}

// MARK: - Driver protocol (the extension point for other keypads)

protocol DeviceDriver {
    var id: String { get }
    var model: DeviceModel { get }
    /// Encodes a profile into the exact report payloads for this firmware.
    func encode(profile: PadProfile) throws -> [DriverMessage]
    /// Timing the firmware needs between reports.
    var interMessageDelay: TimeInterval { get }
    var passes: Int { get }
}

struct DriverMessage {
    let label: String
    let bytes: [UInt8]     // 65 bytes: report ID 3 + 64 payload
}

// MARK: - CH57x K8850 (0xFD framing)

struct CH57xK8850Driver: DeviceDriver {
    let id = "ch57x-k8850"
    let model: DeviceModel = .k8850
    let interMessageDelay: TimeInterval = 0.050   // 4 ms loses writes on this firmware
    let passes = 2

    static let commit: [UInt8] = [0x03, 0xFD, 0xFE, 0xFF]

    func encode(profile: PadProfile) throws -> [DriverMessage] {
        var out: [DriverMessage] = []
        for (layerIndex, layer) in profile.layers.enumerated() where layerIndex < 3 {
            for b in 0..<model.buttonCount {
                let c = ControlID.button(b)
                let a = layer.action(c)
                guard !a.isEmpty else { continue }
                out.append(.init(label: "L\(layerIndex + 1) key \(b + 1)",
                                 bytes: Self.pad(try bind(layer: layerIndex, keyID: UInt8(b + 1), action: a))))
                out.append(.init(label: "L\(layerIndex + 1) key \(b + 1) commit", bytes: Self.pad(Self.commit)))
            }
            for k in 0..<model.knobCount {
                for part in KnobPart.allCases {
                    let c = ControlID.knob(k, part)
                    let a = layer.action(c)
                    guard !a.isEmpty else { continue }
                    let keyID = UInt8(17 + 3 * k + Int(part.index))
                    out.append(.init(label: "L\(layerIndex + 1) knob \(k + 1) \(part.rawValue)",
                                     bytes: Self.pad(try bind(layer: layerIndex, keyID: keyID, action: a))))
                    out.append(.init(label: "L\(layerIndex + 1) knob \(k + 1) \(part.rawValue) commit",
                                     bytes: Self.pad(Self.commit)))
                }
            }
        }
        guard !out.isEmpty else { throw DriverError.nothingToWrite }
        return out
    }

    /// bind: 03 FD <keyID> <layer+1> <kind> 00 <count> [00 00 <code>]*
    private func bind(layer: Int, keyID: UInt8, action: Action) throws -> [UInt8] {
        var msg: [UInt8] = [0x03, 0xFD, keyID, UInt8(layer + 1)]

        switch action.kind {
        case .none:
            throw DriverError.nothingToWrite

        case .keystroke:
            var seq: [[UInt8]] = []
            for u in action.usages {
                for m in modifierOrder where action.modifiers.contains(m) {
                    seq.append([0, 0, m.code])
                }
                seq.append([0, 0, u])
            }
            guard seq.count <= 18 else { throw DriverError.unsupportedModel("Macro longer than 18 keys") }
            msg += [0x01, 0x00, UInt8(seq.count)]
            for s in seq { msg += s }

        case .media:
            guard let mk = MediaKey(rawValue: action.mediaKey) else { throw DriverError.nothingToWrite }
            msg += [0x02, 0x00, 0x02, 0x00, 0x00,
                    UInt8(mk.code & 0xFF), 0x00, 0x00, UInt8(mk.code >> 8)]

        case .mouse:
            var mouse = [UInt8](repeating: 0, count: 17)
            mouse[0] = 1; mouse[1] = 4
            let mm: UInt8 = (action.mouseModifiers.contains(.ctrl) ? 0x01 : 0)
                           | (action.mouseModifiers.contains(.shift) ? 0x02 : 0)
                           | (action.mouseModifiers.contains(.alt) ? 0x04 : 0)
            mouse[4] = mm
            switch action.mouseButton {
            case "right":  mouse[7] = 0x02
            case "middle": mouse[7] = 0x04
            default:       mouse[7] = 0x01
            }
            if action.wheel != 0 { mouse[16] = UInt8(truncatingIfNeeded: action.wheel) }
            msg += [0x03]
            msg += mouse
        }
        return msg
    }

    static func pad(_ bytes: [UInt8]) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: 65)
        for (i, x) in bytes.enumerated() where i < 65 { b[i] = x }
        return b
    }
}

// MARK: - Registry

enum DriverRegistry {
    static func driver(for model: DeviceModel) -> DeviceDriver? {
        switch model.driverID {
        case "ch57x-k8850": return CH57xK8850Driver()
        default: return nil
        }
    }
}

// MARK: - Writer (progress reporting)

@MainActor
final class PadWriter: ObservableObject {
    enum Phase: Equatable {
        case idle
        case preparing
        case writing(done: Int, total: Int)
        case finished(messages: Int)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle

    func write(profile: PadProfile, model: DeviceModel, transport: HIDTransport, deviceID: String) {
        phase = .preparing
        guard let driver = DriverRegistry.driver(for: model) else {
            phase = .failed("No driver for \(model.displayName) yet.")
            return
        }
        do {
            let messages = try driver.encode(profile: profile)
            let total = messages.count * driver.passes
            phase = .writing(done: 0, total: total)

            Task { [weak self] in
                guard let self else { return }
                var done = 0
                do {
                    for _ in 0..<driver.passes {
                        for m in messages {
                            try transport.send(m.bytes, to: deviceID)
                            done += 1
                            await MainActor.run { self.phase = .writing(done: done, total: total) }
                            try await Task.sleep(nanoseconds: UInt64(driver.interMessageDelay * 1_000_000_000))
                        }
                    }
                    await MainActor.run { self.phase = .finished(messages: done) }
                } catch {
                    await MainActor.run { self.phase = .failed(error.localizedDescription) }
                }
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}
