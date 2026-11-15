import Cocoa
import ServiceManagement
import QuartzCore
import CoreImage
import ImageIO


let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
