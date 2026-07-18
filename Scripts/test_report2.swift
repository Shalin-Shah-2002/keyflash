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

    // Open with seize option for exclusive access
    IOHIDDeviceOpen(d, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))

    // Test A: Output Report 3, NO report ID byte (just data byte)
    print("Test A: Output R3 [0x01] — just data, no rid byte")
    var bufA: [UInt8] = [0x01]
    let rA = bufA.withUnsafeMutableBufferPointer { IOHIDDeviceSetReport(d, kIOHIDReportTypeOutput, 3, $0.baseAddress!, 1) }
    print("  result: \(rA) (0=success)")
    sleep(2)
    bufA[0] = 0x00
    _ = bufA.withUnsafeMutableBufferPointer { IOHIDDeviceSetReport(d, kIOHIDReportTypeOutput, 3, $0.baseAddress!, 1) }
    sleep(1)

    // Test B: Feature Report 3, also try without rid byte
    print("Test B: Feature R3 [0x01, 0xFF, 0xFF, 0, 0] — full 5-byte payload")
    var bufB: [UInt8] = [0x01, 0xFF, 0xFF, 0, 0]
    let rB = bufB.withUnsafeMutableBufferPointer { IOHIDDeviceSetReport(d, kIOHIDReportTypeFeature, 3, $0.baseAddress!, 5) }
    print("  result: \(rB)")
    sleep(2)
    bufB = [0, 0, 0, 0, 0]
    _ = bufB.withUnsafeMutableBufferPointer { IOHIDDeviceSetReport(d, kIOHIDReportTypeFeature, 3, $0.baseAddress!, 5) }
    sleep(1)

    // Test C: Output RID=0 (no report ID), just byte [0x01]
    print("Test C: Output RID=0 [0x01]")
    var bufC: [UInt8] = [0x01]
    let rC = bufC.withUnsafeMutableBufferPointer { IOHIDDeviceSetReport(d, kIOHIDReportTypeOutput, 0, $0.baseAddress!, 1) }
    print("  result: \(rC)")
    sleep(2)
    bufC[0] = 0x00
    _ = bufC.withUnsafeMutableBufferPointer { IOHIDDeviceSetReport(d, kIOHIDReportTypeOutput, 0, $0.baseAddress!, 1) }
    sleep(1)

    print("=== DONE ===")
    IOHIDDeviceClose(d, 0)
}

IOHIDManagerClose(m, 0)
