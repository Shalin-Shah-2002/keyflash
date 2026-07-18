import Foundation
import IOKit
import IOKit.hid

let m = IOHIDManagerCreate(kCFAllocatorDefault, 0)
IOHIDManagerSetDeviceMatching(m, nil)
IOHIDManagerOpen(m, 0)
let s = IOHIDManagerCopyDevices(m) as! Set<IOHIDDevice>

for d in s {
    let p = (IOHIDDeviceGetProperty(d, kIOHIDProductKey as CFString) as? String) ?? ""
    guard p == "Keyboard Backlight" else { continue }

    IOHIDDeviceOpen(d, 0)

    func send(_ type: IOHIDReportType, _ rid: Int, _ payload: [UInt8]) -> Int32 {
        var r = [UInt8(rid)] + payload
        let cnt = r.count
        return r.withUnsafeMutableBufferPointer { buf in
            IOHIDDeviceSetReport(d, type, rid, buf.baseAddress!, cnt)
        }
    }

    // Test 1: Output Report 3, [0x01]
    print("Test 1: Output R3 [0x01] — watch keyboard")
    let r1 = send(kIOHIDReportTypeOutput, 3, [0x01])
    print("  result: \(r1) (0=success)")
    sleep(3)
    _ = send(kIOHIDReportTypeOutput, 3, [0x00])
    sleep(1)

    // Test 2: Feature Report 3, full payload
    print("Test 2: Feature R3 [0x01, 0xFFFF, 0, 0]")
    _ = send(kIOHIDReportTypeFeature, 3, [0x01, 0xFF, 0xFF, 0, 0])
    sleep(3)
    _ = send(kIOHIDReportTypeFeature, 3, [0, 0, 0, 0, 0])
    sleep(1)

    // Test 3: Feature Report 1
    print("Test 3: Feature R1")
    _ = send(kIOHIDReportTypeFeature, 1, [0xFF, 0xFF, 0, 0, 0, 0, 0, 0, 0])
    sleep(3)
    _ = send(kIOHIDReportTypeFeature, 1, [0, 0, 0, 0, 0, 0, 0, 0, 0])
    sleep(1)

    // Test 4: Output Report 1
    print("Test 4: Output R1 [0xFF]")
    _ = send(kIOHIDReportTypeOutput, 1, [0xFF])
    sleep(3)
    _ = send(kIOHIDReportTypeOutput, 1, [0x00])
    sleep(1)

    // Test 5: Feature R3 short
    print("Test 5: Feature R3 [0x01] short")
    _ = send(kIOHIDReportTypeFeature, 3, [0x01])
    sleep(3)
    _ = send(kIOHIDReportTypeFeature, 3, [0x00])
    sleep(1)

    // Test 6: Output R3 + Feature R1 combined
    print("Test 6: OUT R3 [1] + FEAT R1 [max]")
    _ = send(kIOHIDReportTypeOutput, 3, [0x01])
    _ = send(kIOHIDReportTypeFeature, 1, [0xFF, 0xFF, 0, 0, 0, 0, 0, 0, 0])
    sleep(3)
    _ = send(kIOHIDReportTypeOutput, 3, [0x00])
    _ = send(kIOHIDReportTypeFeature, 1, [0, 0, 0, 0, 0, 0, 0, 0, 0])
    sleep(1)

    IOHIDDeviceClose(d, 0)
    print("=== DONE ===")
}

IOHIDManagerClose(m, 0)
