// utm-hscroll-send: forward horizontal scrolling over a UTM window to the guest.
//
// UTM's pointer devices have no horizontal wheel, so a sideways swipe on a
// Magic Mouse or trackpad never reaches a Linux guest. This watches scroll
// events on the Mac and, while the pointer is over the VM window, writes each
// horizontal gesture as lines "H <dx>" to 127.0.0.1:4749, where an ssh forward
// carries them to utm-hscroll-receive in the guest.
//
//   dx is in points, with macOS's sign: positive moves the content right.
//
// A gesture is horizontal or vertical as a whole, decided by its first few
// points of travel, so the sideways wobble of a vertical scroll is not sent.
// Events with Shift held are skipped: the guest already turns Shift + wheel
// into horizontal scrolling, and macOS reports Shift + vertical as horizontal.
//
// Needs no Accessibility or Input Monitoring permission: a global monitor for
// scroll-wheel events is allowed without one (key events are not), and window
// bounds from CGWindowList need no Screen Recording permission.
//
// Build:  swiftc -O -o ~/bin/utm-hscroll-send utm-hscroll-send.swift
// Run:    from a LaunchAgent (see the guide); optional argument: the port.
import AppKit
import Foundation

let utmBundle = "com.utmapp.UTM"
let port: UInt16 = CommandLine.arguments.count > 1 ? UInt16(CommandLine.arguments[1]) ?? 4749 : 4749
let windowCacheAge = 0.25
let axisDecideAt: CGFloat = 4  // points of travel before a gesture is called horizontal or vertical
let wheelLine: CGFloat = 40    // points per notch for a wheel without precise deltas

func log(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

/// One line-oriented TCP connection, reconnected lazily with a 1 s backoff.
final class Link {
    private var fd: Int32 = -1
    private var retryAt: TimeInterval = 0
    private var wasUp = false

    private func connect() -> Bool {
        let now = Date().timeIntervalSince1970
        if now < retryAt { return false }
        let s = socket(AF_INET, SOCK_STREAM, 0)
        guard s >= 0 else { retryAt = now + 1; return false }
        var one: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 0, tv_usec: 300_000)
        setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
        if !ok {
            close(s)
            retryAt = now + 1
            if wasUp { log("link: down"); wasUp = false }
            return false
        }
        fd = s
        wasUp = true
        log("link: up")
        return true
    }

    /// A peer that went away shows up as a readable socket with nothing to
    /// read; the first write to it would still succeed and be lost.
    private func peerGone() -> Bool {
        var byte: UInt8 = 0
        let n = recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
        return n == 0 || (n < 0 && errno != EAGAIN && errno != EWOULDBLOCK)
    }

    private func drop() {
        close(fd)
        fd = -1
        retryAt = Date().timeIntervalSince1970 + 1
        if wasUp { log("link: down"); wasUp = false }
    }

    func send(_ line: String) {
        if fd >= 0 && peerGone() { drop() }
        if fd < 0 && !connect() { return }
        let sent = line.withCString { write(fd, $0, strlen($0)) }
        if sent != line.utf8.count { drop() }
    }
}

struct Win: Equatable {
    let pid: pid_t
    let x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat
    func contains(_ p: CGPoint) -> Bool { p.x >= x && p.x < x + w && p.y >= y && p.y < y + h }
}

/// Normal (layer 0), visible windows, front to back.
func onscreenWindows() -> [Win] {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                kCGNullWindowID) as? [[String: Any]] else { return [] }
    var out: [Win] = []
    for w in list {
        guard (w[kCGWindowLayer as String] as? Int) == 0,
              let pid = w[kCGWindowOwnerPID as String] as? pid_t,
              let b = w[kCGWindowBounds as String] as? [String: CGFloat],
              let x = b["X"], let y = b["Y"], let ww = b["Width"], let wh = b["Height"] else { continue }
        if let a = w[kCGWindowAlpha as String] as? CGFloat, a == 0 { continue }
        out.append(Win(pid: pid, x: x, y: y, w: ww, h: wh))
    }
    return out
}

let link = Link()
var winCache: [Win] = []
var winCacheAt: TimeInterval = 0
var pidCache: pid_t?

/// Is the VM display (UTM's largest normal window; the library window is
/// smaller) the topmost window under the pointer?
func pointerOverVM() -> Bool {
    let now = Date().timeIntervalSince1970
    if now - winCacheAt > windowCacheAge {
        winCache = onscreenWindows()
        winCacheAt = now
        pidCache = NSRunningApplication.runningApplications(withBundleIdentifier: utmBundle).first?.processIdentifier
    }
    // NSEvent uses the bottom-left of the main screen; the window list uses the top-left.
    let m = NSEvent.mouseLocation
    let p = CGPoint(x: m.x, y: (NSScreen.screens.first?.frame.height ?? 0) - m.y)
    guard let pid = pidCache,
          let vm = winCache.filter({ $0.pid == pid && $0.w > 200 && $0.h > 200 }).max(by: { $0.w * $0.h < $1.w * $1.h }),
          vm.contains(p), let top = winCache.first(where: { $0.contains(p) }), top == vm else { return false }
    return true
}

enum Axis { case undecided, horizontal, vertical }
var gestureAxis = Axis.undecided
var gestureX: CGFloat = 0, gestureY: CGFloat = 0
var gestureOverVM = false

func scrolled(_ e: NSEvent) {
    if e.modifierFlags.contains(.shift) { return }
    if !e.hasPreciseScrollingDeltas {  // a wheel with a tilt or a second wheel: each event stands alone
        if e.scrollingDeltaX != 0 && pointerOverVM() {
            link.send(String(format: "H %.1f\n", e.scrollingDeltaX * wheelLine))
        }
        return
    }
    // The fingers' phase runs began .. ended; the momentum phase then carries the same gesture on.
    if e.phase.contains(.began) || e.phase.contains(.mayBegin) {
        gestureAxis = .undecided
        gestureX = 0
        gestureY = 0
        gestureOverVM = pointerOverVM()
    }
    if !gestureOverVM { return }
    let dx = e.scrollingDeltaX, dy = e.scrollingDeltaY
    if gestureAxis == .undecided {
        gestureX += dx
        gestureY += dy
        if abs(gestureX) + abs(gestureY) < axisDecideAt { return }
        gestureAxis = abs(gestureX) > abs(gestureY) ? .horizontal : .vertical
        if gestureAxis == .horizontal {
            link.send(String(format: "H %.1f\n", gestureX))  // what was held back while deciding
        }
        return
    }
    if gestureAxis == .horizontal && dx != 0 {
        link.send(String(format: "H %.1f\n", dx))
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)  // no Dock icon, never the front app
if NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel, handler: scrolled) == nil {
    log("no global scroll monitor; nothing will be forwarded")
    exit(1)
}
log("watching scroll events; sending to 127.0.0.1:\(port)")
app.run()  // the global monitor is fed by the application's event loop
