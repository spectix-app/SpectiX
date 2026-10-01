import Cocoa

// MARK: - Main window
//
// A floating glass panel listing every project. The window itself is
// transparent (isOpaque = false) so a behind-window NSVisualEffectView blurs the
// real desktop through it — that's the "Liquid Glass" look on macOS 15. The
// titlebar is hidden and content runs full-bleed; rows are individual glass
// cards that brighten + glow on hover. Click a row → jump to its VSCode + mark seen.

// The grouped list model (DisplayItem, folder ordering, collapse) lives in
// ListModel.swift and is shared with the menu-bar dropdown.

// MARK: - Drag-to-reorder
//
// Every header and child carries a grip on its leading edge. Grabbing the grip
// starts a row drag; grabbing anywhere else keeps the normal click (jump on a
// child, collapse on a header). Headers reorder the folder groups; children
// reorder only within their own group. The custom order is in-memory only — it
// rides reloads but resets on app restart.

let reorderType = NSPasteboard.PasteboardType("com.spectix.row")

// The leading status rail, which doubles as the reorder grip: a thin vertical bar,
// tinted by status, that the user grabs to drag a row up/down. The visible bar sits
// inside a wider transparent grab zone so it's an easy target, and shows an open-hand
// cursor to read as draggable.
final class RailGrip: NSView {
    private let bar = NSView()
    private let baseW: CGFloat = 3
    private let baseH: CGFloat
    // How far the bar grows once the row is pointed at or selected. Height clears the
    // 26pt grab zone at 1.67× — deliberately: the zone is a hit target, and nothing
    // clips to it (neither this view nor the card masks its bounds).
    private let activeScaleH: CGFloat = 1.67
    // Always half the width, so both ends stay true semicircles — a capsule, never a
    // rounded rectangle. Widening the bar without moving this in step is exactly what
    // turned the ends square-ish the one time width was tried.
    private var barRadius: CGFloat { baseW / 2 }
    private lazy var heightC = bar.heightAnchor.constraint(equalToConstant: baseH)
    // Two independent reasons to be lit, one look. Hover is transient and selection
    // outlives it, so they cannot share a flag — a row that is both, then un-hovered,
    // must stay lit for being selected.
    private var hovered = false
    private var selected = false
    private var isActive: Bool { hovered || selected }
    private var tint: NSColor = .clear

    init(barHeight: CGFloat = 18) {
        self.baseH = barHeight
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        bar.wantsLayer = true
        bar.layer?.cornerRadius = barRadius
        bar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bar)
        NSLayoutConstraint.activate([
            bar.centerXAnchor.constraint(equalTo: centerXAnchor),
            bar.centerYAnchor.constraint(equalTo: centerYAnchor),
            bar.widthAnchor.constraint(equalToConstant: baseW),
            heightC,
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func setColor(_ c: NSColor) {
        tint = c
        bar.layer?.backgroundColor = c.cgColor
        bar.layer?.shadowColor = c.cgColor
    }

    // Grow the bar a notch on hover ("变大一圈 / 拉长") — the bar is centered by its
    // centerX/centerY constraints, so animating width + height grows it symmetrically
    // about the center (up AND down, left AND right), not from one edge like a layer
    // scale would. The grab zone (RailGrip bounds) is unchanged.
    func setHovered(_ on: Bool, animated: Bool) {
        guard on != hovered else { return }
        hovered = on
        refresh(animated: animated)
    }

    // The selected row's rail wears the same grown, glowing look as a hovered one, and
    // keeps it while the pointer is elsewhere. Driven by ChildCell.setSelected off the
    // table's selection channel, not off the hover lift.
    func setSelected(_ on: Bool, animated: Bool) {
        guard on != selected else { return }
        selected = on
        refresh(animated: animated)
    }

    private func refresh(animated: Bool) {
        let on = isActive
        // ★ Lengthen ONLY — the width never changes (2026-09-04, asked for and rejected
        // in the same sitting: a fatter bar was tried on request and taken back on
        // sight). The rail grows about its center without getting chunkier.
        heightC.constant = on ? baseH * activeScaleH : baseH
        // The halo. Sized to the bar's TARGET box rather than tracked frame-by-frame:
        // an autolayout animation moves the frame without re-running layout(), so a
        // path chasing the live bounds would simply lag. At 0.14s nobody sees the
        // light reach its final shape a beat before the bar does — and a shadow left
        // to derive itself from layer alpha is what this list's once-a-second reload
        // budget cannot afford.
        let h = heightC.constant
        CATransaction.begin(); CATransaction.setDisableActions(true)
        bar.layer?.shadowPath = CGPath(roundedRect: CGRect(x: 0, y: 0, width: baseW, height: h),
                                       cornerWidth: barRadius, cornerHeight: barRadius,
                                       transform: nil)
        bar.layer?.shadowOffset = .zero
        CATransaction.commit()
        bar.layer?.shadowRadius = on ? 5 : 0
        bar.layer?.shadowOpacity = on ? 0.95 : 0
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.14
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                ctx.allowsImplicitAnimation = true
                self.layoutSubtreeIfNeeded()
            }
        } else {
            layoutSubtreeIfNeeded()
        }
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
}

// A folder header's leading badge: a gradient monogram tile naming the source app
// — blue "VS" for VSCode terminal groups, copper Claude asterisk for the desktop
// app (design/main-window-tabs.html `.applogo`). Status reads from the header's
// wash band + count pill, not from the badge. It doubles as the drag handle
// (grab it to reorder the group).
final class LogoBadge: NSView {
    // A project header shows the source app (VSCode monogram / desktop asterisk) or,
    // when the user has picked one, a custom emoji or uploaded image; a status-bucket
    // header shows a plain tile in the bucket's accent color instead. `.image` carries
    // the icon's *file name*, not an NSImage: Mode is Equatable so configure can skip
    // redundant redraws, and NSImage would break that (and retain a bitmap per mode).
    enum Mode: Equatable {
        case vscode, cursor, windsurf, terminal, desktop, status(String)
        case custom(String)   // emoji
        case image(String)    // file name under AppSettings.iconsDir
    }

    private let gradient = CAGradientLayer()
    private let monogram = NSTextField(labelWithString: "")
    private let icon = NSImageView()
    private let emoji = NSTextField(labelWithString: "")
    private let photo = NSImageView()
    private var mode: Mode?

    // The pure-emoji tile carries no accent color (option A) — just a faint neutral
    // wash so the glyph stays anchored in the badge slot next to VS/asterisk badges.
    private static let neutralTile = [NSColor(white: 0.5, alpha: 0.20),
                                      NSColor(white: 0.5, alpha: 0.20)]

    private static let side: CGFloat = 26

    private static let vscColors = [NSColor(srgbRed: 0.18, green: 0.64, blue: 0.91, alpha: 1),
                                    NSColor(srgbRed: 0.09, green: 0.41, blue: 0.72, alpha: 1)]
    // Cursor (VSCode fork): violet — deliberately off VS blue, the status palette, and
    // desktop copper / terminal graphite, so all five source badges read distinctly.
    private static let cursorColors = [NSColor(srgbRed: 0.604, green: 0.525, blue: 0.961, alpha: 1),
                                       NSColor(srgbRed: 0.357, green: 0.247, blue: 0.839, alpha: 1)]
    // Windsurf (VSCode fork): teal pushed cyan-ward, keeping the brand's water feel while
    // staying clear of the "done" green and VS blue.
    private static let windsurfColors = [NSColor(srgbRed: 0.169, green: 0.792, blue: 0.761, alpha: 1),
                                         NSColor(srgbRed: 0.055, green: 0.545, blue: 0.620, alpha: 1)]
    private static let claudeColors = [NSColor(srgbRed: 0.91, green: 0.54, blue: 0.36, alpha: 1),
                                       NSColor(srgbRed: 0.79, green: 0.42, blue: 0.24, alpha: 1)]
    // Native-terminal group (Terminal.app / iTerm): graphite/slate — deliberately
    // distinct from VS blue and desktop copper, and off the status palette (green/red/
    // blue) so it never reads as a state color.
    private static let termColors = [NSColor(srgbRed: 0.40, green: 0.44, blue: 0.49, alpha: 1),
                                     NSColor(srgbRed: 0.22, green: 0.25, blue: 0.29, alpha: 1)]

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        gradient.cornerRadius = 7
        gradient.cornerCurve = .continuous
        // ~140° diagonal (CSS): light top-left → deep bottom-right, in y-up space.
        gradient.startPoint = CGPoint(x: 0.1, y: 0.95)
        gradient.endPoint = CGPoint(x: 0.9, y: 0.05)
        layer?.addSublayer(gradient)

        monogram.stringValue = "VS"
        monogram.font = Theme.rounded(10.5, .heavy)
        monogram.textColor = .white
        monogram.translatesAutoresizingMaskIntoConstraints = false
        addSubview(monogram)

        let cfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .bold)
        icon.image = NSImage(systemSymbolName: "asterisk", accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
        icon.contentTintColor = .white
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)

        emoji.font = .systemFont(ofSize: 15)
        emoji.alignment = .center
        emoji.isHidden = true
        emoji.translatesAutoresizingMaskIntoConstraints = false
        addSubview(emoji)

        // An uploaded icon fills the whole tile (aspect-fill, rounded-clipped) so it
        // reads like an app icon next to the VS/asterisk badges rather than a small
        // picture floating on a wash.
        photo.imageScaling = .scaleAxesIndependently
        photo.isHidden = true
        photo.wantsLayer = true
        photo.layer?.cornerRadius = 7
        photo.layer?.cornerCurve = .continuous
        photo.layer?.masksToBounds = true
        photo.translatesAutoresizingMaskIntoConstraints = false
        addSubview(photo)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.side),
            heightAnchor.constraint(equalToConstant: Self.side),
            monogram.centerXAnchor.constraint(equalTo: centerXAnchor),
            monogram.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            emoji.centerXAnchor.constraint(equalTo: centerXAnchor),
            emoji.centerYAnchor.constraint(equalTo: centerYAnchor),
            photo.leadingAnchor.constraint(equalTo: leadingAnchor),
            photo.trailingAnchor.constraint(equalTo: trailingAnchor),
            photo.topAnchor.constraint(equalTo: topAnchor),
            photo.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        gradient.frame = bounds
        CATransaction.commit()
    }

    // What a badge is made of: the tile gradient plus the one glyph that rides on it
    // (monogram / SF Symbol / emoji — never more than one). Split out of configure so
    // renderers that aren't this view — the focus-ring caption draws the same badge in
    // a CALayer — share the recipe instead of copying the palette.
    struct Recipe {
        let colors: [NSColor]
        var monogram: String?
        var symbol: String?
        var emoji: String?
        // An uploaded icon: unlike the other three this doesn't ride ON the tile, it
        // replaces it (drawn edge to edge, rounded-clipped). `colors` is then just the
        // fallback showing through if the file went missing.
        var image: NSImage?
    }

    // The badge mode a stored custom icon renders as. One mapping for every reader
    // (header cell, toast banner) so a new icon kind lands everywhere at once.
    static func mode(for icon: AppSettings.CustomIcon) -> Mode {
        switch icon {
        case .emoji(let e): return .custom(e)
        case .image(let f): return .image(f)
        }
    }

    static func recipe(_ mode: Mode) -> Recipe {
        switch mode {
        case .vscode:   return Recipe(colors: vscColors, monogram: "VS")
        case .cursor:   return Recipe(colors: cursorColors, monogram: "CU")
        case .windsurf: return Recipe(colors: windsurfColors, monogram: "WS")
        case .terminal: return Recipe(colors: termColors, symbol: "terminal")
        case .desktop:  return Recipe(colors: claudeColors, symbol: "asterisk")
        case .status(let s):
            let a = Status.accent(s)
            return Recipe(colors: [a.blended(withFraction: 0.18, of: .white) ?? a,
                                   a.blended(withFraction: 0.22, of: .black) ?? a])
        case .custom(let e): return Recipe(colors: neutralTile, emoji: e)
        case .image(let f): return Recipe(colors: neutralTile, image: AppSettings.iconImage(f))
        }
    }

    func configure(_ newMode: Mode) {
        guard newMode != mode else { return }
        mode = newMode
        let r = Self.recipe(newMode)
        monogram.isHidden = r.monogram == nil
        icon.isHidden = r.symbol == nil
        emoji.isHidden = r.emoji == nil
        photo.isHidden = r.image == nil
        if let m = r.monogram { monogram.stringValue = m }
        if let s = r.symbol { setIcon(s) }
        if let e = r.emoji { emoji.stringValue = e }
        if let i = r.image { photo.image = i }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        gradient.colors = r.colors.map(\.cgColor)
        CATransaction.commit()
    }

    // Swap the badge's SF Symbol (asterisk for desktop, terminal for a native-terminal
    // group), reusing one weight/size config. Cached last symbol to skip redundant work.
    private static let iconConfig = NSImage.SymbolConfiguration(pointSize: 12, weight: .bold)
    private var iconSymbol = "asterisk"
    private func setIcon(_ symbol: String) {
        guard symbol != iconSymbol else { return }
        iconSymbol = symbol
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(Self.iconConfig)
    }

    // The badge is the group's drag grip in the session list; where it's only an icon
    // (a recent-projects row) the grab cursor would promise a drag that isn't there.
    var showsGripCursor = true
    override func resetCursorRects() {
        if showsGripCursor { addCursorRect(bounds, cursor: .openHand) }
    }
}

