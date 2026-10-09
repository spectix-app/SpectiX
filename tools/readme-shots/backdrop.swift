// A plain dark backdrop window for clips: covers whatever the owner has open behind
// the shot (browser tabs, bookmarks, avatars) so it never reaches a recording.
//   backdrop <x> <y> <w> <h>     (CG coords: top-left origin, points)
// SIGUSR1 raises it again — the clip rig uses that to push an already-raised
// Terminal window back behind it before the next take.
import Cocoa

let a = CommandLine.arguments.dropFirst().compactMap { Double($0) }
guard a.count == 4, let main = NSScreen.screens.first else {
    FileHandle.standardError.write("usage: backdrop x y w h\n".data(using: .utf8)!); exit(2)
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let rect = NSRect(x: a[0], y: main.frame.height - a[1] - a[3], width: a[2], height: a[3])
let win = NSWindow(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false)
// Black = the video's own ground, so a clip's edges vanish into the frame.
win.backgroundColor = .black
win.hasShadow = false
func raise() { app.activate(ignoringOtherApps: true); win.orderFrontRegardless() }
raise()
signal(SIGUSR1, SIG_IGN)
let src = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
src.setEventHandler { raise() }
src.resume()
app.run()
