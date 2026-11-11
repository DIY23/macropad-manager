import Foundation

// Headless write check: exercises the exact HIDTransport + driver code the app
// uses, against the real device. Writes the starter profile, which is the same
// layout already on the pad, so the operation is idempotent.

let t = HIDTransport()
RunLoop.main.run(until: Date().addingTimeInterval(2.0))

guard let dev = t.devices.first(where: { $0.isWritable }) else {
    print("no writable macropad found (devices: \(t.devices.count))")
    exit(1)
}
print("device: \(dev.name)  id=\(dev.id)  \(String(format: "%04x:%04x", dev.vendorID, dev.productID))")
if let m = dev.model { print("model: \(m.displayName)  keys=\(m.buttonCount) knobs=\(m.knobCount)") }

let profile = StarterProfile.make()
let driver = CH57xK8850Driver()

do {
    let msgs = try driver.encode(profile: profile)
    var sent = 0
    for pass in 0..<driver.passes {
        for m in msgs {
            try t.send(m.bytes, to: dev.id)
            sent += 1
            Thread.sleep(forTimeInterval: driver.interMessageDelay)
        }
        print("pass \(pass + 1) done (\(sent) reports)")
    }
    print("SUCCESS: \(sent) reports accepted by the device")
    exit(0)
} catch {
    print("WRITE FAILED: \(error.localizedDescription)")
    exit(1)
}
