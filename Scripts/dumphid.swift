import Foundation
import IOKit
import IOKit.hid

// Diagnostic 2: open the "Keyboard Backlight" device and read element values
// to identify which element controls brightness.

let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
IOHIDManagerSetDeviceMatching(manager, nil)
IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))

let devicesSet = IOHIDManagerCopyDevices(manager) as! Set<IOHIDDevice>

for device in devicesSet {
    let product = (IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String) ?? "?"
    let vendor = (IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int) ?? 0

    if vendor != 0x05ac { continue }
    guard product.contains("Keyboard Backlight") else { continue }

    print("=== Opening device: \(product) ===")

    let openResult = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
    print("open result: \(openResult)  (0 = success)")

    guard let elements = IOHIDDeviceCopyMatchingElements(device, nil, 0) else {
        print("  (no elements)")
        continue
    }

    for el in (elements as! [IOHIDElement]) {
        let usagePage = IOHIDElementGetUsagePage(el)
        let usage = IOHIDElementGetUsage(el)
        let type = IOHIDElementGetType(el)
        let cookie = IOHIDElementGetCookie(el)
        let reportID = IOHIDElementGetReportID(el)
        let reportSize = IOHIDElementGetReportSize(el)
        let reportCount = IOHIDElementGetReportCount(el)
        let logicalMin = IOHIDElementGetLogicalMin(el)
        let logicalMax = IOHIDElementGetLogicalMax(el)

        print("  cookie=\(cookie) type=\(type.rawValue) page=0x\(String(format:"%04x",usagePage)) usage=0x\(String(format:"%x",usage)) reportID=\(reportID) reportSize=\(reportSize) reportCount=\(reportCount) logical[\(logicalMin),\(logicalMax)]")

        // Try reading the current value via the raw C pointer API
        var valueRef: Unmanaged<IOHIDValue>? = Unmanaged<IOHIDValue>.passUnretained(IOHIDValueCreateWithIntegerValue(kCFAllocatorDefault, el, 0, 0))
        let readResult = withUnsafeMutablePointer(to: &valueRef) { (ptr: UnsafeMutablePointer<Unmanaged<IOHIDValue>?>) -> Int32 in
            // IOHIDDeviceGetValue expects UnsafeMutablePointer<Unmanaged<IOHIDValue>> (non-optional)
            // Cast the optional pointer to the non-optional form expected by the bridged API
            return ptr.withMemoryRebound(to: Unmanaged<IOHIDValue>.self, capacity: 1) { reboundPtr in
                IOHIDDeviceGetValue(device, el, reboundPtr)
            }
        }
        if readResult == 0, let v = valueRef {
            print("    -> current value: \(IOHIDValueGetIntegerValue(v.takeUnretainedValue()))")
        } else {
            print("    -> could not read value (err=\(readResult))")
        }
    }

    IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
}

IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
print("\n=== done ===")