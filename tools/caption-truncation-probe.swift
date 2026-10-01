// Why this file exists: the caption's "位置不够就只剩图标、没有文字" bug was once
// "fixed" by flipping CATextLayer.isWrapped, on a plausible but wrong theory, and the
// bug outlived it all the way to a user review. A written conclusion wasn't enough —
// this is the measurement that settles it, so the next change to FocusRing's caption
// text can re-check in one command instead of reasoning from intuition.
//
//   swift tools/caption-truncation-probe.swift
//
// Method: render a CATextLayer offscreen and count non-transparent pixels. 0 means the
// layer drew literally nothing — the failure mode that reads as "标签没显示".
// See docs/focus-ring.md, the ★★ entry on single-line truncation.

import Cocoa
import QuartzCore

_ = NSApplication.shared

func lineHeight(_ fs: CGFloat) -> CGFloat {
    let f = NSFont.systemFont(ofSize: fs)
    return ceil(f.ascender - f.descender)
}

/// Pixels drawn by a CATextLayer holding `string` (a String or an NSAttributedString)
/// in a `width` × `lines`-tall frame.
func drawnPixels(_ string: Any, width: CGFloat, fs: CGFloat = 12, lines: CGFloat = 1,
                 wrapped: Bool, truncation: CATextLayerTruncationMode) -> Int {
    let t = CATextLayer()
    t.isWrapped = wrapped
    t.truncationMode = truncation
    t.contentsScale = 2
    if string is String {   // plain strings carry no attributes; supply them as properties
        t.font = NSFont.systemFont(ofSize: fs)
        t.fontSize = fs
        t.foregroundColor = NSColor.white.cgColor
    }
    t.string = string
    let h = lineHeight(fs) * lines
    t.frame = CGRect(x: 0, y: 0, width: width, height: h)

    let pw = Int(ceil(width * 2)), ph = Int(ceil(h * 2))
    guard pw > 0, ph > 0,
          let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8,
                              bytesPerRow: pw * 4, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return -1 }
    ctx.scaleBy(x: 2, y: 2)
    t.render(in: ctx)
    guard let data = ctx.data else { return -1 }
    let buf = data.bindMemory(to: UInt8.self, capacity: pw * ph * 4)
    var count = 0
    for i in stride(from: 0, to: pw * ph * 4, by: 4) where buf[i + 3] > 8 { count += 1 }
    return count
}

/// The caption's two-tone string: project semibold-white, task regular-muted.
func captionAttr(_ project: String, _ task: String, fs: CGFloat = 12) -> NSAttributedString {
    let s = NSMutableAttributedString(string: project, attributes: [
        .font: NSFont.systemFont(ofSize: fs, weight: .semibold), .foregroundColor: NSColor.white])
    if !task.isEmpty {
        s.append(NSAttributedString(string: "  " + task, attributes: [
            .font: NSFont.systemFont(ofSize: fs, weight: .regular),
            .foregroundColor: NSColor(calibratedWhite: 0.62, alpha: 1)]))
    }
    return s
}

/// The shipped fix, kept in sync with RingView.truncateToFit — cut to fit on composed
/// character boundaries, ellipsis inheriting the attributes of the character it replaces.
func truncateToFit(_ attr: NSAttributedString, width: CGFloat) -> NSAttributedString {
    guard ceil(attr.size().width) > width else { return attr }
    let ns = attr.string as NSString
    guard ns.length > 0 else { return attr }
    var bounds: [Int] = [0]
    var i = 0
    while i < ns.length {
        let r = ns.rangeOfComposedCharacterSequence(at: i)
        i = r.location + r.length
        bounds.append(i)
    }
    func candidate(_ k: Int) -> NSAttributedString {
        let len = bounds[k]
        let m = NSMutableAttributedString(
            attributedString: attr.attributedSubstring(from: NSRange(location: 0, length: len)))
        m.append(NSAttributedString(string: "…",
                 attributes: attr.attributes(at: max(0, len - 1), effectiveRange: nil)))
        return m
    }
    var lo = 0, hi = bounds.count - 1
    while lo < hi {
        let mid = (lo + hi + 1) / 2
        if ceil(candidate(mid).size().width) <= width { lo = mid } else { hi = mid - 1 }
    }
    return candidate(lo)
}

func pad(_ s: String, _ n: Int) -> String {
    let w = s.reduce(0) { $0 + (String($1).lengthOfBytes(using: .utf8) > 2 ? 2 : 1) }
    return w >= n ? s : s + String(repeating: " ", count: n - w)
}

let widths: [CGFloat] = [200, 90, 60, 41, 34, 20]
let sample = captionAttr("中文项目", "把标签在窄终端里也显示出来")
let samplePlain = "中文项目  把标签在窄终端里也显示出来"

print("[1] 病灶 —— attributed string + `.end` + 一行高：需要截断就一个像素都不画")
print(pad("配置", 34) + widths.map { pad(String(Int($0)) + "pt", 8) }.joined())
let sick: [(String, Bool, CATextLayerTruncationMode, CGFloat, Any)] = [
    ("attributed, wrap=F, .end, 1行", false, .end, 1, sample),
    ("attributed, wrap=T, .end, 1行", true, .end, 1, sample),
    ("attributed, wrap=T, .end, 3行", true, .end, 3, sample),
    ("plain String, wrap=F, .end, 1行", false, .end, 1, samplePlain),
]
for (name, wrapped, trunc, lines, str) in sick {
    print(pad(name, 34) + widths.map {
        pad(String(drawnPixels(str, width: $0, lines: lines, wrapped: wrapped, truncation: trunc)), 8)
    }.joined())
}

print("\n[2] 修法 —— 自己截断 + `.none`：每一档都画得出，且末尾有 …")
print(pad("样本", 12) + pad("预算", 6) + pad("实宽", 6) + pad("像素", 7) + "截断结果")
for (label, pj, tk) in [("中文", "中文项目", "把标签在窄终端里也显示出来"),
                        ("英文", "TaskBeacon", "stack the segmented caption"),
                        ("长单词", "SpectiX", "AbsurdlyLongUnbrokenIdentifierName"),
                        ("emoji", "🚀 火箭项目", "把标签显示出来")] {
    let attr = captionAttr(pj, tk)
    for w in widths {
        let fitted = truncateToFit(attr, width: w)
        let used = min(ceil(fitted.size().width), w)
        let px = drawnPixels(fitted, width: used, wrapped: false, truncation: .none)
        print(pad(label, 12) + pad(String(Int(w)), 6) + pad(String(Int(used)), 6)
              + pad(String(px), 7) + "\"" + fitted.string + "\"" + (px > 0 ? "" : "   ← 空白!"))
    }
}