// A cell that exposes its leading drag grip so the table can tell a grip-grab
// (start a drag) from a body click (jump / collapse).
protocol HandleProviding: AnyObject {
    var dragHandle: NSView { get }
}

// A row cell whose hover highlight is driven externally by the table, not by its
// own tracking area. See ReorderTableView's list-level hover management for why
// per-cell tracking was abandoned (synthesized-enter waterfalls + dropped exits
// during this list's frequent reloads).
protocol Hoverable: AnyObject {
    // The table drives which lift each cell wears: .card for a hovered child row or a
    // collapsed solo header, .group for every slice of an expanded header's group, .none
    // at rest. For .group, `groupCenter` is the whole group's center in the CELL's
    // coordinate space — the shared anchor every slice scales about so the group grows
    // as one card (方案 H1) — and `groupRole` is where this row sits within the LIFTED
    // group, which an agent cluster needs because it lifts out of the middle of its
    // project card. Both nil for the other lifts. See ReorderTableView.reconcile.
    func setHovered(_ lift: HoverLift, groupCenter: NSPoint?, groupRole: SliceRole?, animated: Bool)

    // The selection halo, driven on its own channel because selection outlives a
    // hover: the row whose terminal is focused (or that arrow keys landed on) stays
    // lit while the pointer wanders over its neighbours. Folding it into the lift is
    // what made pointing at the list steal the selected row's highlight.
    func setSelected(_ on: Bool, animated: Bool)
}

// Lets the table drive the "collapse every folder while a header drags" behavior
// through its owner (SessionListView), which is the one that holds the model + items.
protocol ReorderCoordinator: AnyObject {
    func rowIsHeader(_ row: Int) -> Bool
    // The row indices of the group owning `headerRow`: the header itself plus its child
    // rows down to (not including) the next header. One element = a collapsed/childless
    // header. Drives the whole-group hover lift (方案 H1).
    func groupRows(headerRow: Int) -> [Int]
    // A session row plus its expanded agent nodes — the rows that lift together when
    // that row is hovered (方案 16). Empty for anything else.
    func agentClusterRows(childRow: Int) -> [Int]
    // Collapse all folders, reload, and return the dragged header's new row index.
    func beginHeaderDrag(originalRow: Int) -> Int?
    // Restore the pre-drag collapse state and reload.
    func endHeaderDrag()
}

// NSTableView that begins a row drag only when the mouse-down lands on a row's
// grip. A grip-grab opens a manual dragging session and swallows the click so the
// grip never jumps/collapses; anything else falls through to normal click handling.
final class ReorderTableView: NSTableView {

    weak var coordinator: ReorderCoordinator?
    private var draggingHeader = false

    // ── List-level hover (replaces flaky per-cell .inVisibleRect tracking) ──
    // One tracking area on the table drives a single hovered row; cells no longer
    // track individually. Per-cell areas mis-fire during this list's frequent
    // reloads — AppKit synthesizes a burst of mouseEntered along the pointer's path
    // on every relayout (the "headers light up top-to-bottom" waterfall) and drops
    // the matching exit (the "hover sticks after the mouse leaves" bug). A single
    // area + hit-test has exactly one source of truth, so neither can happen.
    private var hoverInstalled = false
    private var hoveredRow = -1
    // ── External "pin" highlight (terminal-focus → list sync) ──
    // A row highlighted because its terminal was focused, not because the pointer is
    // over it. Held by index but re-derived by the owner (SessionListView) after every
    // reload from a stable shellPid, so it survives row shifts. A real pointer hover
    // temporarily wins; when the pointer leaves, the pin lights back up. renderedRows are
    // whichever rows are currently lit (one for a child/solo-header card lift, the whole
    // group for an expanded-header lift), so reconcile() can diff without double-toggling.
    private var pinnedRow = -1
    private var renderedRows: [Int] = []
    private var renderedLift: HoverLift = .none
    // While true, the pin wins over a stationary hover (keyboard navigation: the
    // arrow-selected row must stay lit even if the pointer happens to rest over
    // another row). The first real pointer motion hands control back to hover.
    private var pinBeatsHover = false
    // Fired on genuine pointer motion (not reload-driven hover re-sync) so the owner
    // can exit keyboard-nav mode when the user reaches for the mouse.
    var onPointerMoved: (() -> Void)?

    // Right-click a row → the owner builds a context menu for that row index
    // (nil = no menu). Used for "隐藏此项目" on folder headers.
    var contextMenuProvider: ((Int) -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let p = convert(event.locationInWindow, from: nil)
        let row = self.row(at: p)
        guard row >= 0 else { return nil }
        return contextMenuProvider?(row)
    }

    // Jump on the FIRST click even when the window isn't key. By default AppKit
    // swallows the click that activates an inactive window, so reaching this list
    // from another app cost two clicks (one to focus SpectiX, one to actually
    // jump) — the whole point of the list is to be a one-click launchpad, and
    // SpectiX is a menu-bar app so its window is inactive most of the time.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // Window coordinates of the most recent mouseDown — see the capture site below.
    private(set) var lastClickInWindow: NSPoint = .zero

    override func mouseDown(with event: NSEvent) {
        // Remember WHERE this click landed. The action handler (rowClicked) needs the
        // point to hit-test the in-row controls (🤖 badge, header chevron) because the
        // cells claim every click for themselves — and it cannot ask NSApp.currentEvent
        // for it: on the first click into an inactive window (the menu-bar app's normal
        // case) the current event at action time is not reliably that mouse event, so
        // the hit test ran against a garbage point and every badge click fell through
        // to "jump". Captured here, it is always the real click.
        lastClickInWindow = event.locationInWindow
        let p = convert(event.locationInWindow, from: nil)
        let row = self.row(at: p)
        // Status mode sorts automatically — a manual reorder would be blown away on
        // the next refresh, so don't let a drag start at all (grip falls through to
        // a normal click).
        if AppSettings.sortMode == .custom,
           row >= 0,
           let cell = view(atColumn: 0, row: row, makeIfNecessary: false) as? HandleProviding {
            let handle = cell.dragHandle
            let ph = handle.convert(event.locationInWindow, from: nil)
            if handle.bounds.contains(ph) {
                beginHandleDrag(row: row, event: event)
                return
            }
        }
        super.mouseDown(with: event)
    }

    private func beginHandleDrag(row: Int, event: NSEvent) {
        guard let cell = view(atColumn: 0, row: row, makeIfNecessary: false) else { return }
        // Snapshot + grab point captured before any collapse so the floating image
        // stays under the cursor where the user grabbed.
        let snapshotImg = snapshot(of: cell)
        let grabRect = rect(ofRow: row)

        // Dragging a header collapses every folder for the duration; the header's row
        // index shifts once the children vanish, so remap it for the drop logic.
        var dragRow = row
        draggingHeader = coordinator?.rowIsHeader(row) ?? false
        if draggingHeader, let remapped = coordinator?.beginHeaderDrag(originalRow: row) {
            dragRow = remapped
        }

        let item = NSPasteboardItem()
        item.setString(String(dragRow), forType: reorderType)
        let dragItem = NSDraggingItem(pasteboardWriter: item)
        dragItem.setDraggingFrame(grabRect, contents: snapshotImg)
        let session = beginDraggingSession(with: [dragItem], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    override func draggingSession(_ session: NSDraggingSession,
                                  sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    // Fires after the drop is accepted (or the drag is cancelled) — restore the
    // folders' pre-drag collapse state.
    override func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint,
                                  operation: NSDragOperation) {
        if draggingHeader {
            draggingHeader = false
            coordinator?.endHeaderDrag()
        }
    }

    private func snapshot(of view: NSView) -> NSImage {
        let img = NSImage(size: view.bounds.size)
        if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            img.addRepresentation(rep)
        }
        return img
    }

    // Install the single hover area exactly once — .inVisibleRect auto-tracks the
    // table's visible rect across reloads/scrolls, so it never needs rebuilding
    // (rebuilding is precisely what synthesizes phantom enter/exit).
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard !hoverInstalled else { return }
        hoverInstalled = true
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hover(at: event) }
    override func mouseMoved(with event: NSEvent)   { hover(at: event) }
    override func mouseExited(with event: NSEvent)  { setHovered(-1) }

    private func hover(at event: NSEvent) {
        // Real pointer motion → mouse takes back over from keyboard navigation.
        if pinBeatsHover { pinBeatsHover = false; onPointerMoved?() }
        setHovered(row(at: convert(event.locationInWindow, from: nil)))
    }

    // Re-derive the hovered row against the live pointer after a reload (rows can
    // change under a stationary mouse). animated:false so a reload never animates a
    // hover change — only real pointer motion does. Call after reloadData once the
    // frames have settled.
    func syncHoverToPointer() {
        guard let win = window else { setHovered(-1, animated: false); return }
        let p = convert(win.mouseLocationOutsideOfEventStream, from: nil)
        setHovered(visibleRect.contains(p) ? row(at: p) : -1, animated: false)
    }

    // Rows were rebuilt; every cell reset its own hover in configure(), so forget
    // the stale index and re-sync to the pointer next runloop (frames settled).
    func hoverDidReload() {
        // Nothing is lit after a reload — forget both the hovered row and what was
        // rendered so the owner re-asserting the pin (by shellPid) relights cleanly.
        renderedRows = []
        renderedLift = .none
        hoveredRow = -1
        // Same for the halo: GroupCard.configure() cleared it on every rebuilt cell, so
        // the table must forget it too or the owner re-asserting the SAME pinned row
        // would diff to "no change" and leave the selected row dark.
        renderedSelection = []
        // Re-assert the hovered row in THIS runloop, before the post-reload frame draws.
        // Deferring to the next runloop (the old async) left one frame where every cell
        // had reset its own hover to .none but the table hadn't re-lit yet — a visible
        // flash of the lift each reload (the hover jitter while another session writes
        // state). Force the just-invalidated rows to rebuild now so applyHover finds real
        // cell views instead of the lazily-created ones the async was waiting on.
        layoutSubtreeIfNeeded()
        syncHoverToPointer()
    }

    private func setHovered(_ row: Int, animated: Bool = true) {
        guard row != hoveredRow else { return }
        hoveredRow = row
        reconcile(animated: animated)
    }

    // Set (or clear with -1) the terminal-focus pin. The owner re-derives this from a
    // stable shellPid after each reload, so it stays on the right session across rows
    // shifting under a collapse/reorder/refresh.
    // Not guarded on row != pinnedRow: after a reload every cell reset its own hover
    // (renderedRow is forced to -1), so re-pinning the SAME index must still relight it.
    // reconcile()'s own diff absorbs genuinely redundant calls.
    //
    // But that relight must SNAP, exactly like syncHoverToPointer's: the owner calls this
    // after every reload, and a reload happens whenever a rendered figure changes — the ⏱
    // column ticks by the second on a young session. The pinned row is the terminal you're
    // working in, so with the pointer away from the list (the normal case) hoverDidReload's
    // sync early-returns on the already-cleared hover index and lights nothing, leaving
    // this call to do the relight. Animating it replayed the card-lift entrance — a
    // drop-and-rise pulse of the row's outline and rail on every refresh tick. Only a
    // genuine pin MOVE (terminal switch, arrow-key nav) earns the animation.
    func setPinnedRow(_ row: Int, beatsHover: Bool = false) {
        let moved = row != pinnedRow
        pinnedRow = row
        pinBeatsHover = beatsHover
        reconcile(animated: moved)
        reconcileSelection(animated: moved)
    }

    // ── Selection halo ──
    // Which rows currently wear it. Its own diff, deliberately not merged into
    // reconcile()'s: the lit rows and the selected rows are different sets most of the
    // time (the pointer is over one row while the focused terminal's row is another),
    // and merging them is exactly the coupling this feature exists to undo.
    private var renderedSelection: [Int] = []

    private func reconcileSelection(animated: Bool) {
        let rows = pinnedRow >= 0 ? targetRows(pinnedRow).0 : []
        guard rows != renderedSelection else { return }
        for r in renderedSelection where !rows.contains(r) { applySelection(row: r, on: false, animated: animated) }
        for r in rows { applySelection(row: r, on: true, animated: animated) }
        renderedSelection = rows
    }

    private func applySelection(row: Int, on: Bool, animated: Bool) {
        guard row >= 0 else { return }
        // Lifted OR selected raises the row — see raise(row:above:).
        raise(row: row, above: on || renderedRows.contains(row))
        (view(atColumn: 0, row: row, makeIfNecessary: false) as? Hoverable)?
            .setSelected(on, animated: animated)
    }

    // A row must sit above its neighbours whenever it paints outside its own bounds — a
    // lift's shadow, a selection halo, or both. Each channel ORs in the other's current
    // state rather than owning the flag alone: whichever reconciles second would
    // otherwise stamp the row back down and clip the light the first one just lit.
    private func raise(row: Int, above: Bool) {
        rowView(atRow: row, makeIfNecessary: false)?.layer?.zPosition = above ? 1 : 0
    }

