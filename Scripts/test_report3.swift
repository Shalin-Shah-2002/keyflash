import Foundation
import IOKit
import IOKit.hid

let m = IOHIDManagerCreate(kCFAllocatorDefault, 0)
IOHIDManagerSetDeviceMatching(m, nil)
IOHIDManagerOpen(m, 0)
let devices = IOHIDManagerCopyDevices(m) as! Set<IOHIDDevice>

for d in devices {
    let p = (IOHIDDeviceGetProperty(d, kIOHIDProductKey as CFString) as? String) ?? ""
    guard p == "Keyboard Backlight" else { continue }

    IOHIDDeviceOpen(d, 0)
    print("Opened Keyboard Backlight")

    // Test 1: WITHOUT report ID in buffer (let IOHIDDeviceSetReport add it)
    print("\nTest 1: No report ID in buffer")
    var buf1: [UInt8] = [0x01, 0xFF, 0xFF, 0, 0]  // just on+brightness, no rid
    let cnt1 = buf1.count
    let r1 = buf1.withUnsafeMutableBufferPointer {
        IOHIDDeviceSetReport(d, kIOHIDReportTypeFeature, 3, $0.baseAddress!, cnt1)
    }
    print("  result: \(r1)")
    sleep(2)

    // Test 2: Output report without report ID
    print("\nTest 2: Output without rid")
    var buf2: [UInt8] = [0x01]
    let r2 = buf2.withUnsafeMutableBufferPointer {
        IOHIDDeviceSetReport(d, kIOHIDReportTypeOutput, 3, $0.baseAddress!, 1)
    }
    print("  result: \(r2)")
    sleep(2)

    // Test 3: Use short payload - just on/off byte for feature
    print("\nTest 3: Feature R3, just [0x01] no rid")
    var buf3: [UInt8] = [0x01]
    let r3 = buf3.withUnsafeMutableBufferPointer {
        IOHIDDeviceSetReport(d, kIOHIDReportTypeFeature, 3, $0.baseAddress!, 1)
    }
    print("  result: \(r3)")
    sleep(2)

    // Test 4: Reset - feature R3 without rid, zeroes
    var buf4: [UInt8] = [0x00, 0x00, 0x00, 0x00, 0x00]
    _ = buf4.withUnsafeMutableBufferPointer {
        IOHIDDeviceSetReport(d, kIOHIDReportTypeFeature, 3, $0.baseAddress!, 5)
    }

    // Test 5: IOHIDDeviceSetReport with kIOHIDReportTypeOutput and no rid
    print("\nTest 5: Feature R3 with rid=0 (no rid)")
    var buf5: [UInt8] = [0x01, 0xFF, 0xFF, 0, 0]
    let r5 = buf5.withUnsafeMutableBufferPointer {
        IOHIDDeviceSetReport(d, kIOHIDReportTypeFeature, 0, $0.baseAddress!, 5)
    }
    print("  result: \(r5)")
    sleep(3)

    // Turn off
    var bufOff: [UInt8] = [0x00, 0x00, 0x00, 0x00, 0x00]
    _ = bufOff.withUnsafeMutableBufferPointer {
        IOHIDDeviceSetReport(d, kIOHIDReportTypeFeature, 3, $0.baseAddress!, 5)
    }

    IOHIDDeviceClose(d, 0)
    print("\n=== DONE ===")
}

IOHIDManagerClose(m, 0)
