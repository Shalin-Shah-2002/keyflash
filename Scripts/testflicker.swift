import Foundation
import IOKit
import IOKit.hid

// Try a sequence of feature report payloads and observe what works.
let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
IOHIDManagerSetDeviceMatching(manager, nil)
IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
let devicesSet = IOHIDManagerCopyDevices(manager) as! Set<IOHIDDevice>

for device in devicesSet {
    let product = (IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String) ?? "?"
    let vendor = (IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int) ?? 0
    if vendor != 0x05ac || !product.contains("Keyboard Backlight") { continue }

    print("=== \(product) ===")
    let openResult = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
    print("open: \(openResult)")

    func send(_ reportID: Int, _ payload: [UInt8], _ type: Int32 = kIOHIDReportTypeFeature) -> Int32 {
        var report: [UInt8] = [UInt8(reportID)] + payload
        return report.withUnsafeMutableBufferPointer { buf -> Int32 in
            guard let base = buf.baseAddress else { return -1 }
            return IOHIDDeviceSetReport(device, type, reportID, base, report.count)
        }
    }

    // Try: turn ON, observe (4s), turn OFF
    let onTests: [(String, Int, [UInt8])] = [
        ("R1: enable via 0x01 high threshold", 1, [0x01, 0x00, 0x00, 0x00, 0x00]),
        ("R1: brightness=0xFFFF + threshold high", 1, [0xA4, 0x39, 0x00, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0x00]),
        ("R3: on/off=1", 3, [0x01, 0x00, 0x00, 0x00, 0x00]),
        ("R3: brightness=0xFFFF", 3, [0x00, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]),
        ("R1 usage0x1=0x0001 (minimum brightness val)", 1, [0x01, 0x00, 0x00, 0x00, 0x00]),
        ("R1 usage0x1=0x4000 mid", 1, [0x00, 0x40, 0x00, 0x00, 0x00]),
        ("R1 usage0x1=0x3940 (14600 = max)", 1, [0x40, 0x39, 0x00, 0x00, 0x00]),
    ]

    for (label, rid, payload) in onTests {
        print(">>> \(label)")
        print("    setReport -> \(send(rid, payload))")
        print("    >>> KEYBOARD WATCH (4s)")
        sleep(4)
        print("    (turning off)")
        _ = send(3, [0x00, 0x00, 0x00, 0x00, 0x00])
        _ = send(1, [0x00, 0x00, 0x00, 0x00, 0x00])
        sleep(1)
        print("")
    }

    IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
}

IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
print("=== done ===")