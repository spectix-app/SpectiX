import Cocoa

// A single-line text layer that stays PIXEL-CRISP while it magnifies on hover.
//
// Why this exists: the hover-lift used to scale the whole row's layer (transform =
// scale 1.018). That makes the GPU up-sample the already-rasterized text bitmap →
// 虚化 (the recurring "hover text goes blurry" bug). A CATextLayer instead re-rasterizes
// its glyphs from the vector outline every time its `fontSize` changes, so growing the
// text via an explicit fontSize animation stays sharp at every frame — no bitmap stretch.
//
// It also re-homes the "free" things NSTextField gave us, so callers don't scatter the
// manual bookkeeping (see the four "弊端" in task/hover-crisp-magnify-plan.md):
//   • 深浅色 — colors are stored as NSColor and re-resolved to CGColor on appearance change
//   • 多屏   — contentsScale tracks the owning view's backingScaleFactor
//   • 截断   — truncationMode + single-line wrapping mirrors .byTruncatingTail
//   • 无障碍 — the layer isn't an a11y element; the OWNING CELL must expose the text via
//             accessibilityLabel. This layer exposes `text` for the cell to read back.
final class CrispTextLayer: CATextLayer {

    // The resting font. `fontSize` animates between this size and `size × liftScale`
    // during hover; the weight/family come from here. Kept so we can re-derive the CGColor
    // and reset fontSize after a lift ends.
    private(set) var baseFont: NSFont = .systemFont(ofSize: 13)
    // Stored as NSColor (not CGColor) so we can re-resolve it for the current appearance —
    // CATextLayer's foregroundColor is a raw CGColor that would NOT follow dark/light mode.
    private var textColor: NSColor = .labelColor

    override init() {
        super.init()
        isWrapped = false                       // single line
        truncationMode = .end                   // == NSTextField .byTruncatingTail
        alignmentMode = .left
        // contentsScale is set to the real backing scale via updateForBackingScale(); this
        // is just a sane default before the layer is hosted (avoids a 1× first frame).
        contentsScale = 2
        font = baseFont
        fontSize = baseFont.pointSize
        foregroundColor = textColor.cgColor
        // The lift animation drives fontSize explicitly; disable implicit animations on the
        // other properties so a text/color/weight swap during cell reuse snaps (no crossfade).
        actions = ["contents": NSNull(), "foregroundColor": NSNull(),
                   "string": NSNull(), "bounds": NSNull(), "position": NSNull()]
    }

    override init(layer: Any) { super.init(layer: layer) }        // required for animations
    required init?(coder: NSCoder) { fatalError() }

    // ── Content ────────────────────────────────────────────────────────────────────
    var text: String {
        get { (string as? String) ?? "" }
        set { string = newValue }
    }

    /// Set font (weight/family + resting size) and text color together — the common cell-reuse
    /// update. Snaps (no animation); the hover lift animates fontSize separately.
    func setStyle(font: NSFont, color: NSColor) {
        baseFont = font
        textColor = color
        CATransaction.begin(); CATransaction.setDisableActions(true)
        self.font = font
        self.fontSize = font.pointSize
        self.foregroundColor = resolvedColor()
        CATransaction.commit()
    }

    // ── Appearance (弊端 3: 深浅色) ──────────────────────────────────────────────────
    /// Re-resolve the stored NSColor to a CGColor for `appearance`. Call from the owning
    /// view's viewDidChangeEffectiveAppearance so semantic colors (.labelColor etc.) track
    /// dark/light mode — a CGColor alone would freeze at whatever mode it was created in.
    func refreshColor(for appearance: NSAppearance) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        foregroundColor = resolvedColor(appearance)
        CATransaction.commit()
    }

    private func resolvedColor(_ appearance: NSAppearance? = nil) -> CGColor {
        var cg = textColor.cgColor
        let a = appearance ?? NSAppearance.currentDrawing()
        a.performAsCurrentDrawingAppearance { cg = self.textColor.cgColor }
        return cg
    }

    // ── Backing scale (弊端 4: 多屏) ─────────────────────────────────────────────────
    /// Match the layer's rasterization to the current screen. Call from the owning view's
    /// viewDidChangeBackingProperties so moving the window between a Retina and a non-Retina
    /// display re-rasterizes the glyphs at the right density instead of up-sampling.
    func updateForBackingScale(_ scale: CGFloat) {
        guard scale > 0, contentsScale != scale else { return }
        contentsScale = scale
    }

    // ── Hover lift (弊端 1: 丝滑 fontSize 动画) ───────────────────────────────────────
    /// Grow (or restore) the text by animating `fontSize` explicitly. Explicit from→to
    /// interpolation is continuous — it does NOT step/jump the way an implicit fontSize
    /// change can on some macOS versions. Because CATextLayer re-rasterizes from the vector
    /// outline at each interpolated size, every frame is crisp (no bitmap stretch).
    func animateLift(to scale: CGFloat, duration: CFTimeInterval, timing: CAMediaTimingFunction) {
        let target = baseFont.pointSize * scale
        guard fontSize != target else { return }
        let anim = CABasicAnimation(keyPath: "fontSize")
        anim.fromValue = fontSize          // current presented size (from the model)
        anim.toValue = target
        anim.duration = duration
        anim.timingFunction = timing
        fontSize = target                  // commit model value first, then attach the anim
        add(anim, forKey: "lift")
    }
}
