import Foundation
import IOKit
import IOKit.hid

// Test: control the keyboard backlight by sending feature reports.
// We'll iterate through payloads and print what we're trying with delays.

let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
IOHIDManagerSetDeviceMatching(manager, nil)
IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))

let devicesSet = IOHIDManagerCopyDevices(manager) as! Set<IOHIDDevice>

for device in devicesSet {
    let product = (IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String) ?? "?"
    let vendor = (IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int) ?? 0

    if vendor != 0x05ac { continue }
    guard product.contains("Keyboard Backlight") else { continue }

    print("=== Found: \(product) ===")
    let openResult = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
    print("open result: \(openResult)")
    print("")

    func setFeatureReport(reportID: Int, payload: [UInt8]) -> Int32 {
        var report: [UInt8] = [UInt8(reportID)] + payload
        let count = report.count
        return report.withUnsafeMutableBufferPointer { buf -> Int32 in
            guard let base = buf.baseAddress else { return -1 }
            return IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, reportID, base, count)
        }
    }

    func setOutputReport(reportID: Int, payload: [UInt8]) -> Int32 {
        var report: [UInt8] = [UInt8(reportID)] + payload
        let count = report.count
        return report.withUnsafeMutableBufferPointer { buf -> Int32 in
            guard let base = buf.baseAddress else { return -1 }
            return IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, reportID, base, count)
        }
    }

    // Test sequence — each entry: (label, reportType, id, payload)
    let tests: [(String, Int, [UInt8])] = [
        ("1) Report 1, usage 0x1 peak (100=low, 14660=high); set high threshold", 1, [0x64, 0x39, 0x00, 0x00, 0x00]),
        ("2) Report 1, usage 0x2 brightness max (0xFFFF LE)", 1, [0xFF, 0xFF, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]),
        ("3) Report 3, usage 0x3 on/off toggle = 1 (feature)", 3, [0x01, 0x00, 0x00, 0x00, 0x00]),
        ("4) Report 3, usage 0x4 brightness max = 0xFFFF (feature)", 3, [0x00, 0xFF, 0xFF, 0x00, 0x00]),
    ]

    for (label, rid, payload) in tests {
        print(">>> \(label)")
        let res = setFeatureReport(reportID: rid, payload: payload)
        print("    result: \(res)  (0=success)")
        print("    >>> LOOK AT YOUR KEYBOARD NOW <<<")
        sleep(4)
        print("    (turning off)")
        _ = setFeatureReport(reportID: 1, payload: [0x00, 0x00, 0x00, 0x00, 0x00])
        _ = setFeatureReport(reportID: 3, payload: [0x00, 0x00, 0x00, 0x00, 0x00])
        sleep(2)
        print("")
    }

    IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
}

IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
print("=== done ===")