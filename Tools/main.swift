import Foundation

// Headless encoder check: builds the starter profile and prints the exact
// reports the app would send, so it can be diffed against the known-good
// node-hid output captured earlier.

let profile = StarterProfile.make()
let driver = CH57xK8850Driver()

func hex(_ bytes: ArraySlice<UInt8>) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
}

do {
    let msgs = try driver.encode(profile: profile)
    print("messages: \(msgs.count)  passes: \(driver.passes)  gap: \(driver.interMessageDelay)s")
    for m in msgs.prefix(6) {
        print("  \(m.label.padding(toLength: 26, withPad: " ", startingAt: 0)) \(hex(m.bytes.prefix(14)))")
    }

    let checks: [(String, String)] = [
        ("L1 key 1", "03fd01010100020000f4000006"),   // cmd+c
        ("L1 key 4", "03fd04010100020000f400001a"),   // cmd+z  (AZERTY z = 0x1a)
        ("L1 key 6", "03fd06010100020000f4000014"),   // cmd+a  (AZERTY a = 0x14)
    ]
    var ok = true
    for (label, want) in checks {
        let got = msgs.first { $0.label == label }.map { hex($0.bytes.prefix(13)) } ?? "missing"
        let pass = got == want
        ok = ok && pass
        print("\(pass ? "OK  " : "FAIL") \(label): got \(got) want \(want)")
    }
    exit(ok ? 0 : 1)
} catch {
    print("encode error: \(error)")
    exit(1)
}