    // Light the hovered target: normally the pointer-hovered row (else the pin), but
    // during keyboard navigation (pinBeatsHover) the pin wins over a stationary hover so
    // the arrow-selected row stays lit. A hovered CHILD (or collapsed solo header) floats
    // as a single card (方案 C); a hovered EXPANDED header floats its whole group together
    // (方案 H1). Diffs against renderedRows so only changed rows toggle (no waterfall).
    private func reconcile(animated: Bool) {
        let (rows, lift) = desiredLift()
        guard rows != renderedRows || lift != renderedLift else { return }
        // The group's union rect (table coords) — its center is the shared anchor every
        // slice scales about, so the whole group lifts as one card (方案 H1).
        var groupCenter: NSPoint?
        if lift == .group, let first = rows.first {
            let union = rows.dropFirst().reduce(rect(ofRow: first)) { $0.union(rect(ofRow: $1)) }
            groupCenter = NSPoint(x: union.midX, y: union.midY)
        }
        for r in renderedRows where !rows.contains(r) {
            applyHover(row: r, lift: .none, groupCenter: nil, groupRole: nil, animated: animated)
        }
        for (i, r) in rows.enumerated() {
            applyHover(row: r, lift: lift, groupCenter: groupCenter,
                       groupRole: lift == .group ? Self.groupRole(at: i, of: rows.count) : nil,
                       animated: animated)
        }
        renderedRows = rows
        renderedLift = lift
    }

    // The rows to light and how. Empty when nothing is targeted.
    private func desiredLift() -> ([Int], HoverLift) {
        let base = (pinBeatsHover && pinnedRow >= 0) ? pinnedRow
                 : (hoveredRow >= 0 ? hoveredRow : pinnedRow)
        guard base >= 0 else { return ([], .none) }
        return targetRows(base)
    }

    // Which rows a target covers, and how they'd lift. Shared by the hover lift and the
    // selection halo so a selected header haloes its whole group exactly as hovering it
    // lifts the whole group — one definition of "what this row stands for".
    private func targetRows(_ base: Int) -> ([Int], HoverLift) {
        // A header target lifts its whole group with the H1 treatment — a collapsed
        // solo header IS its whole group (one box), so it takes the same lift instead
        // of the child row's card float (mirrors the mock, where solo hover = liftAll).
        if coordinator?.rowIsHeader(base) == true {
            return (coordinator?.groupRows(headerRow: base) ?? [base], .group)
        }
        // An expanded session row and its agent sublist are one card's two segments
        // (方案 16), so pointing at the row lifts both: floating the row alone would
        // tear it off the segment that is drawn as part of it, leaving the sublist
        // sunk in the enclosure while its own header hovers above it.
        if let cluster = coordinator?.agentClusterRows(childRow: base), !cluster.isEmpty {
            return (cluster, .group)
        }
        return ([base], .card)
    }

    // Where the i-th row of a lifted group sits within it. For a header's group this
    // restates the enclosure's own roles (header .top, last child .bottom); for an
    // agent cluster it is the whole point — those rows are .middle slices of the
    // project card, but the lift's shadow belongs on the CLUSTER's edges.
    private static func groupRole(at i: Int, of n: Int) -> SliceRole {
        n <= 1 ? .solo : (i == 0 ? .top : (i == n - 1 ? .bottom : .middle))
    }

    private func applyHover(row: Int, lift: HoverLift, groupCenter: NSPoint?,
                            groupRole: SliceRole?, animated: Bool) {
        guard row >= 0 else { return }
        // Raise the whole row above its neighbours so the lift's shadow (and any scale
        // overflow) isn't clipped by the adjacent rows painted on top of it.
        raise(row: row, above: lift != .none || renderedSelection.contains(row))
        guard let cellView = view(atColumn: 0, row: row, makeIfNecessary: false),
              let cell = cellView as? Hoverable else { return }
        cell.setHovered(lift,
                        groupCenter: groupCenter.map { cellView.convert($0, from: self) },
                        groupRole: groupRole,
                        animated: animated)
    }
}

// The main window's four panes, in bottom-tab order (⌘1–⌘4).
enum MainTab: Int, CaseIterable {
    case sessions, stats, recent, skills, settings
}

// MARK: - App logo mark (wordmark companion)

// Miniature of the app icon beside the wordmark — draws the real AppIcon so it
// always matches the Dock/Finder/System-Settings icon (tools/AppIcon.png).
final class AppLogoMark: NSView {
    override var intrinsicContentSize: NSSize { NSSize(width: 34, height: 34) }

    // Draw the real app icon (AppIcon.icns, sourced from tools/AppIcon.png) so the
    // header mark stays in sync with the Dock/Finder icon.
    override func draw(_ dirtyRect: NSRect) {
        NSApp.applicationIconImage?.draw(in: bounds, from: .zero,
                                         operation: .sourceOver, fraction: 1,
                                         respectFlipped: true,
                                         hints: [.interpolation: NSImageInterpolation.high])
    }
}

// The yellow button must put the window away INTO the app icon, not spawn a second
// Dock tile beside it. A real miniaturize parks the window in the Dock's right
// section, so SpectiX would show up twice (app icon + minimized window) for its
// one and only window. Hiding it is what "minimize into application icon" means
// here — the Dock icon and the menu-bar item both bring it straight back. Overriding
// the window (not just retargeting the button) covers every path: the traffic-light
// button, ⌘M, and any menu item, which all funnel through these two.
final class HideOnMinimizeWindow: NSWindow {
    var onMinimize: (() -> Void)?
    /// Runs after every window layout pass. The traffic lights are laid out by AppKit
    /// (not by our constraints), so nudging them once at setup would be undone the
    /// next time AppKit rebuilds the titlebar — re-apply from here instead.
    /// ⚠️ This is why it is not a `windowDidResize` delegate: that path crashed this
    /// window (see the note in the NSWindowDelegate extension below).
    var onLayout: (() -> Void)?
    override func miniaturize(_ sender: Any?) { onMinimize?() }
    override func performMiniaturize(_ sender: Any?) { onMinimize?() }
    override func layoutIfNeeded() {
        super.layoutIfNeeded()
        onLayout?()
    }
}

final class MainWindowController: NSWindowController {

    private let model: ListModel
    var onJump: ((SessionRow) -> Void)?
    var onOpenProject: ((String) -> Void)?   // a 最近项目 row was clicked
    var onRebindHotKey: ((HotKeyAction, HotKeyCombo?) -> OSStatus)?   // Settings rebound a hotkey

    private lazy var listView = SessionListView(model: model)
    private let hiddenBar = HiddenBar()   // 已隐藏 discoverability + undo, below the list
    private let tipBar = TipBar()         // one-time feature tips, between the list and hiddenBar
    private lazy var tips = TipCenter(bar: tipBar)
    private let logoMark = AppLogoMark()
    private let titleLabel = NSTextField(labelWithString: "SpectiX")
    /// The running build's version, riding the wordmark's baseline. It used to live
    /// only in 设置 → 关于, which meant a rebuilt dev app looked identical to the one
    /// it replaced — you had to dig two panes deep to tell which binary was on screen.
    private let versionLabel = NSTextField(labelWithString: "v" + AboutCard.version)
    /// Status-bucket counts, at the right end of the title row. The popover keeps
    /// its own inside HeaderStatsView (its identity row lives in the header); here
    /// the window's own title row plays that part, so the pill belongs to the
    /// window and the shared header is purely the 2×2 metric grid.
    private let countPill = CountPill()
    private let breakChip = BreakChip()   // "🍅 48:12", left of the counts (BreakReminder)
    // The 2×2 metric grid (CPU / memory over session / weekly quota), identical to
    // the popover's.
    private let statsHeader = HeaderStatsView()
    private let tabBar = BottomTabBar()
    private let recentPane = RecentProjectsPane()   // tab 3
    private let statsPane = StatsPane()             // tab 2
    private let skillsPane = SkillsPane()           // tab 4
    private let settingsPane = SettingsPane()       // tab 5
    private var panes: [NSView] = []      // indexed by MainTab.rawValue
    private(set) var currentTab: MainTab = .sessions
    // Put-away state (改 putAway/showWindow 前必读). The window is PARKED at alpha 0
    // rather than ordered out, because orderOut drops a window's Space binding: the
    // next orderFront re-seats it on whatever Space happens to be current, which is
    // why a window put away on 桌面2 used to come back on 桌面1. Left ordered-in, it
    // stays bound to its Space, and makeKeyAndOrderFront switches back to that Space
    // to reach it — the window returns exactly where it was left, position and all.
    // (FocusRing's overlays park by alpha for the same reason — see its comments.)
    private(set) var isParked = false
    private var openCwds: Set<String> = []          // live project dirs, for 已打开 badges
    private var latestUsage: UsageSnapshot?         // freshest quota snapshot, for the stats tab

    // Content-fit window height: the sessions tab shrinks to hug its rows (a lone
    // session no longer leaves a tall empty gutter). Other tabs never shrink below a
    // comfortable browsing height (so switching in from a shrunk sessions tab doesn't
    // land on a cramped pane), and never fight a height the user dragged taller.
    private var maxWindowContentH: CGFloat { min((NSScreen.main?.visibleFrame.height ?? 900) - 40, 760) }
    private let sessionsMinContentH: CGFloat = 180   // floor so the empty-state label still breathes
    private let comfortableContentH: CGFloat = 520   // non-sessions tabs open at least this tall

    init(model: ListModel) {
        self.model = model
        let window = HideOnMinimizeWindow(
            contentRect: NSRect(x: 0, y: 0, width: 476, height: 847),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "SpectiX"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        // Transparent window backing: the window's own background is a square
        // rect, so an opaque white here leaks past the rounded top corners of
        // the base/glass layers. The rounded `base` view below supplies the
        // solid white fill instead (no desktop showing through the content).
        window.isOpaque = false
        window.backgroundColor = .clear
        // Shared with the popover's drag floor — see Theme.minPanelWidth for why the
        // header's metric grid sets the number.
        window.minSize = NSSize(width: Theme.minPanelWidth, height: 360)
        // Restore the last position/size ourselves (setFrameAutosaveName no-ops on this
        // window — see AppSettings.mainWindowFrame). A saved frame owns the whole frame;
        // fall back to centering on first launch. ensureWindowOnScreen() (in the app
        // controller) recenters if this frame is now off every screen.
        if let saved = AppSettings.mainWindowFrame {
            // Clamp against minSize by hand: it only governs interactive resizing, so
            // setFrame would happily restore a frame saved under an older, smaller
            // floor and leave the window below its own minimum until you dragged it.
            // Note the flip side, and why Theme.minPanelWidth is not to be nudged:
            // raising the floor pushes every saved frame out to it through here, and
            // the user can't drag back to where they had it.
            var f = saved
            f.size.width = max(f.width, window.minSize.width)
            f.size.height = max(f.height, window.minSize.height)
            window.setFrame(f, display: false)
        } else {
            // First launch: open at the default size and keep it. Content-fit
            // (adjustWindowHeight) would otherwise shrink the height on the spot to
            // whatever the session list happens to need — measured 567pt on a machine
            // with a handful of sessions — so the default height above would never be
            // the height anyone actually sees. Claiming the size as user-owned here
            // hands the window its full default and takes height out of content-fit's
            // hands for good, on this launch and every later one.
            // The default is taller than a 13" screen can show, so fit it to the
            // screen first; minSize still sets the floor.
            if let vis = NSScreen.main?.visibleFrame {
                var f = window.frame
                f.size.height = max(window.minSize.height, min(f.height, vis.height))
                window.setFrame(f, display: false)
            }
            window.center()
            AppSettings.mainWindowUserSized = true
        }
        super.init(window: window)
        setupUI()
    }
    required init?(coder: NSCoder) { fatalError() }

    // The red button HIDES the window, it does not quit: SpectiX lives in the menu
    // bar, so putting its one window away is not "I'm done with the app". Returning
    // false keeps the window (and every pane's state) alive for an instant reopen from
    // the menu-bar icon or the Dock. Quitting is the status item's right-click menu.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        putAway()
        return false
    }

    // True while the window is really on screen for the user. A parked window is still
    // `isVisible` (that's the whole point — see `isParked`), so every "is the user
    // looking at it?" check must ask this instead of NSWindow.isVisible.
    var isShown: Bool { window?.isVisible == true && !isParked }

    // Both "put the window away" paths (red button, yellow button) land here: hide it
    // and stop the panes that poll while visible. Everything stays alive for an
    // instant reopen from the menu-bar icon or the Dock.
    private func putAway() {
        settingsPane.paneDidDisappear()   // stop 设置's ring preview / permission poller
        guard let window = window, !isParked else { return }
        isParked = true
        window.alphaValue = 0
        window.ignoresMouseEvents = true   // an invisible window must not swallow clicks
        // Ordering out used to hand the front back on its own; parking keeps a window,
        // so give up the foreground explicitly or the app sits active behind nothing.
        NSApp.deactivate()
    }

    // Every reopen path funnels through NSWindowController.showWindow, so un-park here:
    // makeKeyAndOrderFront below then reaches the window on its own Space, switching
    // the display back to it rather than dragging the window to the current one.
    override func showWindow(_ sender: Any?) {
        if isParked, let window = window {
            isParked = false
            window.alphaValue = 1
            window.ignoresMouseEvents = false
        }
        super.showWindow(sender)
    }

