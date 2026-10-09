// Pointer driver for the shoot scripts: `mouse move X Y` / `mouse click X Y` / `mouse scroll X Y DY`
// (points, CG top-left origin; DY in lines, negative scrolls the content up).
// System Events can click AX elements but cannot hover, and the hover lift is half of what the list shows.
// Must run under Terminal.app (term.sh): posting CGEvents needs the Accessibility grant Terminal holds.
import CoreGraphics
import Foundation

let a = CommandLine.arguments
guard a.count >= 4, let x = Double(a[2]), let y = Double(a[3]) else {
    FileHandle.standardError.write("usage: mouse move|click X Y | mouse scroll X Y DY\n".data(using: .utf8)!); exit(2)
}
let p = CGPoint(x: x, y: y)
func post(_ t: CGEventType) { CGEvent(mouseEventSource: nil, mouseType: t, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap) }
post(.mouseMoved)
if a[1] == "scroll", a.count == 5, let dy = Int32(a[4]) {
    // Ten small wheel steps read as a smooth scroll on film; one big one jumps.
    for _ in 0..<10 {
        CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: dy * 4, wheel2: 0, wheel3: 0)?.post(tap: .cghidEventTap)
        usleep(30_000)
    }
}
if a[1] == "click" { usleep(80_000); post(.leftMouseDown); usleep(60_000); post(.leftMouseUp) }
