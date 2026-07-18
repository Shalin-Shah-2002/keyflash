import Foundation

// Try to communicate with com.apple.backlightd via XPC
let service = "com.apple.backlightd"

print("Connecting to \(service)...")

// Try XPC connection
let conn = xpc_connection_create_mach_service(service, nil, 0)
xpc_connection_set_event_handler(conn) { event in
    print("XPC event: \(event)")
}
xpc_connection_resume(conn)

// Try setting keyboard brightness via property
let msg = xpc_dictionary_create(nil, nil, 0)
xpc_dictionary_set_string(msg, "key", "KeyboardBacklightBrightness")
xpc_dictionary_set_double(msg, "value", 1.0)

print("Sending XPC message...")
xpc_connection_send_message_with_reply_sync(conn, msg)
print("Sent!")

sleep(2)
print("Done")
