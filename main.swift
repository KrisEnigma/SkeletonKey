import AppKit

let app = NSApplication.shared
let delegate = SkeletonKeyAppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