    // Tear the window down for real — the only such path (languageDidChange /
    // themeDidChange rebuild it so every statically-built label and layer is remade).
    // close() bypasses windowShouldClose, so the hide above doesn't intercept it.
    func closeForRebuild() {
        settingsPane.paneDidDisappear()
        close()
    }

    private func setupUI() {
        guard let window = window, let content = window.contentView else { return }
        window.delegate = self   // observe the user dragging the window edge
        (window as? HideOnMinimizeWindow)?.onMinimize = { [weak self] in self?.putAway() }
        (window as? HideOnMinimizeWindow)?.onLayout = { [weak self] in self?.alignTrafficLights() }
        alignTrafficLights()

        // Solid base + a frost layer on top. The base is an opaque fill (no
        // desktop bleeds through; white in light, deep neutral in dark); the glass
        // uses .withinWindow blending so its HUD material frosts the base itself —
        // a milky frosted panel rather than a see-through blur of the desktop.
        let base = OpaquePane(radius: Theme.windowRadius)
        base.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(base)
        NSLayoutConstraint.activate([
            base.topAnchor.constraint(equalTo: content.topAnchor),
            base.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            base.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            base.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        ])

        // radius matches the macOS titled-window corner so the frosted material's
        // rounded edge sits exactly on the window's rounded corner (no white leak).
        let glass = Theme.surfacePane(material: .hudWindow, radius: Theme.windowRadius)
        glass.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(glass)
        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: content.topAnchor),
            glass.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        ])

        // ── Header row 1: wordmark only. The old recent/stats/settings pill and
        // refresh button are gone — tabs live in the bottom bar; refresh is automatic.
        logoMark.translatesAutoresizingMaskIntoConstraints = false
        glass.addSubview(logoMark)

        titleLabel.font = Theme.rounded(22, .bold)
        titleLabel.textColor = .labelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        glass.addSubview(titleLabel)

        versionLabel.font = Theme.roundedMono(11.5, .semibold)
        versionLabel.textColor = .tertiaryLabelColor
        versionLabel.translatesAutoresizingMaskIntoConstraints = false
        glass.addSubview(versionLabel)
        glass.addSubview(countPill)
        glass.addSubview(breakChip)
        // The chip rides in the title row; the strip it opens lives in the shared header.
        breakChip.onClick = { [weak self] in self?.statsHeader.breakPanel.toggle() }
        statsHeader.onLayoutChange = { [weak self] in self?.adjustWindowHeight() }

        // ── Bottom tab bar (in-flow, scheme 6) ──
        tabBar.onSelect = { [weak self] i in
            guard let tab = MainTab(rawValue: i) else { return }
            self?.showTab(tab)
        }
        glass.addSubview(tabBar)

        // ── Pane container: one pane per tab, hide/show swapped ──
        let paneContainer = NSView()
        paneContainer.translatesAutoresizingMaskIntoConstraints = false
        glass.addSubview(paneContainer)

        // Shared stats header — pinned at the top for EVERY tab (below the wordmark,
        // above the pane container) so switching tabs keeps it in place.
        glass.addSubview(statsHeader)

        // Pane 0 — sessions: the drag-reorderable list (the stats header now lives
        // above the pane container, shared across all tabs).
        let sessionsPane = NSView()
        sessionsPane.translatesAutoresizingMaskIntoConstraints = false
        listView.onJump = { [weak self] row in self?.onJump?(row) }
        listView.translatesAutoresizingMaskIntoConstraints = false
        sessionsPane.addSubview(listView)
        wireHiddenBar()
        wireTips()
        sessionsPane.addSubview(tipBar)
        sessionsPane.addSubview(hiddenBar)
        NSLayoutConstraint.activate([
            listView.leadingAnchor.constraint(equalTo: sessionsPane.leadingAnchor, constant: Theme.pad - Theme.cardCellInset),
            listView.trailingAnchor.constraint(equalTo: sessionsPane.trailingAnchor, constant: -(Theme.pad - Theme.cardCellInset)),
            listView.topAnchor.constraint(equalTo: sessionsPane.topAnchor),
            listView.bottomAnchor.constraint(equalTo: tipBar.topAnchor, constant: -4),

            // Below the list, above the hidden bar: right next to the rows it talks about.
            // It carries its own 4pt bottom gap, so collapsed (height 0) the list lands
            // exactly where it did before this bar existed — no extra seam.
            tipBar.leadingAnchor.constraint(equalTo: sessionsPane.leadingAnchor, constant: Theme.pad),
            tipBar.trailingAnchor.constraint(equalTo: sessionsPane.trailingAnchor, constant: -Theme.pad),
            tipBar.bottomAnchor.constraint(equalTo: hiddenBar.topAnchor),

            hiddenBar.leadingAnchor.constraint(equalTo: sessionsPane.leadingAnchor, constant: Theme.pad),
            hiddenBar.trailingAnchor.constraint(equalTo: sessionsPane.trailingAnchor, constant: -Theme.pad),
            hiddenBar.bottomAnchor.constraint(equalTo: sessionsPane.bottomAnchor, constant: -8),
        ])

        // Pane 1 — 统计; pane 2 — 最近项目; pane 3 — 技能; pane 4 — 设置.
        recentPane.onOpen = { [weak self] path in self?.onOpenProject?(path) }
        // Settings rebinds route through the host; seed each recorder with its saved combo.
        settingsPane.onRebind = { [weak self] action, combo in self?.onRebindHotKey?(action, combo) ?? noErr }
        for action in HotKeyAction.allCases { settingsPane.setCombo(action, HotKeyStore.load(action)) }
        panes = [sessionsPane, statsPane, recentPane, skillsPane, settingsPane]
        for (i, pane) in panes.enumerated() {
            paneContainer.addSubview(pane)
            pane.isHidden = i != MainTab.sessions.rawValue
            NSLayoutConstraint.activate([
                pane.topAnchor.constraint(equalTo: paneContainer.topAnchor),
                pane.bottomAnchor.constraint(equalTo: paneContainer.bottomAnchor),
                pane.leadingAnchor.constraint(equalTo: paneContainer.leadingAnchor),
                pane.trailingAnchor.constraint(equalTo: paneContainer.trailingAnchor),
            ])
        }

        let top = window.contentLayoutGuide as! NSLayoutGuide
        NSLayoutConstraint.activate([
            logoMark.leadingAnchor.constraint(equalTo: glass.leadingAnchor, constant: Theme.pad),
            logoMark.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            logoMark.widthAnchor.constraint(equalToConstant: 34),
            logoMark.heightAnchor.constraint(equalToConstant: 34),

            titleLabel.leadingAnchor.constraint(equalTo: logoMark.trailingAnchor, constant: 8),
            // Tight to the titlebar: the 34pt logo still clears the traffic lights by
            // ~9pt, and every pt saved here goes to the list below.
            titleLabel.topAnchor.constraint(equalTo: top.topAnchor, constant: 6),

            // Baseline-aligned rather than centred: a 11.5pt tag centred on a 22pt
            // wordmark floats in the middle of the caps and reads as a separate row.
            versionLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 6),
            versionLabel.firstBaselineAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor),

            // Counts ride at the far right of the identity row, opposite the logo and
            // wordmark — not down in the stats header, which is now purely the 2×2
            // metric grid. Kept here so the row reads "who I am … what's running".
            countPill.trailingAnchor.constraint(equalTo: glass.trailingAnchor, constant: -Theme.pad),
            countPill.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            countPill.leadingAnchor.constraint(greaterThanOrEqualTo: versionLabel.trailingAnchor, constant: 10),
            breakChip.trailingAnchor.constraint(equalTo: countPill.leadingAnchor, constant: -8),
            breakChip.centerYAnchor.constraint(equalTo: countPill.centerYAnchor),
            breakChip.leadingAnchor.constraint(greaterThanOrEqualTo: versionLabel.trailingAnchor, constant: 10),

            statsHeader.leadingAnchor.constraint(equalTo: glass.leadingAnchor, constant: Theme.pad),
            statsHeader.trailingAnchor.constraint(equalTo: glass.trailingAnchor, constant: -Theme.pad),
            statsHeader.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 10),

            // 8 = the same gap the list puts between projects, so the stats header stacks
            // like one more card (no hairline). It lives HERE, not in the list's first row
            // (which drops its own 8 — HeaderCell.topGap), so it stays put while the
            // rows scroll under the list's top edge.
            paneContainer.topAnchor.constraint(equalTo: statsHeader.bottomAnchor, constant: 8),
            paneContainer.leadingAnchor.constraint(equalTo: glass.leadingAnchor),
            paneContainer.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
            paneContainer.bottomAnchor.constraint(equalTo: tabBar.topAnchor),

            tabBar.leadingAnchor.constraint(equalTo: glass.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
            tabBar.bottomAnchor.constraint(equalTo: glass.bottomAnchor),
        ])
    }

    // AppKit parks the traffic lights ~7pt from the left edge — closer in than
    // anything else in the window, so the close button and the logo below it read as
    // two different left margins. Shift the whole row right until its leading edge is
    // the same Theme.pad the logo, the stats grid and the list all sit on. Vertical
    // placement is left exactly where AppKit put it. Idempotent: once aligned the
    // delta is 0 and the loop is skipped, so the per-layout call costs one compare.
    private func alignTrafficLights() {
        guard let window = window,
              let close = window.standardWindowButton(.closeButton) else { return }
        let dx = Theme.pad - close.frame.minX
        guard abs(dx) > 0.5 else { return }
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let b = window.standardWindowButton(type) else { continue }
            b.setFrameOrigin(NSPoint(x: b.frame.minX + dx, y: b.frame.minY))
        }
    }

    func showTab(_ tab: MainTab) {
        let previous = currentTab
        currentTab = tab
        for (i, pane) in panes.enumerated() { pane.isHidden = i != tab.rawValue }
        tabBar.select(tab.rawValue)
        // Leaving 设置 → stop its ring preview + permission poller (they'd otherwise
        // keep animating/polling behind the visible tab).
        if previous == .settings, tab != .settings { settingsPane.paneDidDisappear() }
        // Refresh the pane we're switching TO so it opens current (matches the old
        // per-window "refresh right before showWindow").
        switch tab {
        case .recent:   recentPane.refresh(openCwds: openCwds)
        case .stats:    statsPane.refresh(usage: latestUsage, force: true)
        case .skills:   skillsPane.paneDidAppear()
        case .settings: settingsPane.paneDidAppear()
        default:        break
        }
        adjustWindowHeight()
    }

    // Resize the window so its height fits the current tab's content, keeping the top
    // edge pinned (only the bottom moves). "chrome" — everything above/below the list
    // (title + stats header + hidden bar + tab bar + gaps) — is derived from live frames
    // rather than hardcoded, so it stays correct as the stats/hidden rows grow or shrink.
    /// The break banner was clicked: land on the sessions tab with the strip open.
    func showBreakPanel() {
        showTab(.sessions)
        statsHeader.breakPanel.setExpanded(true)
        breakChip.refresh()
    }

    private func adjustWindowHeight() {
        // Once the user has dragged the window to a size they like, stop fighting it:
        // their frame (autosaved + restored on relaunch) wins over content-fit.
        if AppSettings.mainWindowUserSized { return }
        guard let window = window, let content = window.contentView, isShown else { return }
        window.layoutIfNeeded()
        let contentH = content.frame.height
        let frameExtra = window.frame.height - contentH   // title bar band outside the content view
        let target: CGFloat
        if currentTab == .sessions {
            let chrome = contentH - listView.frame.height  // fixed parts + hidden bar (varies) + gaps
            let neededList = listView.contentHeight + 8     // scroll insets: 2 top + 6 bottom
            target = min(max(chrome + neededList, sessionsMinContentH), maxWindowContentH)
        } else {
            // Grow to a comfortable height if we arrived here shrunk; never shrink a
            // pane the user has already sized, and never exceed the screen.
            target = min(max(contentH, comfortableContentH), maxWindowContentH)
        }
        guard abs(target - contentH) > 1 else { return }
        let newTotal = target + frameExtra
        var frame = window.frame
        frame.origin.y = frame.maxY - newTotal   // pin the top edge, extend/retract the bottom
        frame.size.height = newTotal
        window.setFrame(frame, display: true, animate: false)
    }

    // Hide → persist + show the undo bar (teaching where to restore on the first
    // time); the bar's 恢复 opens 设置 › 已隐藏, 撤销 puts the project back.
    private func wireHiddenBar() {
        listView.onHide = { [weak self] cwd, folder in
            let first = !AppSettings.hasSeenHideOnboarding
            AppSettings.hasSeenHideOnboarding = true
            AppSettings.hide(cwd: cwd)
            self?.hiddenBar.showUndo(folder: folder, cwd: cwd, onboarding: first)
        }
        hiddenBar.onOpenHidden = { [weak self] in self?.showTab(.settings) }
        hiddenBar.onUndo = { cwd in AppSettings.unhide(cwd: cwd) }
        // Collapsing a folder / reordering changes the row count → re-fit the height.
        listView.onLayoutChange = { [weak self] in self?.adjustWindowHeight() }
    }

    // Feature tips: the bar only speaks while the user is actually looking at the list,
    // and stands down while the undo prompt owns the strip below it. Using an affordance
    // (a jump, a header right-click, an agent expand) retires its tip on the spot.
    private func wireTips() {
        tips.isActive = { [weak self] in
            guard let self, self.isShown, self.currentTab == .sessions,
                  self.window?.isKeyWindow == true else { return false }
            return !self.hiddenBar.isShowingUndo
        }
        listView.onLearned = { [weak self] id in self?.tips.markLearned(id) }
        tipBar.onHeightChange = { [weak self] in self?.adjustWindowHeight() }
    }

    func reload(_ newRows: [SessionRow], usage: UsageSnapshot? = nil,
                header: HeaderAgentInfo? = nil) {
        statsHeader.update(rows: newRows, usage: usage,
                           codexUsage: header?.codexUsage,
                           claudeAccount: header?.claudeAccount,
                           codexAccount: header?.codexAccount,
                           claudeRemembered: header?.claudeRemembered ?? false,
                           codexRemembered: header?.codexRemembered ?? false)
        // The "—" placeholder keeps the pill anchoring the row's right edge when
        // nothing is running, so the title row doesn't change shape on an empty list.
        countPill.configure(rows: newRows, placeholder: "—")
        breakChip.refresh()
        listView.reload(newRows)
        hiddenBar.update(count: AppSettings.hiddenCwds.count)
        // Single evaluation point for feature tips — everything they need is derivable
        // from the rows just rendered. Header-only projects count toward groupCount
        // because they're draggable headers too.
        tips.evaluate(TipContext(
            sessionCount: newRows.count,
            groupCount: Set(newRows.map { $0.cwd }).count + model.emptyProjects.count,
            hasCustomOrder: model.hasCustomOrder,
            hasAgents: newRows.contains { $0.bgAgents > 0 }))
        // Keep the 已打开 badges truthful while the 最近项目 tab is showing.
        openCwds = Set(newRows.map { $0.cwd })
        if currentTab == .recent { recentPane.updateOpenState(openCwds) }
        // Remember the freshest quota snapshot so the stats tab's week-quota bar shows
        // current figures whenever it's opened (or refreshed while already visible).
        if let usage { latestUsage = usage }
        if currentTab == .stats { statsPane.refresh(usage: latestUsage) }
        // Only the sessions tab re-fits on each poll; other tabs are sized once on
        // switch-in (showTab) so a per-poll resize can't fight a user-dragged height.
        if currentTab == .sessions { adjustWindowHeight() }
    }

    // A terminal was focused → sync the list (reveal + highlight its session). No-op
    // unless the window is visible and showing the sessions tab.
    func focusSession(shellPid pid: pid_t) {
        guard isShown, currentTab == .sessions else { return }
        listView.focusSession(shellPid: pid)
    }

}

