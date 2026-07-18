import Foundation
import IOKit
import IOKit.hid

let testNum = Int(CommandLine.arguments[1])!

let m = IOHIDManagerCreate(kCFAllocatorDefault, 0)
IOHIDManagerSetDeviceMatching(m, nil)
IOHIDManagerOpen(m, 0)
let s = IOHIDManagerCopyDevices(m) as! Set<IOHIDDevice>

for d in s {
    let p = (IOHIDDeviceGetProperty(d, kIOHIDProductKey as CFString) as? String) ?? ""
    if p != "Keyboard Backlight" { continue }
    IOHIDDeviceOpen(d, 0)

    func f(_ rid: Int, _ payload: [UInt8]) {
        var r = [UInt8(rid)] + payload; let c = r.count
        _ = r.withUnsafeMutableBufferPointer { IOHIDDeviceSetReport(d, kIOHIDReportTypeFeature, rid, $0.baseAddress!, c) }
    }
    func o(_ rid: Int, _ payload: [UInt8]) {
        var r = [UInt8(rid)] + payload; let c = r.count
        _ = r.withUnsafeMutableBufferPointer { IOHIDDeviceSetReport(d, kIOHIDReportTypeOutput, rid, $0.baseAddress!, c) }
    }
    func off() { o(3, [0]); f(3, [0]); o(1, [0,0,0,0,0,0,0,0]); f(1, [0,0,0,0,0,0,0,0]) }

    switch testNum {
    case 1:
        print("TEST 1: OUTPUT Report3 on=1 >>> WATCH KEYBOARD (6s)"); fflush(stdout)
        o(3, [0x01]); sleep(6); off(); print("OFF")
    case 2:
        print("TEST 2: OUTPUT Report1 both fields >>> WATCH KEYBOARD (6s)"); fflush(stdout)
        o(1, [0x08,0x39,0x00,0x00, 0xFF,0xFF,0x00,0x00]); sleep(6); off(); print("OFF")
    case 3:
        print("TEST 3: FEATURE Report3 on=1 + bright 0xFFFF >>> WATCH KEYBOARD (6s)"); fflush(stdout)
        f(3, [0x01, 0xFF,0xFF,0x00,0x00]); sleep(6); off(); print("OFF")
    case 4:
        print("TEST 4: FEATURE Report1 both max >>> WATCH KEYBOARD (6s)"); fflush(stdout)
        f(1, [0x08,0x39,0x00,0x00, 0xFF,0xFF,0x00,0x00]); sleep(6); off(); print("OFF")
    case 5:
        print("TEST 5: OUTPUT Report3 big payload >>> WATCH KEYBOARD (6s)"); fflush(stdout)
        o(3, [0,0xFF,0xFF,0,0,0,0,0,0]); sleep(6); off(); print("OFF")
    case 6:
        print("TEST 6: OUT R3=1 + FEAT R1=max >>> WATCH KEYBOARD (6s)"); fflush(stdout)
        o(3, [0x01]); f(1, [0x08,0x39,0x00,0x00, 0xFF,0xFF,0x00,0x00]); sleep(6); off(); print("OFF")
    default: break
    }
    fflush(stdout)
    IOHIDDeviceClose(d, 0)
}

IOHIDManagerClose(m, 0)