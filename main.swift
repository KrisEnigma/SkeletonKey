import AppKit

let app = NSApplication.shared
let delegate = KrisKVMAppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
