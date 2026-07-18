import Foundation
import IOKit

// Try controlling keyboard backlight via AppleHIDKeyboard IOKit service
let matching = IOServiceMatching("AppleHIDKeyboard") as NSMutableDictionary
matching["IOPropertyMatch"] = ["HIDDefaultBehavior": "Keyboard"]

var iterator: io_iterator_t = 0
let kr = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
guard kr == KERN_SUCCESS else { print("Failed to get services"); exit(1) }

var count = 0
var service: io_object_t = IOIteratorNext(iterator)
while service != 0 {
    count += 1
    var nameC = [CChar](repeating: 0, count: 128)
    IORegistryEntryGetName(service, &nameC)
    let name = String(cString: nameC)

    print("Service \(count): \(name)")

    var conn: io_connect_t = 0
    let openResult = IOServiceOpen(service, mach_task_self_, 0, &conn)
    print("  IOServiceOpen: \(openResult) (0=success)")

    if openResult == KERN_SUCCESS {
        // Try selector 5 = setLEDBrightness
        var brightness: UInt64 = 65535
        let result1 = IOConnectCallScalarMethod(conn, 5, &brightness, 1, nil, nil)
        print("  Selector 5 (setLEDBrightness=65535): \(result1) (0=success)")
        print("  >>> CHECK KEYBOARD BACKLIGHT <<<")
        sleep(3)

        brightness = 0
        let result2 = IOConnectCallScalarMethod(conn, 5, &brightness, 1, nil, nil)
        print("  Selector 5 (setLEDBrightness=0): \(result2) (0=success)")

        IOServiceClose(conn)
    }

    IOObjectRelease(service)
    service = IOIteratorNext(iterator)
}

IOObjectRelease(iterator)
print("Done (found \(count) services)")
