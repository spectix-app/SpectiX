import Cocoa

// The 关于 card at the foot of the settings pane: icon, name, version, and the
// three links off this app — the home page, the page that says how to report a
// bug, and the source repo (FSL-1.1-ALv2, source-available).
//
// ⚠️ Both open a browser and that is the ONLY thing they may ever do. This
// app's whole trust story is that it never makes a network call — the home page
// stakes it on four checks a stranger can run (`codesign` shows no network
// entitlement, `otool` shows no network stack linked, `lsof` shows no
// connection, an outbound firewall never prompts). Posting feedback from inside
// the app would link CFNetwork into the binary and break all four at once, and
// that is not a claim you get to walk back once it is made. Bug reports are
// written by hand on the website; here we hand the reader a URL and get out of
// the way.
//
// (Written with // rather than /* */ on purpose: build.sh's no-network gate
// strips line comments before grepping for networking APIs, so a block comment
// naming one trips its own guard.)
final class AboutCard: NSView {

    /// spectix.app went live 2026-08-09 and verify-domain.sh passes against it.
    /// The old taskbeacon.app is the one that no longer resolves — it was never
    /// pointed anywhere after the rename — so leaving these on it is what breaks
    /// the buttons, not the other way round.
    static let siteURL = "https://spectix.app"

    /// The bug-report page rather than a mailto: — the address can then change
    /// without shipping a new build, and the page gets to say which details make
    /// a report actionable before the reader starts typing.
    /// Trailing slash on purpose: Pages 308s /feedback to /feedback/, and the
    /// button may as well land on the page instead of on a redirect.
    static let feedbackURL = "https://spectix.app/feedback/"

    static let sourceURL = "https://github.com/spectix-app/SpectiX"

    /// What Info.plist says, never a literal -- build.sh injects it, so a
    /// hardcoded copy here would quietly disagree with the About box the moment
    /// the version is bumped.
    static var version: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "—"
    }

    private let linkBtn = NSButton()
    private let bugBtn = NSButton()
    private let sourceBtn = NSButton()

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        build()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        // Glass background (GlassCard is final — embed rather than subclass).
        let bg = GlassCard(radius: Theme.card, glows: false)
        bg.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bg)
        NSLayoutConstraint.activate([
            bg.topAnchor.constraint(equalTo: topAnchor),
            bg.bottomAnchor.constraint(equalTo: bottomAnchor),
            bg.leadingAnchor.constraint(equalTo: leadingAnchor),
            bg.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        // The running app's own icon — one source (tools/AppIcon.png), so this
        // cannot drift from what the Dock shows. See docs/logo.md.
        let icon = NSImageView()
        icon.image = NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)

        let name = NSTextField(labelWithString: "SpectiX")
        name.font = Theme.rounded(14, .semibold)
        name.textColor = .labelColor
        name.translatesAutoresizingMaskIntoConstraints = false
        addSubview(name)

        let version = NSTextField(labelWithString: L("版本 ", "Version ") + Self.version)
        version.font = Theme.font(11.5, .regular)
        version.textColor = .secondaryLabelColor
        version.translatesAutoresizingMaskIntoConstraints = false
        addSubview(version)

        // Sits on the version line rather than with the two links below: it is a
        // fact about this build (FSL-1.1, here is its source), not an ask.
        sourceBtn.isBordered = false
        sourceBtn.attributedTitle = NSAttributedString(
            string: "FSL-1.1 · " + L("源代码 →", "Source code →"),
            attributes: [.foregroundColor: NSColor.secondaryLabelColor,
                         .font: Theme.font(11.5, .regular)])
        sourceBtn.setContentHuggingPriority(.required, for: .horizontal)
        sourceBtn.translatesAutoresizingMaskIntoConstraints = false
        sourceBtn.target = self
        sourceBtn.action = #selector(openSource)
        addSubview(sourceBtn)

        // Asks for the 👍 and for the complaint in one breath: the site's box is
        // 👍/👎 plus an optional line, and a thumbs-down with a sentence is worth
        // far more than a thumbs-up without one.
        let pitch = WrappingLabel.make(
            L("如果 SpectiX 帮到你了，去官网点个赞支持一下 —— 用不顺的地方也欢迎在那里说一句。",
              "If SpectiX helps, leave a 👍 on the site — and if something doesn't work, say so there."))
        pitch.font = Theme.font(11.5, .regular)
        pitch.textColor = .secondaryLabelColor
        pitch.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pitch)

        linkBtn.isBordered = false
        linkBtn.attributedTitle = NSAttributedString(
            string: "spectix.app →",
            attributes: [.foregroundColor: NSColor.controlAccentColor,
                         .font: Theme.font(12.5, .semibold)])
        linkBtn.setContentHuggingPriority(.required, for: .horizontal)
        linkBtn.translatesAutoresizingMaskIntoConstraints = false
        linkBtn.target = self
        linkBtn.action = #selector(openSite)
        addSubview(linkBtn)

        // Secondary weight on purpose: the site link is the ask (leave a 👍),
        // this one is the escape hatch you only want when something is wrong.
        bugBtn.isBordered = false
        bugBtn.attributedTitle = NSAttributedString(
            string: L("报告问题 →", "Report a bug →"),
            attributes: [.foregroundColor: NSColor.secondaryLabelColor,
                         .font: Theme.font(12.5, .regular)])
        bugBtn.setContentHuggingPriority(.required, for: .horizontal)
        bugBtn.translatesAutoresizingMaskIntoConstraints = false
        bugBtn.target = self
        bugBtn.action = #selector(openFeedback)
        addSubview(bugBtn)

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.inset),
            icon.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            icon.widthAnchor.constraint(equalToConstant: 40),
            icon.heightAnchor.constraint(equalToConstant: 40),

            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            name.topAnchor.constraint(equalTo: icon.topAnchor, constant: 1),

            version.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            version.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 3),

            sourceBtn.leadingAnchor.constraint(equalTo: version.trailingAnchor, constant: 10),
            sourceBtn.firstBaselineAnchor.constraint(equalTo: version.firstBaselineAnchor),
            sourceBtn.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Theme.inset),

            pitch.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.inset),
            pitch.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.inset),
            pitch.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 12),

            linkBtn.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.inset),
            linkBtn.topAnchor.constraint(equalTo: pitch.bottomAnchor, constant: 8),
            linkBtn.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),

            bugBtn.leadingAnchor.constraint(equalTo: linkBtn.trailingAnchor, constant: 16),
            bugBtn.firstBaselineAnchor.constraint(equalTo: linkBtn.firstBaselineAnchor),
        ])
    }

    /// A pointing-hand over the links, so they read as clickable before they are
    /// clicked.
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(linkBtn.frame, cursor: .pointingHand)
        addCursorRect(bugBtn.frame, cursor: .pointingHand)
        addCursorRect(sourceBtn.frame, cursor: .pointingHand)
    }

    @objc private func openSite() {
        open(Self.siteURL)
    }

    @objc private func openFeedback() {
        open(Self.feedbackURL)
    }

    @objc private func openSource() {
        open(Self.sourceURL)
    }

    private func open(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }
}
