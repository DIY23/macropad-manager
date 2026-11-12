import Foundation

// Diagnostic: bind keys 1-4 to a,b,c,d, then try four different "clear"
// encodings, one per key. Press the keys afterwards; any that still type a
// letter tells us that encoding does not clear.
//
//   key 1  letter 'a'  then  bind type 0, count 1, entry 00 00 00
//   key 2  letter 'b'  then  bind type 1, count 1, entry 00 00 00   (current)
//   key 3  letter 'c'  then  bind type 1, count 0
//   key 4  letter 'd'  then  bind type 0, count 0

let t = HIDTransport()
RunLoop.main.run(until: Date().addingTimeInterval(2.0))
guard let dev = t.devices.first(where: { $0.isWritable }) else {
    print("no writable macropad found"); exit(1)
}
print("device:", dev.model?.displayName ?? dev.name)

func pad(_ b: [UInt8]) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: 65)
    for (i, x) in b.enumerated() where i < 65 { out[i] = x }
    return out
}

let commit: [UInt8] = [0x03, 0xFD, 0xFE, 0xFF]
let layer: UInt8 = 1

// 1. known-good bindings: a, b, c, d  (HID 0x04..0x07)
for i in 0..<4 {
    let rec: [UInt8] = [0x03, 0xFD, UInt8(i + 1), layer, 0x01, 0x00, 0x01, 0x00, 0x00, UInt8(0x04 + i)]
    try! t.send(pad(rec), to: dev.id); Thread.sleep(forTimeInterval: 0.05)
    try! t.send(pad(commit), to: dev.id); Thread.sleep(forTimeInterval: 0.05)
}
print("bound keys 1-4 to a b c d")

// 2. the four candidate clear encodings
let variants: [(String, [UInt8])] = [
    ("type0 count1 usage0", [0x03, 0xFD, 0x01, layer, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00]),
    ("type1 count1 usage0", [0x03, 0xFD, 0x02, layer, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00]),
    ("type1 count0",        [0x03, 0xFD, 0x03, layer, 0x01, 0x00, 0x00]),
    ("type0 count0",        [0x03, 0xFD, 0x04, layer, 0x00, 0x00, 0x00]),
]
for (name, rec) in variants {
    try! t.send(pad(rec), to: dev.id); Thread.sleep(forTimeInterval: 0.05)
    try! t.send(pad(commit), to: dev.id); Thread.sleep(forTimeInterval: 0.05)
    print("  key", rec[2], "<-", name, rec.map { String(format: "%02x", $0) }.joined(separator: " "))
}

// 3. second pass so nothing is lost to timing
for (_, rec) in variants {
    try! t.send(pad(rec), to: dev.id); Thread.sleep(forTimeInterval: 0.05)
    try! t.send(pad(commit), to: dev.id); Thread.sleep(forTimeInterval: 0.05)
}
print("done — press keys 1-4 and report which still type a letter")