extension MainWindowController: NSWindowDelegate {
    // The user dragged the window edge (only a live resize fires this — programmatic
    // setFrame never does). Latch it so `adjustWindowHeight` stops snapping the height
    // back to content on every poll; the autosaved frame now owns the size.
    func windowDidEndLiveResize(_ notification: Notification) {
        AppSettings.mainWindowUserSized = true
        persistFrame()
    }

    // Persist position on every move and size on every resize, so the next launch
    // restores the exact frame (setFrameAutosaveName doesn't work on this window).
    // Only track user-driven moves while visible — programmatic setFrame during
    // teardown/restore shouldn't overwrite the saved frame.
    func windowDidMove(_ notification: Notification) {
        persistFrame()
    }

    // ⚠️ Do NOT add windowWillResize/windowDidResize to enforce the minimum width.
    // Both were tried and both crashed the app: this window's frame is partly
    // constraint-driven (`_changeWindowFrameFromConstraintsIfNecessary`), so a
    // delegate that answers with a different size than Auto Layout just asked for
    // sends the two into a loop — AppKit gives up with "marked as needing another
    // Layout Window pass, but it has already had more Layout Window passes than
    // there are views" and aborts. `minSize` already covers the case a delegate
    // would (the user dragging an edge); the two clamps below cover the rest
    // without ever answering back mid-layout.
    private func persistFrame() {
        guard let window = window, isShown else { return }
        // Never store a frame the app would refuse to open at — otherwise one
        // externally-forced resize outlives the session that caused it.
        var f = window.frame
        f.size.width = max(f.width, window.minSize.width)
        f.size.height = max(f.height, window.minSize.height)
        AppSettings.mainWindowFrame = f
    }
}

// MARK: - Header cell (folder group, with aggregate count pill)
//
// One per VSCode window. Folder name on the left, one glass pill of colored counts
// on the right (●2 ●1 ●1) so the whole window's state reads at a glance.
// Click → raise the folder's window.

final class HeaderCell: NSTableCellView, HandleProviding, Hoverable {
    private let card = GroupCard(radius: Theme.group)   // the project enclosure's top / solo slice
    private let logoBadge = LogoBadge()      // gradient source monogram; doubles as the drag grip
    private let disc = DiscButton()          // round collapse toggle (replaces the bare chevron glyph)
    private let folderLabel = NSTextField(labelWithString: "")
    private let countPill = CountPill()      // one glass chip holding every status bucket
    // The 8pt above the card is the ONLY separation between projects. The FIRST
    // group drops it (0): the host puts the same 8 outside the scroll view, between
    // the stats header and the list, so that gap stays put while the rows scroll
    // under it. Keeping the first row's own 8 as well would double it at rest.
    private var topGap: NSLayoutConstraint!

    var dragHandle: NSView { logoBadge }

    // The badge view — used as the popover anchor when editing the project icon.
    var iconAnchor: NSView { logoBadge }

    // True if `windowPoint` lands on the disclosure disc's (padded) hit area — the
    // disc is a comfortable 25pt already, so only a small margin is added.
    func chevronHit(_ windowPoint: NSPoint) -> Bool {
        guard !disc.isHidden else { return false }   // empty group: no disc, so no toggle zone
        let p = disc.convert(windowPoint, from: nil)
        return disc.bounds.insetBy(dx: -6, dy: -8).contains(p)
    }

    // True if `windowPoint` lands on the leading badge (padded) — a right-click there
    // opens the "编辑图标" menu instead of the whole-project hide menu.
    func badgeHit(_ windowPoint: NSPoint) -> Bool {
        let p = logoBadge.convert(windowPoint, from: nil)
        return logoBadge.bounds.insetBy(dx: -5, dy: -5).contains(p)
    }

    init(id: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        identifier = id
        letShadowsEscape()   // a clipped shadow ends in a straight line — see letShadowsEscape

        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)
        topGap = card.topAnchor.constraint(equalTo: topAnchor, constant: 8)

        // Leading logo badge: the source app icon inside a status ring. Grab it to
        // drag the whole folder group up/down.
        card.addSubview(logoBadge)

        // Disclosure disc: a round chevron button parked on the far right — ▸
        // collapsed, ▾ expanded. Toggling is routed through chevronHit (below).
        card.addSubview(disc)

        folderLabel.font = Theme.rounded(14.5, Theme.groupTitleWeight)
        folderLabel.textColor = .labelColor
        folderLabel.lineBreakMode = .byTruncatingTail
        folderLabel.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(folderLabel)

        card.addSubview(countPill)

        NSLayoutConstraint.activate([
            // Same horizontal inset as ChildCell (6 / -6) so the per-slice side
            // borders line up into one continuous edge. The 8pt top gap is the ONLY
            // separation between projects; the bottom is flush with the first child.
            card.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.cardCellInset),
            card.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.cardCellInset),
            topGap,
            card.bottomAnchor.constraint(equalTo: bottomAnchor, constant: 0),

            logoBadge.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 11),
            logoBadge.centerYAnchor.constraint(equalTo: card.centerYAnchor),

            folderLabel.leadingAnchor.constraint(equalTo: logoBadge.trailingAnchor, constant: 10),
            folderLabel.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            folderLabel.trailingAnchor.constraint(lessThanOrEqualTo: countPill.leadingAnchor, constant: -8),

            countPill.trailingAnchor.constraint(equalTo: disc.leadingAnchor, constant: -9),
            countPill.centerYAnchor.constraint(equalTo: card.centerYAnchor),

            disc.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -10),
            disc.centerYAnchor.constraint(equalTo: card.centerYAnchor),
        ])

        card.setHover(.none, animated: false)
    }
    required init?(coder: NSCoder) { fatalError() }

    // Hover is driven by the table (see ReorderTableView), not a per-cell tracking
    // area — one hovered row, hit-tested, no synthesized-enter waterfall.
    func setHovered(_ lift: HoverLift, groupCenter: NSPoint?, groupRole: SliceRole?, animated: Bool) {
        card.setHover(lift,
                      groupCenter: groupCenter.map { card.convert($0, from: self) },
                      groupRole: groupRole,
                      animated: animated)
    }

    func setSelected(_ on: Bool, animated: Bool) { card.setSelected(on, animated: animated) }

    // First-click jump from an inactive window — see ChildCell's note. Chevron /
    // badge hit-testing is done in window coordinates by the table, so collapsing
    // and the icon menu keep working with the whole card claiming the click.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    func configure(folder: String, counts: [(String, Int)], collapsed: Bool,
                   kind: HeaderKind, source: HeaderSource, pinned: Bool = false,
                   isFirst: Bool = false) {
        // Set on every configure — cells are recycled, so the first group's cell may
        // have last served a lower row (and vice versa).
        topGap.constant = isFirst ? 0 : 8
        // A pinned project floats to the top; mark its header with a leading 📌 so the
        // reason it's parked up here is obvious. Zero extra layout — rides the label.
        folderLabel.stringValue = pinned ? "📌 " + folder : folder
        // A project whose VSCode window is open but holds no session arrives as a single
        // zero bucket (ListModel.projectItems) — the only way counts carries a 0, since
        // ListModel.counts() drops empty buckets. It renders exactly like any other header
        // (full opacity, normal badge/label); it just drops the collapse disc (no children
        // to reveal) and hides the count pill (a "●0" chip reads as noise). Reset alpha to
        // 1 unconditionally — cells are reused and may carry a prior dimmed state.
        let isEmptyProject = counts.count == 1 && counts[0].1 == 0
        disc.isHidden = isEmptyProject
        folderLabel.alphaValue = 1
        logoBadge.alphaValue = 1
        countPill.alphaValue = 1
        disc.configure(collapsed: collapsed)
        // Collapsed → the header is the whole box (solo); expanded → it's the top
        // slice with children flush beneath. isHeaderBand paints the status wash +
        // the under-header hairline (the latter only when there are rows below).
        let accent = counts.first?.0 ?? "idle"
        card.configure(role: collapsed ? .solo : .top, isHeaderBand: true, topDivider: false)
        card.setAccent(accent)
        switch kind {
        case .project(let cwd):
            // A user-picked icon (emoji or uploaded image) overrides the default source
            // badge (VS / terminal / asterisk); otherwise the badge follows the group's
            // derived source.
            if let ic = AppSettings.customIcon(cwd: cwd) { logoBadge.configure(LogoBadge.mode(for: ic)) }
            else {
                switch source {
                case .vscode:   logoBadge.configure(.vscode)
                case .cursor:   logoBadge.configure(.cursor)
                case .windsurf: logoBadge.configure(.windsurf)
                case .terminal: logoBadge.configure(.terminal)
                case .desktop:  logoBadge.configure(.desktop)
                }
            }
        case .status(let s):    logoBadge.configure(.status(s))
        }
        countPill.configure(counts: counts)
        countPill.isHidden = counts.isEmpty || isEmptyProject
        // Reset hover on (re)configure; the table re-syncs the real hovered row after
        // reload. animated:false so a reload never animates a hover change.
        card.setHover(.none, animated: false)
    }
}

// MARK: - Marquee label
//
// A clipping container around a single-line field whose text lives at full width.
// At rest the field is capped at the container and its tail ellipsizes, so a step that
// doesn't fit ends in "…" instead of being sliced through a glyph — the "…" IS the
// signal that hovering will show more (T153). While the row is hovered, an overflowing
// field scrolls continuously right-to-left as an endless
// ticker: a trailing clone follows one (text + gap) span behind, so when the clone
// reaches the head the frame is identical to t=0 and the infinite loop has no seam.
// The scroll arms only when the text actually overflows — a fitting string stays
// perfectly still. The container never props the row open (low compression/hugging +
// no intrinsic width), so it can't undo the window's minimum width.
final class MarqueeLabel: NSView {
    private let field = NSTextField(labelWithString: "")
    private let clone = NSTextField(labelWithString: "")   // trailing copy that supplies the seamless wrap-around
    private var leading: NSLayoutConstraint!
    private var hovering = false
    private let gap: CGFloat = 44   // blank run between the tail and the wrapped-around head
    // Rest-state cap: the field can't outgrow the container, so an overflowing step
    // truncates with an ellipsis. Released while hovering — the field must be back at
    // its full natural width before startMarquee() reads the scroll span off its frame.
    private lazy var restCap = field.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.masksToBounds = true               // clip the overflowing tail (and the off-right clone)
        for f in [field, clone] {
            f.wantsLayer = true                    // animate the field's layer, not the text
            // The field is capped at the container at rest (restCap), so this is what
            // puts the "…" on an overflowing step. The clone is never capped — it only
            // shows mid-scroll, where the full string is the point.
            f.lineBreakMode = .byTruncatingTail
            f.maximumNumberOfLines = 1
            f.usesSingleLineMode = true
            f.translatesAutoresizingMaskIntoConstraints = false
            addSubview(f)
        }
        clone.isHidden = true                      // only revealed while a loop is running
        leading = field.leadingAnchor.constraint(equalTo: leadingAnchor)
        NSLayoutConstraint.activate([
            leading,
            restCap,
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
            clone.leadingAnchor.constraint(equalTo: field.trailingAnchor, constant: gap),
            clone.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setContentHuggingPriority(.defaultLow, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError() }

    var font: NSFont? { get { field.font } set { field.font = newValue; clone.font = newValue } }

    var attributedText: NSAttributedString = NSAttributedString() {
        didSet {
            // The list re-runs configure() every 2.5s poll, re-setting an identical
            // step. Bail on unchanged content so an in-flight scroll isn't yanked back
            // to the head each refresh (the visible flicker while hovering). Genuinely
            // new step text falls through and restarts the cycle from the head.
            guard attributedText != oldValue else { return }
            field.attributedStringValue = attributedText
            clone.attributedStringValue = attributedText
            stopMarquee()
            needsLayout = true
        }
    }

    // Full width comes from the field; the container's own width must not track it,
    // or an overflowing step would widen the whole window past its minimum.
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: field.intrinsicContentSize.height)
    }

