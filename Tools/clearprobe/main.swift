import Foundation

// Clear-encoding experiment.
//
// Binds keys 1-7 to letters, then overwrites keys 1-6 with six different
// candidate "no function" encodings. Key 7 is left alone as a control.
//
//   key 1  a   bind type 0, count 1, usage 0
//   key 2  b   bind type 1, count 1, usage 0        (what 1.7.0 shipped)
//   key 3  c   bind type 1, count 0
//   key 4  d   bind type 0, count 0
//   key 5  e   bind type 3 (mouse), all-zero payload
//   key 6  f   bind type 2 (media), count 1, code 0
//   key 7  g   CONTROL - untouched, must still type 'g'
//
// Press keys 1-7 in a text field. Key 7 typing 'g' proves the layer is live;
// any of 1-6 that types nothing is a working clear.

let t = HIDTransport()
RunLoop.main.run(until: Date().addingTimeInterval(2.0))
guard let dev = t.devices.first(where: { $0.isWritable }) else {
    print("no writable macropad found — connect the USB cable"); exit(1)
}
print("device:", dev.model?.displayName ?? dev.name)

func pad(_ b: [UInt8]) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: 65)
    for (i, x) in b.enumerated() where i < 65 { out[i] = x }
    return out
}
func send(_ b: [UInt8]) {
    try? t.send(pad(b), to: dev.id)
    Thread.sleep(forTimeInterval: 0.05)
    try? t.send(pad([0x03, 0xFD, 0xFE, 0xFF]), to: dev.id)
    Thread.sleep(forTimeInterval: 0.05)
}

let layer: UInt8 = 1

// Seed: a..g on keys 1..7 (HID 0x04...)
for i in 0..<7 { send([0x03, 0xFD, UInt8(i + 1), layer, 0x01, 0x00, 0x01, 0x00, 0x00, UInt8(0x04 + i)]) }
print("seeded keys 1-7 with a b c d e f g")

// Mouse record: type 3 followed by the 17-byte payload, all zeros = no action.
let mouseZero: [UInt8] = [0x03, 0xFD, 0x05, layer, 0x03] + [UInt8](repeating: 0, count: 17)

let variants: [(String, [UInt8])] = [
    ("1 type0 count1 usage0", [0x03, 0xFD, 0x01, layer, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00]),
    ("2 type1 count1 usage0", [0x03, 0xFD, 0x02, layer, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00]),
    ("3 type1 count0",        [0x03, 0xFD, 0x03, layer, 0x01, 0x00, 0x00]),
    ("4 type0 count0",        [0x03, 0xFD, 0x04, layer, 0x00, 0x00, 0x00]),
    ("5 mouse zeros",         mouseZero),
    ("6 media code0",         [0x03, 0xFD, 0x06, layer, 0x02, 0x00, 0x01, 0x00, 0x00, 0x00]),
]

for _ in 0..<2 {
    for (_, rec) in variants { send(rec) }
}

for (name, rec) in variants {
    print("  key \(rec[2])  <-  \(name)")
}
print("")
print("key 7 still types 'g' (control).")
print("Now press keys 1-7 into a text field and report which still type a letter.")