    // Measured off the laid-out frame, not fittingSize: while hovering restCap is off, so
    // the frame IS the full natural width — and reading the frame keeps the scroll span
    // and this test on the same number no matter what the constraint state is.
    private var overflow: CGFloat { max(0, field.frame.width - bounds.width) }

    override func layout() {
        super.layout()
        if hovering { startMarquee() } else { stopMarquee() }
    }

    func setHovered(_ on: Bool) {
        guard on != hovering else { return }
        hovering = on
        // Drop the cap first so the layout pass this schedules widens the field back to
        // full text; layout() then arms the loop against the resolved frame.
        restCap.isActive = !on
        needsLayout = true
    }

    private func startMarquee() {
        // Nothing to scroll, or a cycle is already running → leave it be.
        guard overflow > 1 else { stopMarquee(); return }
        guard field.layer?.animation(forKey: "marquee") == nil else { return }
        // Glide both copies left in lockstep by exactly one (text + gap) span. At the end
        // the clone sits where the field began → seamless infinite right-to-left loop.
        let span = field.frame.width + gap
        clone.isHidden = false
        let a = CABasicAnimation(keyPath: "transform.translation.x")
        a.fromValue = 0
        a.toValue = -span
        a.duration = Double(span) / 42.0          // constant speed; longer text just takes longer
        a.repeatCount = .infinity
        a.timingFunction = CAMediaTimingFunction(name: .linear)
        field.layer?.add(a, forKey: "marquee")
        clone.layer?.add(a, forKey: "marquee")
    }

    private func stopMarquee() {
        field.layer?.removeAnimation(forKey: "marquee")
        clone.layer?.removeAnimation(forKey: "marquee")
        clone.isHidden = true
    }
}

// MARK: - Child cell (one terminal under a folder header)
//
// Compact, indented row for a single session inside a multi-session folder. Shows
// the tty, its status pill, and a left rail tinted by status. Click → focus that
// exact terminal.

final class ChildCell: NSTableCellView, HandleProviding, Hoverable {
    private let card = GroupCard(radius: Theme.group)   // a middle / bottom slice of the enclosure
    private let railGrip = RailGrip(barHeight: 18)
    private let dot = StatusDot(diameter: 14)   // 14, not 9: at 9 the glyphs (⏸ bars, ✓) were
                                                // sub-2px smears crowding the disc edge. 64pt rows
                                                // carry a toast-sized dot fine; 11 was still too timid.
    private let ttyLabel = NSTextField(labelWithString: "")
    // The metrics column (⏱ time · ◆ tokens · % · model) — a shared component, the very
    // same one the expanded agent sublist uses (see UsageMetricsView), so both lists
    // render one line, one geometry, one set of rules.
    private let usage = UsageMetricsView()
    private let stepLabel = MarqueeLabel()   // "▸ Edit · main.swift" — live tool step while 运行中, sharing the meta
                                             // line right of the fixed usage column; hover scrolls/ tooltips the tail
    private let pctText = NSTextField(labelWithString: "")  // 变体 C: right-aligned colored %
    private let ctxBar = ContextBarView()          // 变体 C: full-width occupancy bar on the bottom edge
    private let pill = CapsuleLabel()
    private let agentBadge = AgentBadge()   // 方案 A: 🤖 ×N running-subagent chip, left of the pill
    // "bash" — what KIND of work the 运行中 is. Same tag component (and the same
    // 0.22 fill / 0.48 border recipe) the agent sublist wears for its 职位 chips, one size
    // down: it shares the title line with the status pill and must not read as a second one.
    private let shellTag = AgentTag(fontSize: 9.5, height: 15, hPad: 6)
    // Collapses the pill to zero width so the tty label reclaims the space when
    // status labels are turned off in Settings.
    private lazy var pillCollapse = pill.widthAnchor.constraint(equalToConstant: 0)
    // The agent badge sits just left of the pill. Both constraints collapse to zero
    // (width 0 + gap 0) when the row has no background agents, so badge.leading lands
    // exactly on pill.leading and every element anchored to badge.leading keeps its
    // original spacing — the no-agent row is pixel-identical to before.
    private lazy var agentCollapse = agentBadge.widthAnchor.constraint(equalToConstant: 0)
    private lazy var agentBadgeTrailing =
        agentBadge.trailingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 0)
    // The bash/shell tag joins the same right-hand attribute band, one slot further left,
    // and collapses by the same rule: zero width AND zero gap, so a row without a command
    // running is pixel-identical to one that never had the tag. Everything that used to
    // stop at the badge's leading edge now stops here — the tag is the band's new left edge.
    // WHETHER it gets that slot is a width question, answered in applyRoom() below.
    private lazy var shellCollapse = shellTag.widthAnchor.constraint(equalToConstant: 0)
    private lazy var shellTagTrailing =
        shellTag.trailingAnchor.constraint(equalTo: agentBadge.leadingAnchor, constant: 0)
    // Caps the whole usage block at the step's start while a step shares the meta line
    // (see the activation site in configure()): the block grows with its content, so
    // without the cap a long meta run would shove the step column out of alignment.
    private lazy var usageWithinColumn =
        usage.trailingAnchor.constraint(lessThanOrEqualTo: stepLabel.leadingAnchor, constant: -8)
    // The step's start = the end of the reserved usage block, so it begins at the same x
    // in every row. Held as a property because the reserved width shifts with the gauge
    // style / model setting (see UsageMetricsView.reservedWidth).
    private lazy var stepLeading =
        stepLabel.leadingAnchor.constraint(equalTo: usage.leadingAnchor,
                                           constant: UsageMetricsView.reservedWidth)

    // The title's vertical placement swaps for a solo (subtitle-less) row: normally it
    // sits just above center with the usage meta beneath (ttyAbove); with no subtitle it
    // centers vertically (ttyCentered) and enlarges so an idle "空闲" reads as the row's
    // sole, balanced content. Exactly one is active at a time — see configure().
    private lazy var ttyAbove = ttyLabel.bottomAnchor.constraint(equalTo: card.centerYAnchor, constant: -3)
    // +1 nudges the sole title down to optical center — a CJK glyph like "空闲" sits
    // high in its line box, so a pure geometric center reads as too-high. Kept small so
    // the title stays level with the status dot (which sits at the geometric center).
    private lazy var ttyCentered = ttyLabel.centerYAnchor.constraint(equalTo: card.centerYAnchor, constant: -2.5)

    private var status = "idle"

    // ── Step column floor (T153) ──
    //
    // The step starts at a fixed x (stepLeading) and ends before the pill, so its width
    // is whatever the WINDOW leaves over — and at the 384pt minimum that remainder is
    // ~0: the column silently drew nothing, which is what read as "位置不够就直接没有
    // 显示了". Below this floor the column is dropped outright instead of rendering an
    // unreadable sliver; the full step is still one hover away in the row's tooltip.
    private static let stepMinW: CGFloat = 60
    // The right-edge slot the step must clear. A CONSTANT on purpose — measuring this
    // row's own pill (状态词 widths differ per status and per language, and an agent
    // badge replaces it entirely) would let one row show a step while its neighbour
    // doesn't, at the same window width.
    private static let rightSlotW: CGFloat = 62
    // The slot the bash/shell tag needs: its two possible words at 9.5pt bold plus the
    // tag's own padding and the 6pt gap before the badge. A CONSTANT for the same reason
    // rightSlotW is — measured per row, two rows at the same window width could disagree.
    private static let shellSlotW: CGFloat = 52
    private var wantsShell = false                // this row has a command running…
    private var shellShown = false                // …and the width actually allowed the tag
    private var stepAttr = NSAttributedString()   // what the step column would show…
    private var wantsStep = false                 // …and whether this row has a step at all
    private var stepShown = false
    // The settings live preview opts out: its rows are mocks whose whole job is to show
    // the element a toggle points at, and its card can be narrower than the floor in a
    // small settings window — dropping the step there would break the 当前步骤 preview.
    var enforcesStepFloor = true

    var dragHandle: NSView { railGrip }

    init(id: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        identifier = id
        letShadowsEscape()

        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)

        // The thin status-tinted rail at the left edge ties the child to its group,
        // and doubles as the grip: grab it to reorder within the folder group.
        card.addSubview(railGrip)

        dot.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(dot)

        ttyLabel.font = Theme.font(13, .medium)
        ttyLabel.textColor = .secondaryLabelColor
        ttyLabel.lineBreakMode = .byTruncatingTail
        // Truncate the label before the status pill is forced to shrink.
        ttyLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        ttyLabel.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(ttyLabel)

        card.addSubview(usage)

        // Live tool step, sharing the meta line to the right of the fixed usage column
        // (only populated while 运行中). Tinted with the working accent in stepText().
        // Single-line/clip/compression behavior lives inside MarqueeLabel.
        stepLabel.font = Theme.rounded(10.5, .medium)
        card.addSubview(stepLabel)

        // Bottom-edge occupancy bar (变体 C) — added first so the pill/labels paint above it.
        ctxBar.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(ctxBar)

        pctText.font = Theme.rounded(10.5, .bold)
        pctText.translatesAutoresizingMaskIntoConstraints = false
        pctText.setContentHuggingPriority(.required, for: .horizontal)
        pctText.setContentCompressionResistancePriority(.required, for: .horizontal)
        card.addSubview(pctText)

        pill.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(pill)

        agentBadge.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(agentBadge)

        shellTag.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(shellTag)

        NSLayoutConstraint.activate([
            agentBadgeTrailing,
            agentBadge.centerYAnchor.constraint(equalTo: card.centerYAnchor),

            shellTagTrailing,
            shellTag.centerYAnchor.constraint(equalTo: card.centerYAnchor),

            // Same edges as HeaderCell (6 / -6) so the side borders form one
            // continuous line; the nesting now reads from being *inside* the
            // enclosure, not from a card indent. Top/bottom flush = no interior gap.
            card.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.cardCellInset),
            card.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.cardCellInset),
            card.topAnchor.constraint(equalTo: topAnchor, constant: 0),
            card.bottomAnchor.constraint(equalTo: bottomAnchor, constant: 0),

            railGrip.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 9),
            railGrip.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            railGrip.widthAnchor.constraint(equalToConstant: 14),
            railGrip.heightAnchor.constraint(equalToConstant: 26),

            dot.leadingAnchor.constraint(equalTo: railGrip.trailingAnchor, constant: 8),
            dot.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 14),
            dot.heightAnchor.constraint(equalToConstant: 14),

            // Title on top, usage meta beneath — the pair vertically centered. The title's
            // own vertical anchor (ttyAbove / ttyCentered) is activated in configure().
            ttyLabel.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 10),
            ttyLabel.trailingAnchor.constraint(lessThanOrEqualTo: shellTag.leadingAnchor, constant: -8),

            // The metrics block: its own leading edge is the meta origin every fixed
            // sub-column inside it is measured from (see UsageMetricsView). Top-anchored
            // 1pt above where the text used to start so the 16pt block centers the same
            // line the bare label did.
            usage.leadingAnchor.constraint(equalTo: ttyLabel.leadingAnchor),
            usage.topAnchor.constraint(equalTo: card.centerYAnchor, constant: 2),
            usage.trailingAnchor.constraint(lessThanOrEqualTo: pctText.leadingAnchor, constant: -6),
            usage.trailingAnchor.constraint(lessThanOrEqualTo: shellTag.leadingAnchor, constant: -8),

            // 变体 C: the % sits at the row's right edge (empty string → zero width when
            // this style is inactive), the bar spans the bottom edge inset from corners.
            pctText.trailingAnchor.constraint(equalTo: shellTag.leadingAnchor, constant: -8),
            pctText.centerYAnchor.constraint(equalTo: usage.centerYAnchor),

            ctxBar.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            ctxBar.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            ctxBar.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -6),
            ctxBar.heightAnchor.constraint(equalToConstant: 3),

            // The step begins one fixed column-width past the meta origin, so the usage
            // column (⏱ time · tokens · % · model) stays a constant width and the step
            // aligns across rows. Empty (zero-width) when not 运行中 → invisible.
            stepLeading,
            stepLabel.centerYAnchor.constraint(equalTo: usage.centerYAnchor),
            stepLabel.trailingAnchor.constraint(lessThanOrEqualTo: shellTag.leadingAnchor, constant: -8),

            pill.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -Theme.inset),
            pill.centerYAnchor.constraint(equalTo: card.centerYAnchor),
        ])
        // Start collapsed so the initial state agrees with shellShown; applyRoom() owns
        // every flip from here on.
        shellTag.isHidden = true
        shellCollapse.isActive = true

        // Active only while a step shares the line: caps the usage block at the step's
        // start so long usage truncates instead of shoving the step. Inactive otherwise
        // → the block reclaims the full width up to the pill.
        usageWithinColumn.isActive = false

        card.setHover(.none, animated: false)
    }
    required init?(coder: NSCoder) { fatalError() }

    // Hover is driven by the table (see ReorderTableView), not a per-cell tracking
    // area — one hovered row, hit-tested, no synthesized-enter waterfall.
    func setHovered(_ lift: HoverLift, groupCenter: NSPoint?, groupRole: SliceRole?, animated: Bool) {
        card.setHover(lift,
                      groupCenter: groupCenter.map { card.convert($0, from: self) },
                      groupRole: groupRole,
                      animated: animated)
        // Row-local flourishes (rail pop, step marquee) belong to the row actually
        // being pointed at: a card float, or the head of an agent cluster (方案 16 —
        // the row lifts together with its own agent segment, and a group lift there
        // still means "you are on this row"). Rows merely riding along in a header's
        // group lift (H1) stay unchanged — a header's group never leads with a child.
        let on = lift == .card || (lift == .group && groupRole == .top)
        railGrip.setHovered(on, animated: animated)
        stepLabel.setHovered(on)
    }

    func setSelected(_ on: Bool, animated: Bool) {
        card.setSelected(on, animated: animated)
        // The rail wears the selection too — same grown, glowing bar a hover gives it.
        railGrip.setSelected(on, animated: animated)
    }

    // ── First click jumps, even when SpectiX isn't the active app ──
    //
    // ReorderTableView.acceptsFirstMouse alone wasn't enough: AppKit asks the view
    // hitTest LANDS ON, and on a row that's a card subview (GroupCard, a label, the
    // rail) — all plain NSViews that decline the first mouse — so the click that
    // activated the window was still swallowed and the jump needed a second click.
    // Claim the whole card for the cell (same trick as the toast's
    // ToastSurfaceView) and accept the activating click. None of the subviews
    // handle clicks themselves — the grip and the chevron are hit-tested in window
    // coordinates by ReorderTableView / rowClicked — so nothing is lost.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    // Did a click (window coords) land on the visible 🤖 badge? The cell claims every
    // click via hitTest above, so SessionListView.rowClicked asks after the fact —
    // same pattern as HeaderCell.chevronHit. Padded a few points so the small capsule
    // isn't a precision target.
    func agentBadgeHit(_ locationInWindow: NSPoint) -> Bool {
        guard !agentBadge.isHidden, agentBadge.bounds.width > 0 else { return false }
        let p = agentBadge.convert(locationInWindow, from: nil)
        return agentBadge.bounds.insetBy(dx: -6, dy: -8).contains(p)
    }

    // `isFirst` / `isLast` place this row within its enclosure: the last row rounds
    // the container's bottom (role .bottom), interior rows are square (.middle), and
    // every row but the first draws the between-rows hairline at its top edge (the
    // first sits right under the header's own under-line, so it stays clean).
    // `roundTop` is for the settings live preview, which shows rows with no header
    // above them: in the real list the first row's flat top is capped by the header's
    // rounded head, so on its own it needs to round (and close) its own top edge.
    func configure(_ r: SessionRow, isFirst: Bool, isLast: Bool, agentExpanded: Bool = false,
                   roundTop: Bool = false) {
        status = r.status
        // Title text uses the primary label color so it reads at full contrast —
        // white in dark mode, black in light mode. (idleSolo re-renders its own
        // attributed title below, keeping its muted moon-glyph tone.)
        ttyLabel.textColor = .labelColor
        let role: SliceRole = roundTop && isFirst
            ? (isLast ? .solo : .top)
            : (isLast ? .bottom : .middle)
        card.configure(role: role, isHeaderBand: false, topDivider: !isFirst)
        // Keyed by session so the one-shot "done landing" pop plays exactly once
        // per completion, surviving cell recycling and reconfigure churn.
        dot.apply(r.status, key: r.id)
        card.setAccent(r.status)
        railGrip.setColor(Status.accent(r.status))
        // Idle sessions with no task title read as a plain "空闲" instead of the
        // "会话 NN" device fallback — the number carries no signal when nothing's running.
        if !r.taskTitle.isEmpty {
            ttyLabel.stringValue = r.taskTitle
        } else if r.status == "idle" {
            ttyLabel.stringValue = L("空闲", "Idle")
        } else {
            ttyLabel.stringValue = L("会话 \(r.seqLabel)", "Session \(r.seqLabel)")
        }
        // The usage line (⏱ time · tokens · %) now stays in a fixed-width column and no
        // longer vanishes while 运行中 — the live step ("▸ Edit · main.swift") shares the
        // line to its right instead of replacing it. Desktop rows carry no time/token
        // data, so they surface the live status phrase in place of the usage column.
        let style = AppSettings.contextGaugeStyle
        // A step shows while 运行中 with a live tool step, OR while waiting on background
        // subagents (bg ledger non-empty) even before any of them reports a tool.
        // A real tool step shows while 运行中. The hook's bare "Agent · 后台任务运行中"
        // placeholder (emitted while waiting on subagents before any reports a tool) is
        // now redundant — the standalone 🤖 ×N badge (方案 A) carries the agent count — so
        // it's treated as "no step" and the row falls back to its usage line.
        // The live tool step is off by default (设置 → 显示 → 列表 → 当前步骤), and a
        // desktop row never had one — bail before reading it at all, so the default path
        // costs nothing per row per refresh. The background annotations below cost
        // nothing either: both branches are behind a count that is 0 on a quiet row.
        var realStep = ""
        if !r.isDesktop, AppSettings.showStepLabel {
            // ★ One switch covers everything this column draws (改这块前必读): the live
            // tool step AND the two background annotations below. They were briefly
            // exempt — 「等待」 only recolours the row, so with the switch off nothing
            // said WHAT the row was waiting on — but 2026-09-12 用户拍板「setting 有开就
            // 显示，没有就不显示」: a switch labelled 当前步骤 that still leaves text in
            // that column is a broken switch. The 等待 pill keeps carrying the "work
            // continues" signal on its own; only the wordy line goes.
            realStep = r.step == "Agent · 后台任务运行中" ? "" : r.step
            // A done row with a live background command (run_in_background) has no hook
            // step — Stop already cleared step-<tty> — so a bare green row would read as
            // "nothing happening". Per T54 the row stays done (绿「该你了」, not 运行中蓝),
            // but we still annotate what's running with the shell count, mirroring Claude
            // Code's own "N shells still running", so you know work continues in the background.
            if realStep.isEmpty, r.bgShells > 0 {
                // Append the oldest shell's runtime so a long-running background command
                // reads as "still running, 3m in" rather than an unexplained subtitle.
                let runtime = r.bgShellsSince > 0
                    ? " · " + UsageMetricsView.fmtDur(max(0, Int(Date().timeIntervalSince1970 - r.bgShellsSince)))
                    : ""
                realStep = L("后台命令 · \(r.bgShells) 个 shell 运行中\(runtime)",
                             "Background · \(r.bgShells) shell\(r.bgShells > 1 ? "s" : "") running\(runtime)")
            } else if realStep.isEmpty, r.bgAgents > 0 {
                // Same shape for background SUBagents (T314): the row is 等待, its hook
                // step was cleared by Stop, and the 🤖 ×N badge alone doesn't say how long
                // they've been out. Runtime comes from the earliest still-running agent's
                // launch stamp — the roster drops an agent as soon as it finishes, so the
                // oldest entry is always one that is genuinely still out.
                let oldest = r.agents.map(\.start).filter { $0 > 0 }.min() ?? 0
                let runtime = oldest > 0
                    ? " · " + UsageMetricsView.fmtDur(max(0, Int(Date().timeIntervalSince1970 - oldest)))
                    : ""
                realStep = L("后台 agent · \(r.bgAgents) 个运行中\(runtime)",
                             "Background · \(r.bgAgents) agent\(r.bgAgents > 1 ? "s" : "") running\(runtime)")
            }
        }
        // Show the step column while 运行中 with a live step, OR whenever a background
        // command is running (bgShells > 0) — that row is 等待 (await, T312), so gating
        // on "working" alone would hide its subtitle. The bg subtitle rides alongside
        // the usage line (they occupy separate columns).
        // realStep is already empty unless the setting is on and this isn't a desktop row.
        let hasStep = !realStep.isEmpty && (r.status == "working" || r.bgShells > 0 || r.bgAgents > 0)
        wantsStep = hasStep
        stepAttr = hasStep ? Self.stepText(realStep) : NSAttributedString()
        // Metrics-column visibility (T75): 闲置 is the ONLY status allowed to render an
        // empty column — every other one keeps ⏱/◆/%/模型 even before its first numbers
        // land, showing "⏱ 0s ◆ 0". The status this fixes is 暂停: an Esc-interrupted turn
        // is frozen out of the in-flight tally (its open run never pairs with a done) and,
        // right after a /clear, has no ctx sample yet — so the old "never ran" gate blanked
        // the whole column on a live session. 运行中/需确认 never hit it (in-flight seconds
        // keep workSec > 0), which is why 暂停 was the one row that went bare.
        let idleSolo = r.status == "idle" && r.taskTitle.isEmpty && !r.isDesktop
        let neverRan = r.workSec <= 0 && r.ctxTokens <= 0
        let showMetrics = !r.isDesktop && !idleSolo && !(neverRan && r.status == "idle")
        let base: NSAttributedString
        if r.isDesktop {
            base = Self.desktopMetaText(r.status)
        } else {
            // `always` keeps the slots visible at zero — without it a 暂停 row with nothing
            // tallied yet falls back to an empty subtitle, the bug this fixes.
            base = UsageMetricsView.usageText(workSec: r.workSec, ctxTokens: r.ctxTokens,
                                              always: showMetrics)
        }
        // Context-occupancy indicator. Desktop rows carry no token data (pct -1 hides
        // everything). A "尚未运行" session (never ran) also hides the gauge — 0% only
        // shows once it has actually started. Only the selected style's views show; the
        // other collapse away — 变体 B = inline % chip, 变体 C = right-aligned % + bottom bar.
        // Idle terminal rows collapse to just the centered "空闲" title — no usage
        // subtitle at all, so "idle = show nothing else" holds even for a session that
        // ran earlier (its ⏱ time would otherwise keep the row in two-line mode). The
        // context gauge is part of "nothing else": an idle row hides the %/bar too.
        // showMetrics (above) is the single gate all three wear.
        let pct = showMetrics ? r.ctxPct : -1
        let showBar = style == .bar && pct >= 0
        // The right-aligned % (变体 C) collides with the step column, so drop it while a
        // step shares the line — the bottom bar still conveys occupancy.
        pctText.attributedStringValue = (showBar && !hasStep)
            ? UsageMetricsView.pctString(pct) : NSAttributedString()
        ctxBar.isHidden = !showBar
        if showBar { ctxBar.configure(pct: pct) }
        // The model wears the same visibility rules as the rest of the usage line: hidden
        // on a desktop row (no model) and on an idle row (which shows nothing but its
        // title). The Settings toggle is applied inside the component, along with the
        // gauge style.
        // Desktop rows have no metrics but DO have a model: it's read straight off the
        // window's own picker, so the chip is truthful there even though ⏱/◆/% aren't.
        let showModel = showMetrics || r.isDesktop
        // Status-group mode mixes sessions from different projects under one bucket,
        // so prefix the owning project name to keep each row's source legible.
        let meta: NSAttributedString
        if idleSolo {
            meta = NSAttributedString()
        } else if AppSettings.sortMode == .status {
            let proj = r.projectName
            meta = Self.prefixProject(proj, base)
        } else {
            meta = base
        }
        usage.configure(meta: meta, pct: pct, model: showModel ? r.model : "",
                        freeMeta: r.isDesktop)
        // The step starts where the reserved block ends — which shrinks with the gauge
        // style / model setting, so re-read it on every configure.
        stepLeading.constant = UsageMetricsView.reservedWidth
        // Hovering the row spells out whatever the columns had to cut (T153): the full
        // title, the metrics line, and the whole step — whose column truncates early and
        // is dropped outright on a narrow window (applyStepRoom). Same answer the stats
        // window already gives its truncated rows (see StatsWindow.taskRow).
        // Attached to the CELL, not to a label: hitTest() hands every point inside the
        // card to self, so a label-owned tooltip would never be the view under the mouse.
        // An idle row carries nothing but "空闲" — repeating that is noise, not a reveal.
        if idleSolo {
            toolTip = nil
        } else {
            var lines = [ttyLabel.stringValue]
            let metaLine = meta.string.trimmingCharacters(in: .whitespaces)
            if !metaLine.isEmpty { lines.append(metaLine) }
            if !realStep.isEmpty { lines.append("▸ " + realStep) }
            toolTip = lines.joined(separator: "\n")
        }
        // Only a pure idle "空闲" row enlarges + centers its title as the row's sole
        // content. Every other status keeps the normal 14pt two-line layout (title above,
        // usage/time meta beneath) — matching 运行中 — even when its meta happens to be
        // empty (e.g. a done/needs session that hasn't accrued usage yet), so "big font"
        // reads as the idle signal alone and never leaks onto other states.
        let soloTitle = idleSolo
        ttyLabel.font = Theme.font(soloTitle ? 16 : 14, .medium)
        ttyAbove.isActive = !soloTitle
        ttyCentered.isActive = soloTitle
        // Re-apply the idle title as rich text AFTER the font setter above — setting
        // ttyLabel.font re-renders from the plain stringValue and strips the sleep-glyph
        // attachment, so the icon must be (re)installed last to survive.
        if idleSolo {
            ttyLabel.attributedStringValue = Self.idleTitle(chat: r.isChatPanel)
        } else if r.isChatPanel, r.status == "idle" {
            // Same mark for an idle chat row that kept a task title (SessionStart writes
            // idle while title-<key> still holds the last one), which never reaches the
            // idleSolo branch above.
            let t = NSMutableAttributedString(string: ttyLabel.stringValue,
                attributes: [.font: Theme.font(14, .medium),
                             .foregroundColor: NSColor.labelColor])
            t.append(Self.chatTag(size: 14))
            ttyLabel.attributedStringValue = t
        }
        // 方案 A + C: the 🤖 ×N badge (iris glass + breathing pulse) shows whenever this
        // session has background subagents in flight — in ANY status (running / needs /
        // done / idle), not just 运行中. When it shows it STANDS IN for the status pill
        // (they're mutually exclusive: the agent badge is that moment's status label), so
        // it takes the pill's right-edge slot at the same size. Desktop rows carry no bg
        // ledger → never shown, pill behaves as before.
        let showAgent = !r.isDesktop && r.bgAgents > 0
        let showPill = AppSettings.showStatusLabels && !showAgent
        pill.isHidden = !showPill
        pillCollapse.isActive = !showPill
        if showPill { pill.configure(status: r.status, text: Status.label(r.status)) }
        // With the pill collapsed to zero width, pill.leading == the card's right edge,
        // so the badge (trailing anchored to pill.leading, constant 0) lands exactly
        // where the pill would sit. When there's no agent it collapses to zero width at
        // the same point, costing nothing.
        agentBadge.configure(count: showAgent ? r.bgAgents : 0, expanded: agentExpanded)
        agentCollapse.isActive = !showAgent
        // The bash tag. A FOREGROUND command run does not get its own status — the row
        // stays 运行中 — so the tag is the only thing that separates "thinking / editing"
        // from "waiting on a command", and it has to survive 当前步骤 being off (that
        // column is off by default; this is the whole point of the tag). A backgrounded
        // command gets the second word, 'shell': that row IS the 等待 status (T312), but
        // the pill only says it is waiting — see the branch below for why the word came
        // back. Desktop rows have no hook data at all → never tagged.
        let cmdTag: String
        if !AppSettings.showShellBadge || r.isDesktop {
            cmdTag = ""
        } else if r.status == "working", r.step == "Bash" || r.step.hasPrefix("Bash ·") {
            cmdTag = "bash"
        } else if r.bgShells > 0 {
            // ★ 「等待」 restores the second word (改这块前必读). T312 deleted it on the
            // theory that the 等待 pill already says this — but the pill says "waiting",
            // not WHAT for: a row waiting on background AGENTS carries the 🤖 ×N badge,
            // and a row waiting on a command then carried nothing at all. The subtitle
            // that would have explained it cannot help: at popover width applyRoom()
            // leaves ~45pt and the step column's floor is 60 (2026-09-12 用户当场问
            // 「在等待什么？我没有看到有 shell 的标记」). The tag is served FIRST in that
            // budget, so it is the only thing that survives a narrow row.
            cmdTag = "shell"
        } else {
            cmdTag = ""
        }
        // Only the intent is recorded here — whether the row is wide enough to carry the
        // tag is decided in applyRoom(), on a layout pass where bounds are trustworthy.
        wantsShell = !cmdTag.isEmpty
        // Both intents (step + tag) are set by now, so a first pass can run; bounds may
        // still be stale on a recycled cell, which is why layout() runs it again.
        applyRoom()
        if !cmdTag.isEmpty {
            // Blue, and its OWN blue — not `Status.accent("working")`. The tag rides the
            // same edge as the status pill and shows up on done/idle rows too (that is
            // what `shell` means), so a status tone would either duplicate the pill next
            // to it or flatly contradict the row it sits on. A hue outside the status
            // palette says 「这是在等一条命令」 without claiming to be a state. Filled AND
            // outlined — a borderless wash vanishes into the glass at this size.
            let tint = Theme.shellTagAccent
            shellTag.configure(text: cmdTag, textColor: tint,
                               fill: tint.withAlphaComponent(0.22),
                               border: tint.withAlphaComponent(0.48))
        }
        // Reset hover on (re)configure; the table re-syncs the real hovered row after
        // reload (in the same runloop, so the drop is never drawn). animated:false so a
        // reload never animates a hover change. The rail goes with the card — it's part
        // of the same lift, and a cell recycled off the hovered row onto another one
        // would otherwise keep its grown rail with nothing to reset it (only rows still
        // in the table's renderedRows get an explicit .none). stepLabel stays out: its
        // marquee is guarded on change, and stopping it here would restart the scroll
        // from the head on every refresh.
        card.setHover(.none, animated: false)
        railGrip.setHovered(false, animated: false)
        // Selection is recycled for the same reason (GroupCard.configure clears its own
        // half); the table re-asserts the real selected row right after the reload.
        railGrip.setSelected(false, animated: false)
    }

    override func layout() {
        super.layout()
        // The row's width is only trustworthy here — configure() runs on recycled cells
        // that haven't been sized yet — and it changes on every window resize without a
        // reconfigure, so the floors have to be re-checked on each pass.
        applyRoom()
    }

    // Hand out the leftover width — first to the bash/shell tag, then to the step column
    // — and drop whichever doesn't fit rather than rendering it squeezed.
    //
    // The remainder is a function of the WINDOW's width and the global display settings
    // (reservedWidth already is one) — never of this row's own content. That's the rule
    // the whole column system rests on: every row's step starts at the same x, so every
    // row must also agree on whether there IS a step column. See docs/row-display.md.
    private func applyRoom() {
        var room = bounds.width
            - Theme.cardCellInset * 2               // card inset, both edges
            - 55                                    // meta origin (rail + dot + gaps)
            - UsageMetricsView.reservedWidth        // the fixed ⏱ · ◆ · % · model column
            - (AppSettings.showStatusLabels ? Self.rightSlotW : 0)
            - Theme.inset - 8                       // pill's right inset + the gap before it

        // The tag is served first (it's the smaller ask, and it survives 当前步骤 being
        // off — the whole reason it exists), but below its own slot it is dropped, not
        // squeezed in: taking those points out of a narrow row is what flattened the
        // title and meta columns, which is what "看不到" actually was (T256).
        let showShell = wantsShell && (!enforcesStepFloor || room >= Self.shellSlotW)
        if showShell != shellShown {
            shellShown = showShell
            shellTag.isHidden = !showShell
            shellCollapse.isActive = !showShell
            // Zero gap when collapsed so shellTag.leading lands exactly on
            // agentBadge.leading and every column anchored to it keeps its spacing.
            shellTagTrailing.constant = showShell ? -6 : 0
        }
        if showShell { room -= Self.shellSlotW }

        let show = wantsStep && (!enforcesStepFloor || room >= Self.stepMinW)
        // Only flip the constraint when the state actually changes — this runs on every
        // layout pass, and the usage block's cap must not be re-set from inside one.
        if show != stepShown {
            stepShown = show
            usageWithinColumn.isActive = show
        }
        // Identical text is a no-op inside MarqueeLabel (it guards its own didSet so an
        // in-flight scroll isn't yanked back to the head), so this is safe to repeat.
        stepLabel.attributedText = show ? stepAttr : NSAttributedString()
    }

    // Which single subview a display setting visually maps to, for the settings
    // live-preview card: after a setting changes it flashes this element so "the thing
    // you just changed" is unmistakable (design/settings-live-preview.html 方案 3).
    //
    // nil means "no one element" — either the setting was just switched off (nothing
    // left to point at) or it acts on the list as a whole (sorting reorders every row;
    // a status color reaches every tinted part of all of them). The caller flashes the
    // whole list in that case.
    func previewFlashTarget(for key: AppSettings.DisplayKey) -> NSView? {
        switch key {
        case .statusLabels: return pill.isHidden ? nil : pill
        case .modelLabel:   return AppSettings.showModelLabel ? usage.modelChipView : nil
        case .stepLabel:    return AppSettings.showStepLabel ? stepLabel : nil
        case .shellBadge:   return shellTag.isHidden ? nil : shellTag
        // Both metrics live in one text run, so either switch points at that run — and
        // only while it still paints something (switching the last one off leaves an
        // empty label, and the card falls back to flashing the whole list).
        case .duration:     return AppSettings.showDuration ? usage.metaTextView : nil
        case .tokens:       return AppSettings.showTokens ? usage.metaTextView : nil
        case .contextGauge:
            switch AppSettings.contextGaugeStyle {
            case .capsule: return usage.pctChipView
            case .bar:     return ctxBar.isHidden ? nil : ctxBar
            case .off:     return nil
            }
        case .sortMode, .statusColors: return nil
        }
    }

    // "空闲 ☾zzz" — an idle row's sole title: the label with a sleeping moon glyph
    // trailing it, both muted and slightly enlarged (15pt). The glyph is vertically
    // centered on the text via a baseline-adjusted attachment so word + icon sit on
    // one optical line.
    static func idleTitle(chat: Bool = false) -> NSAttributedString {
        let font = Theme.font(16, .medium)
        let tint = NSColor.secondaryLabelColor
        let out = NSMutableAttributedString()
        out.append(NSAttributedString(string: L("空闲", "Idle"),
            attributes: [.font: font, .foregroundColor: tint]))
        let cfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [tint]))
        if let img = NSImage(systemSymbolName: "moon.zzz.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg) {
            let att = NSTextAttachment()
            att.image = img
            let h = img.size.height
            // +2 raises the glyph above the text's optical center so the moon sits a
            // touch higher than the label baseline.
            att.bounds = CGRect(x: 0, y: (font.capHeight - h) / 2 + 2, width: img.size.width, height: h)
            out.append(NSAttributedString(string: "  "))
            out.append(NSAttributedString(attachment: att))
        }
        if chat { out.append(chatTag(size: 16)) }
        return out
    }

    // "· Chat" — the only thing that tells an idle chat-panel row apart from an idle
    // terminal one: both otherwise render the identical "空闲 ☾zzz", and a chat panel has
    // no tty to fall back on. Idle-only by design — a working/done row already identifies
    // itself through its title and step, where a source tag would just be noise.
    // Trailing, per the user's call: the title truncates its tail, so an idle row that
    // kept a long task title can swallow the mark — accepted, since the row it actually
    // matters on is the bare "空闲" one, which has room to spare.
    static func chatTag(size: CGFloat) -> NSAttributedString {
        NSAttributedString(string: " · Chat", attributes: [
            .font: Theme.font(max(11, size - 3), .semibold),
            .foregroundColor: NSColor.secondaryLabelColor])
    }

    // Desktop-app subtitle: the app exposes no time/token data, so the row shows a
    // status phrase tinted with its accent — "正在回复…" (working), "回复完成" (done),
    // "空闲中" (idle) — instead of the empty meta line.
    static func desktopMetaText(_ status: String) -> NSAttributedString {
        let text: String
        switch status {
        case "working": text = L("▸ 正在回复…", "▸ Replying…")
        case "done":    text = L("✓ 回复完成", "✓ Reply done")
        default:        text = L("空闲中", "Idle")
        }
        let color = status == "done" || status == "working"
            ? Status.accent(status) : NSColor.tertiaryLabelColor
        return NSAttributedString(string: text, attributes: [
            .foregroundColor: color, .font: Theme.rounded(10.5, .medium)])
    }

    // "api · ⏱ 3m · 12k" — prefix the owning project name (status-group mode, where
    // sessions from different projects share one bucket). The name reads as a subtle
    // label ahead of the existing meta content.
    static func prefixProject(_ name: String, _ rest: NSAttributedString) -> NSAttributedString {
        // With every metric switched off there is nothing to separate — the name stands
        // alone rather than trailing a dangling "· ".
        let out = NSMutableAttributedString(string: rest.length == 0 ? name : name + " · ", attributes: [
            .foregroundColor: NSColor.secondaryLabelColor, .font: Theme.rounded(10.5, .semibold)])
        out.append(rest)
        return out
    }

    // "▸ Edit · main.swift" — the live tool step, tinted with the working accent so it
    // reads as in-flight. The label truncates to the width left of the pill (the step
    // now shares the meta line to the right of the fixed usage column).
    static func stepText(_ step: String) -> NSAttributedString {
        NSAttributedString(string: "▸ " + step, attributes: [
            .foregroundColor: Status.accent("working"),
            .font: Theme.rounded(10.5, .medium)])
    }
}
