import Cocoa

// MARK: - Emoji catalog
//
// A compact, categorized emoji set for the project-header icon picker. Each entry
// carries space-separated search keywords (English + a little Chinese) so the
// picker's search box can filter without a giant Unicode name table. The catalog
// is intentionally curated (not exhaustive) — enough variety to make a project
// recognizable at a glance, small enough to render instantly.
enum EmojiCatalog {

    struct Category {
        let symbol: String       // the tab/jump-bar glyph
        let name: String         // section title
        let entries: [(String, String)]   // (emoji, keywords)
        var emojis: [String] { entries.map(\.0) }
    }

    static let categories: [Category] = [
        Category(symbol: "😀", name: L("表情", "Smileys"), entries: [
            ("😀", "grin happy smile"), ("😃", "happy smile open"), ("😄", "happy joy smile"),
            ("😁", "grin beam"), ("😆", "laugh haha"), ("😅", "sweat laugh nervous"),
            ("🤣", "rofl rolling laugh"), ("😂", "joy laugh tears"), ("🙂", "slight smile"),
            ("🙃", "upside down silly"), ("😉", "wink"), ("😊", "blush smile"),
            ("😇", "angel halo innocent"), ("🥰", "love hearts adore"), ("😍", "love heart eyes"),
            ("🤩", "star struck wow"), ("😘", "kiss blow"), ("😗", "kiss"),
            ("😋", "yum tasty tongue"), ("😛", "tongue playful"), ("🤪", "zany goofy crazy"),
            ("😜", "wink tongue"), ("🤗", "hug"), ("🤭", "giggle oops hand"),
            ("🤫", "shush quiet secret"), ("🤔", "think hmm"), ("🤨", "raised eyebrow doubt"),
            ("😐", "neutral meh"), ("😑", "expressionless blank"), ("😶", "no mouth silent"),
            ("🙄", "eye roll"), ("😏", "smirk sly"), ("😬", "grimace awkward"),
            ("😌", "relieved calm"), ("😔", "sad pensive"), ("😪", "sleepy"),
            ("😴", "sleep zzz tired"), ("😷", "mask sick"), ("🤒", "sick fever thermometer"),
            ("🤢", "nausea sick gross"), ("🥵", "hot heat sweat"), ("🥶", "cold freeze"),
            ("😵", "dizzy knocked out"), ("🤯", "mind blown explode"), ("🥳", "party celebrate"),
            ("🥺", "pleading puppy eyes"), ("😢", "cry sad tear"), ("😭", "sob crying loud"),
            ("😤", "huff frustrated steam"), ("😠", "angry mad"), ("😡", "rage furious red"),
            ("🤬", "swear censored curse"), ("😱", "scream shock fear"), ("😨", "fearful scared"),
            ("😰", "anxious sweat worried"), ("😳", "flushed embarrassed"), ("🤥", "lying pinocchio"),
            ("😈", "devil smiling mischief"), ("👿", "imp angry devil"), ("💀", "skull dead"),
            ("💩", "poop"), ("🤡", "clown"), ("👻", "ghost boo"),
            ("👽", "alien ufo"), ("🤖", "robot bot ai"), ("🎃", "pumpkin halloween jack"),
        ]),
        Category(symbol: "👋", name: L("人物", "People"), entries: [
            ("👋", "wave hi hello bye"), ("🤚", "raised back hand"), ("✋", "stop high five"),
            ("🖐️", "hand fingers"), ("👌", "ok perfect"), ("🤌", "pinch italian"),
            ("🤏", "small pinch tiny"), ("✌️", "peace victory"), ("🤞", "fingers crossed luck"),
            ("🤟", "love you hand"), ("🤘", "rock horns"), ("🤙", "call me shaka"),
            ("👈", "point left"), ("👉", "point right"), ("👆", "point up"),
            ("👇", "point down"), ("☝️", "index up one"), ("👍", "thumbs up like yes good"),
            ("👎", "thumbs down dislike no"), ("✊", "fist raised"), ("👊", "fist bump punch"),
            ("👏", "clap applause"), ("🙌", "raise hands celebrate"), ("👐", "open hands"),
            ("🤲", "palms up pray"), ("🤝", "handshake deal"), ("🙏", "pray thanks please"),
            ("✍️", "writing hand"), ("💅", "nail polish"), ("💪", "muscle strong flex"),
            ("🧠", "brain smart mind"), ("👀", "eyes look watch"), ("👁️", "eye"),
            ("👶", "baby"), ("🧑", "person adult"), ("👨", "man"),
            ("👩", "woman"), ("🧓", "old elder"), ("👮", "police cop"),
            ("🕵️", "detective spy"), ("👷", "worker construction"), ("🧑‍💻", "developer coder tech"),
            ("🧑‍🚀", "astronaut space"), ("🦸", "superhero"), ("🧙", "wizard mage"),
            ("🧑‍🎨", "artist"), ("👑", "crown king queen royal"), ("🤴", "prince"),
            ("👸", "princess"), ("🎅", "santa christmas"), ("🦹", "villain supervillain"),
        ]),
        Category(symbol: "🐱", name: L("动物", "Animals"), entries: [
            ("🐶", "dog puppy"), ("🐱", "cat kitten"), ("🐭", "mouse"), ("🐹", "hamster"),
            ("🐰", "rabbit bunny"), ("🦊", "fox"), ("🐻", "bear"), ("🐼", "panda"),
            ("🐻‍❄️", "polar bear"), ("🐨", "koala"), ("🐯", "tiger"), ("🦁", "lion"),
            ("🐮", "cow"), ("🐷", "pig"), ("🐸", "frog"), ("🐵", "monkey"),
            ("🐔", "chicken"), ("🐧", "penguin"), ("🐦", "bird"), ("🐤", "chick baby bird"),
            ("🦆", "duck"), ("🦅", "eagle bird"), ("🦉", "owl wise night"), ("🦇", "bat"),
            ("🐺", "wolf"), ("🐗", "boar"), ("🐴", "horse"), ("🦄", "unicorn magic"),
            ("🐝", "bee"), ("🐛", "caterpillar bug"), ("🦋", "butterfly"), ("🐌", "snail slow"),
            ("🐞", "ladybug bug"), ("🐜", "ant"), ("🕷️", "spider"), ("🦂", "scorpion"),
            ("🐢", "turtle slow"), ("🐍", "snake"), ("🦎", "lizard gecko"), ("🦖", "dino trex"),
            ("🐙", "octopus"), ("🦑", "squid"), ("🦐", "shrimp"), ("🦀", "crab"),
            ("🐡", "blowfish"), ("🐠", "tropical fish"), ("🐟", "fish"), ("🐬", "dolphin"),
            ("🐳", "whale"), ("🦈", "shark"), ("🐊", "crocodile"), ("🐘", "elephant"),
            ("🦏", "rhino"), ("🦛", "hippo"), ("🐫", "camel"), ("🦒", "giraffe"),
            ("🦘", "kangaroo"), ("🐑", "sheep"), ("🐐", "goat"), ("🦌", "deer"),
            ("🐉", "dragon"), ("🦕", "dino brontosaurus"), ("🦩", "flamingo"), ("🦚", "peacock"),
            ("🐾", "paw prints"), ("🦭", "seal"),
        ]),
        Category(symbol: "🍕", name: L("食物", "Food"), entries: [
            ("🍏", "green apple"), ("🍎", "apple"), ("🍐", "pear"), ("🍊", "orange tangerine"),
            ("🍋", "lemon"), ("🍌", "banana"), ("🍉", "watermelon"), ("🍇", "grapes"),
            ("🍓", "strawberry"), ("🫐", "blueberries"), ("🍒", "cherries"), ("🍑", "peach"),
            ("🥭", "mango"), ("🍍", "pineapple"), ("🥥", "coconut"), ("🥝", "kiwi"),
            ("🍅", "tomato"), ("🥑", "avocado"), ("🍆", "eggplant"), ("🌶️", "chili spicy pepper"),
            ("🌽", "corn"), ("🥕", "carrot"), ("🧄", "garlic"), ("🥦", "broccoli"),
            ("🍄", "mushroom"), ("🥜", "peanut nut"), ("🍞", "bread"), ("🥐", "croissant"),
            ("🥖", "baguette"), ("🥨", "pretzel"), ("🧀", "cheese"), ("🥚", "egg"),
            ("🍳", "fried egg cooking"), ("🥞", "pancakes"), ("🧇", "waffle"), ("🥓", "bacon"),
            ("🍔", "burger"), ("🍟", "fries"), ("🍕", "pizza"), ("🌭", "hotdog"),
            ("🥪", "sandwich"), ("🌮", "taco"), ("🌯", "burrito"), ("🥗", "salad"),
            ("🍜", "ramen noodles"), ("🍝", "spaghetti pasta"), ("🍣", "sushi"), ("🍱", "bento"),
            ("🍚", "rice"), ("🍙", "rice ball"), ("🍤", "shrimp tempura"), ("🥟", "dumpling"),
            ("🍦", "soft serve ice cream"), ("🍩", "donut"), ("🍪", "cookie"), ("🎂", "cake birthday"),
            ("🧁", "cupcake"), ("🍰", "cake slice"), ("🍫", "chocolate"), ("🍬", "candy"),
            ("🍭", "lollipop"), ("🍯", "honey"), ("☕", "coffee tea"), ("🍵", "tea matcha"),
            ("🧋", "boba bubble tea"), ("🥤", "soda cup drink"), ("🧃", "juice box"), ("🍺", "beer"),
            ("🍻", "cheers beers"), ("🍷", "wine"), ("🍸", "cocktail martini"), ("🥂", "champagne toast"),
            ("🍾", "champagne bottle"), ("🧊", "ice cube"),
        ]),
        Category(symbol: "⚽", name: L("活动", "Activities"), entries: [
            ("⚽", "soccer football"), ("🏀", "basketball"), ("🏈", "american football"),
            ("⚾", "baseball"), ("🎾", "tennis"), ("🏐", "volleyball"),
            ("🏉", "rugby"), ("🎱", "billiards pool 8ball"), ("🏓", "ping pong table tennis"),
            ("🏸", "badminton"), ("🥅", "goal net"), ("🏒", "hockey"),
            ("🏑", "field hockey"), ("🥍", "lacrosse"), ("🏏", "cricket"),
            ("🥊", "boxing glove"), ("🥋", "martial arts karate"), ("⛳", "golf flag"),
            ("⛸️", "ice skate"), ("🎿", "ski"), ("🛹", "skateboard"),
            ("🏂", "snowboard"), ("🏋️", "weightlifting gym"), ("🤸", "cartwheel gymnastics"),
            ("🤺", "fencing"), ("🏇", "horse racing"), ("🧗", "climbing"),
            ("🚴", "cycling bike"), ("🏊", "swimming"), ("🏄", "surfing"),
            ("🚣", "rowing"), ("🤾", "handball"), ("🏌️", "golfing"),
            ("🎯", "target goal dart bullseye"), ("🎳", "bowling"), ("🎮", "game controller gaming"),
            ("🕹️", "joystick arcade"), ("🎲", "dice random"), ("♟️", "chess pawn"),
            ("🧩", "puzzle piece"), ("🎰", "slot machine"), ("🎨", "art paint design"),
            ("🎭", "theater drama masks"), ("🎬", "movie clapper film"), ("🎤", "mic sing karaoke"),
            ("🎧", "headphones music"), ("🎸", "guitar"), ("🎹", "piano keyboard"),
            ("🥁", "drum"), ("🎺", "trumpet"), ("🎻", "violin"),
            ("🎼", "music score"), ("🎵", "music note"), ("🎶", "music notes"),
            ("🏆", "trophy win award"), ("🏅", "medal"), ("🥇", "gold first"),
            ("🥈", "silver second"), ("🥉", "bronze third"), ("🎖️", "military medal"),
            ("🎗️", "ribbon awareness"), ("🎫", "ticket"), ("🎟️", "admission tickets"),
        ]),
        Category(symbol: "✈️", name: L("旅行", "Travel"), entries: [
            ("🚗", "car"), ("🚕", "taxi"), ("🚙", "suv"), ("🚌", "bus"),
            ("🏎️", "race car fast"), ("🚓", "police car"), ("🚑", "ambulance"), ("🚒", "fire truck"),
            ("🚚", "truck"), ("🚛", "semi lorry"), ("🚜", "tractor"), ("🏍️", "motorcycle"),
            ("🛵", "scooter moped"), ("🚲", "bicycle bike"), ("🛴", "kick scooter"), ("🚨", "siren alert"),
            ("🚔", "police light"), ("🚄", "bullet train"), ("🚅", "high speed train"), ("🚈", "metro"),
            ("🚂", "steam train locomotive"), ("🚝", "monorail"), ("🚁", "helicopter"), ("✈️", "airplane flight"),
            ("🛫", "takeoff departure"), ("🛬", "landing arrival"), ("🚀", "rocket launch ship fast"), ("🛸", "ufo flying saucer"),
            ("🚤", "speedboat"), ("⛵", "sailboat"), ("🛥️", "motor boat"), ("🚢", "ship cruise"),
            ("⚓", "anchor"), ("⛽", "fuel gas station"), ("🚦", "traffic light"), ("🗺️", "map"),
            ("🧭", "compass"), ("🗿", "moai statue"), ("🗽", "statue liberty"), ("🗼", "tower tokyo"),
            ("🏰", "castle"), ("🏯", "japanese castle"), ("🎡", "ferris wheel"), ("🎢", "roller coaster"),
            ("🎠", "carousel"), ("⛲", "fountain"), ("⛱️", "beach umbrella"), ("🏖️", "beach"),
            ("🏝️", "island"), ("🏔️", "mountain snow"), ("🗻", "mount fuji"), ("🌋", "volcano"),
            ("🏕️", "camping tent"), ("⛺", "tent"), ("🏠", "house home"), ("🏡", "house garden"),
            ("🏢", "office building"), ("🏬", "department store"), ("🏥", "hospital"), ("🏦", "bank"),
            ("🏨", "hotel"), ("🏫", "school"), ("⛪", "church"), ("🕌", "mosque"),
            ("🌆", "city dusk"), ("🌃", "night city"), ("🌉", "bridge night"), ("🎑", "moon ceremony"),
        ]),
        Category(symbol: "💡", name: L("物品", "Objects"), entries: [
            ("💡", "idea bulb light"), ("🔥", "fire hot flame lit"), ("⚡", "bolt fast power energy"),
            ("⭐", "star fav"), ("✨", "sparkles new shiny"), ("💥", "boom collision"),
            ("🎯", "target goal dart"), ("🚀", "rocket launch fast"), ("💎", "diamond gem premium"),
            ("👑", "crown royal"), ("🏆", "trophy win award"), ("🎁", "gift present"),
            ("🎈", "balloon party"), ("🎉", "tada party celebrate"), ("🎊", "confetti"),
            ("🔔", "bell notify alert"), ("📢", "megaphone announce loud"), ("📣", "cheer megaphone"),
            ("💰", "money bag cash"), ("💵", "dollar money"), ("💳", "credit card pay"),
            ("🪙", "coin"), ("📈", "chart up growth stonks"), ("📉", "chart down loss"),
            ("📊", "bar chart stats"), ("📋", "clipboard"), ("📌", "pin"),
            ("📎", "clip paperclip attach"), ("🔗", "link chain url"), ("📁", "folder file dir"),
            ("📂", "open folder"), ("🗂️", "dividers organize"), ("📦", "box package deliver"),
            ("📝", "memo note write"), ("✏️", "pencil edit write"), ("🖊️", "pen write"),
            ("🖌️", "paintbrush"), ("🖍️", "crayon"), ("📚", "books library"),
            ("📖", "book open read"), ("🔖", "bookmark"), ("📰", "newspaper news"),
            ("💻", "laptop computer code dev"), ("🖥️", "desktop monitor"), ("⌨️", "keyboard type"),
            ("🖱️", "mouse click"), ("💾", "floppy save disk"), ("💿", "cd disc"),
            ("📀", "dvd disc"), ("📱", "phone mobile app"), ("☎️", "telephone call"),
            ("📷", "camera photo"), ("📹", "video camera record"), ("🎥", "movie camera film"),
            ("🔋", "battery power"), ("🔌", "plug power"), ("🔦", "flashlight torch"),
            ("🕯️", "candle"), ("🧯", "extinguisher"), ("🛠️", "tools"),
            ("🔧", "wrench tool fix"), ("🔨", "hammer build"), ("⚙️", "gear settings config"),
            ("🪛", "screwdriver"), ("🧰", "toolbox"), ("🧲", "magnet"),
            ("🧪", "test tube lab experiment"), ("🧫", "petri dish bio"), ("🔬", "microscope science research"),
            ("🔭", "telescope"), ("🛰️", "satellite"), ("💊", "pill medicine"),
            ("🩺", "stethoscope"), ("🔑", "key access auth"), ("🗝️", "old key"),
            ("🔒", "lock secure private"), ("🔓", "unlock open"), ("🛡️", "shield protect security"),
            ("⚔️", "swords fight"), ("🏴‍☠️", "pirate flag skull"), ("🧭", "compass direction"),
            ("⏰", "alarm clock time"), ("⌛", "hourglass time"), ("⏳", "hourglass running"),
            ("💣", "bomb"), ("🧨", "firecracker dynamite"), ("🎏", "carp streamer"),
        ]),
        Category(symbol: "✅", name: L("符号", "Symbols"), entries: [
            ("✅", "check done ok green"), ("☑️", "checkbox checked"), ("✔️", "check mark tick"),
            ("❌", "cross no error red"), ("❎", "cross mark button"), ("⭕", "circle o"),
            ("‼️", "double exclamation"), ("⁉️", "exclamation question"), ("❓", "question mark"),
            ("❗", "exclamation"), ("⚠️", "warning caution"), ("🚫", "prohibited no ban"),
            ("🔞", "no under 18"), ("💯", "hundred perfect"), ("🔥", "fire lit"),
            ("💤", "zzz sleep"), ("💢", "anger mad"), ("♻️", "recycle"),
            ("✳️", "asterisk sparkle"), ("❇️", "sparkle"), ("♾️", "infinity loop"),
            ("➕", "plus add"), ("➖", "minus subtract"), ("➗", "divide"),
            ("✖️", "multiply times"), ("🟰", "equals"), ("💲", "dollar sign"),
            ("🔴", "red circle dot"), ("🟠", "orange circle"), ("🟡", "yellow circle"),
            ("🟢", "green circle ok"), ("🔵", "blue circle"), ("🟣", "purple circle"),
            ("🟤", "brown circle"), ("⚫", "black circle"), ("⚪", "white circle"),
            ("🟥", "red square"), ("🟧", "orange square"), ("🟨", "yellow square"),
            ("🟩", "green square"), ("🟦", "blue square"), ("🟪", "purple square"),
            ("⬛", "black square"), ("⬜", "white square"), ("🔶", "orange diamond"),
            ("🔷", "blue diamond"), ("🔺", "red triangle up"), ("🔻", "red triangle down"),
            ("❤️", "heart love red"), ("🧡", "orange heart"), ("💛", "yellow heart"),
            ("💚", "green heart"), ("💙", "blue heart"), ("💜", "purple heart"),
            ("🖤", "black heart"), ("🤍", "white heart"), ("🤎", "brown heart"),
            ("💔", "broken heart"), ("❤️‍🔥", "heart on fire"), ("💕", "two hearts"),
            ("💗", "growing heart"), ("💖", "sparkle heart"), ("⭐", "star"),
            ("🌟", "glowing star"), ("💫", "dizzy sparkle"), ("🔆", "bright brightness"),
        ]),
        Category(symbol: "🌈", name: L("自然", "Nature"), entries: [
            ("🌈", "rainbow"), ("☀️", "sun sunny"), ("🌤️", "sun cloud"), ("⛅", "partly cloudy"),
            ("☁️", "cloud"), ("🌥️", "cloudy"), ("🌦️", "sun rain shower"), ("🌧️", "rain"),
            ("⛈️", "storm thunder"), ("🌩️", "lightning"), ("🌨️", "snow cloud"), ("❄️", "snow cold winter"),
            ("☃️", "snowman"), ("⛄", "snowman no snow"), ("🌬️", "wind blow"), ("💨", "dash wind fast"),
            ("🌪️", "tornado"), ("🌫️", "fog"), ("🌊", "wave ocean water"), ("💧", "droplet water"),
            ("💦", "sweat splash"), ("🔥", "fire flame"), ("🌙", "moon night"), ("🌕", "full moon"),
            ("🌗", "moon quarter"), ("🌑", "new moon dark"), ("🌛", "moon face"), ("⭐", "star"),
            ("🌟", "glowing star"), ("🌠", "shooting star wish"), ("🌌", "galaxy milky way stars"), ("🪐", "planet saturn space"),
            ("🌍", "earth globe world europe"), ("🌎", "earth americas"), ("🌏", "earth asia"), ("☄️", "comet"),
            ("🌸", "cherry blossom pink"), ("🌺", "hibiscus flower"), ("🌻", "sunflower"), ("🌷", "tulip"),
            ("🌹", "rose"), ("🥀", "wilted flower"), ("🌼", "daisy blossom"), ("💐", "bouquet flowers"),
            ("🍀", "clover luck four leaf"), ("🍃", "leaves wind"), ("🍂", "fallen leaves autumn"), ("🍁", "maple leaf"),
            ("🌿", "herb plant"), ("🌱", "seedling sprout grow"), ("🌵", "cactus"), ("🌴", "palm tree beach"),
            ("🌳", "tree deciduous"), ("🌲", "tree pine evergreen"), ("🎋", "bamboo tanabata"), ("🎍", "pine decoration"),
            ("🍄", "mushroom"), ("🪷", "lotus"), ("🐚", "shell seashell"), ("⛰️", "mountain"),
        ]),
        Category(symbol: "🚩", name: L("旗帜", "Flags"), entries: [
            ("🏁", "checkered finish race"), ("🚩", "flag red triangular"), ("🏳️", "white flag"),
            ("🏴", "black flag"), ("🏳️‍🌈", "rainbow pride flag lgbt"), ("🏳️‍⚧️", "trans flag"),
            ("🏴‍☠️", "pirate flag skull"), ("🎌", "crossed flags"), ("🇨🇳", "china cn"),
            ("🇺🇸", "usa us america united states"), ("🇯🇵", "japan jp"), ("🇰🇷", "korea kr south"),
            ("🇬🇧", "uk britain united kingdom"), ("🇩🇪", "germany de"), ("🇫🇷", "france fr"),
            ("🇮🇹", "italy it"), ("🇪🇸", "spain es"), ("🇵🇹", "portugal pt"),
            ("🇳🇱", "netherlands nl"), ("🇷🇺", "russia ru"), ("🇨🇦", "canada ca"),
            ("🇧🇷", "brazil br"), ("🇲🇽", "mexico mx"), ("🇦🇷", "argentina ar"),
            ("🇮🇳", "india in"), ("🇦🇺", "australia au"), ("🇳🇿", "new zealand nz"),
            ("🇸🇬", "singapore sg"), ("🇭🇰", "hong kong hk"), ("🇹🇼", "taiwan tw"),
            ("🇹🇭", "thailand th"), ("🇻🇳", "vietnam vn"), ("🇮🇩", "indonesia id"),
            ("🇵🇭", "philippines ph"), ("🇲🇾", "malaysia my"), ("🇦🇪", "uae dubai emirates"),
            ("🇸🇦", "saudi arabia sa"), ("🇹🇷", "turkey tr"), ("🇪🇬", "egypt eg"),
            ("🇿🇦", "south africa za"), ("🇸🇪", "sweden se"), ("🇳🇴", "norway no"),
            ("🇩🇰", "denmark dk"), ("🇫🇮", "finland fi"), ("🇨🇭", "switzerland ch"),
            ("🇮🇪", "ireland ie"), ("🇵🇱", "poland pl"), ("🇺🇦", "ukraine ua"),
        ]),
    ]

    static let all: [String] = categories.flatMap(\.emojis)

    // Emojis whose keywords contain every whitespace-split token of `query`.
    static func search(_ query: String) -> [String] {
        let tokens = query.lowercased().split(separator: " ").map(String.init)
        guard !tokens.isEmpty else { return all }
        var out: [String] = []
        for c in categories {
            for (emoji, kw) in c.entries {
                let hay = kw.lowercased()
                if tokens.allSatisfy({ hay.contains($0) }) { out.append(emoji) }
            }
        }
        // De-dup while preserving order (an emoji can only live in one category, but
        // guard anyway).
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }
    }
}

// MARK: - Emoji cell (one tappable glyph with a hover wash)

private final class EmojiCell: NSView {
    private let emoji: String
    var onPick: ((String) -> Void)?
    private let field = NSTextField(labelWithString: "")

    init(emoji: String) {
        self.emoji = emoji
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        field.stringValue = emoji
        field.font = .systemFont(ofSize: 19)
        field.alignment = .center
        field.isBezeled = false
        field.drawsBackground = false
        field.isEditable = false
        field.isSelectable = false
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        NSLayoutConstraint.activate([
            field.centerXAnchor.constraint(equalTo: centerXAnchor),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = NSColor(white: 1, alpha: 0.14).cgColor
    }
    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = NSColor.clear.cgColor
    }
    override func mouseDown(with event: NSEvent) {}   // swallow so the click is a pick, not a drag
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onPick?(emoji) }
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

// MARK: - Emoji grid (flipped; sections with titles, jump-to-section support)

private final class EmojiGridView: NSView {
    override var isFlipped: Bool { true }
    var onPick: ((String) -> Void)?

    private let cols = 7
    private let cell: CGFloat = 34
    private let pad: CGFloat = 8
    private let secHeaderH: CGFloat = 22

    // name -> top y of that section (for the jump bar)
    private(set) var sectionOffsets: [String: CGFloat] = [:]

    struct Section { let name: String; let emojis: [String] }

    // Lay out the given sections at `width`, return the total content height.
    @discardableResult
    func reload(_ sections: [Section], width: CGFloat) -> CGFloat {
        subviews.forEach { $0.removeFromSuperview() }
        sectionOffsets.removeAll()

        let cellW = ((width - pad * 2) / CGFloat(cols)).rounded(.down)
        var y = pad
        for sec in sections where !sec.emojis.isEmpty {
            sectionOffsets[sec.name] = y
            let header = NSTextField(labelWithString: sec.name.uppercased())
            header.font = Theme.rounded(10.5, .bold)
            header.textColor = .tertiaryLabelColor
            header.frame = NSRect(x: pad + 2, y: y + 2, width: width - pad * 2, height: secHeaderH - 4)
            addSubview(header)
            y += secHeaderH

            for (i, e) in sec.emojis.enumerated() {
                let r = i / cols, c = i % cols
                let cv = EmojiCell(emoji: e)
                cv.onPick = { [weak self] in self?.onPick?($0) }
                cv.frame = NSRect(x: pad + CGFloat(c) * cellW, y: y + CGFloat(r) * cell,
                                  width: cellW, height: cell)
                addSubview(cv)
            }
            let rows = (sec.emojis.count + cols - 1) / cols
            y += CGFloat(rows) * cell + 6
        }
        y += pad
        frame = NSRect(x: 0, y: 0, width: width, height: max(y, 1))
        return y
    }
}

// MARK: - Emoji icon picker (hosted in an NSPopover)

final class EmojiIconPicker: NSViewController {

    // Selected an emoji → apply + persist. Upload → hand off to the host's file picker
    // (the panel closes first). Remove → clear the custom icon.
    var onPick: ((String) -> Void)?
    var onUpload: (() -> Void)?
    var onRemove: (() -> Void)?

    static let contentSize = NSSize(width: 300, height: 384)
    private var contentW: CGFloat { Self.contentSize.width }
    private var contentH: CGFloat { Self.contentSize.height }

    private let search = NSSearchField()
    private let catBar = NSStackView()
    private let scroll = NSScrollView()
    private let grid = EmojiGridView()

    override func loadView() {
        let root = FlippedView(frame: NSRect(x: 0, y: 0, width: contentW, height: contentH))

        // ── Search ──
        search.placeholderString = L("搜索 emoji…", "Search emoji…")
        search.frame = NSRect(x: 10, y: 10, width: contentW - 20, height: 26)
        search.autoresizingMask = [.width]
        search.focusRingType = .none
        search.target = self
        search.action = #selector(searchChanged)
        (search.cell as? NSSearchFieldCell)?.sendsSearchStringImmediately = true
        root.addSubview(search)

        // ── Category jump bar ──
        catBar.orientation = .horizontal
        catBar.spacing = 2
        catBar.frame = NSRect(x: 8, y: 44, width: contentW - 16, height: 28)
        catBar.autoresizingMask = [.width]
        for c in EmojiCatalog.categories {
            let b = NSButton(title: c.symbol, target: self, action: #selector(jumpToCategory(_:)))
            b.isBordered = false
            b.font = .systemFont(ofSize: 15)
            b.toolTip = c.name
            b.identifier = NSUserInterfaceItemIdentifier(c.name)
            b.setButtonType(.momentaryChange)
            catBar.addArrangedSubview(b)
        }
        root.addSubview(catBar)

        // hairline under the category bar
        let hair = FlippedView(frame: NSRect(x: 0, y: 78, width: contentW, height: 1))
        hair.wantsLayer = true
        hair.layer?.backgroundColor = Theme.hairline.cgColor
        hair.autoresizingMask = [.width]
        root.addSubview(hair)

        // ── Grid ──
        scroll.frame = NSRect(x: 4, y: 82, width: contentW - 8, height: contentH - 82 - 48)
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        grid.onPick = { [weak self] in self?.pick($0) }
        scroll.documentView = grid
        root.addSubview(scroll)

        // ── Footer: 随机 / 上传图片 / 移除自定义 ──
        let footHair = FlippedView(frame: NSRect(x: 0, y: contentH - 48, width: contentW, height: 1))
        footHair.wantsLayer = true
        footHair.layer?.backgroundColor = Theme.hairline.cgColor
        footHair.autoresizingMask = [.width, .minYMargin]
        root.addSubview(footHair)

        let random = makeFooterButton(L("🎲 随机", "🎲 Random"), #selector(randomTapped))
        random.frame = NSRect(x: 10, y: contentH - 38, width: 84, height: 28)
        random.autoresizingMask = [.minYMargin]
        root.addSubview(random)

        // Second way in to an uploaded icon (the header badge's right-click menu is the
        // other): once the picker is open, making the user close it and re-right-click
        // just to reach the file dialog would be silly.
        let upload = makeFooterButton(L("🖼 上传", "🖼 Upload"), #selector(uploadTapped))
        upload.frame = NSRect(x: 100, y: contentH - 38, width: 84, height: 28)
        upload.autoresizingMask = [.minYMargin]
        root.addSubview(upload)

        let remove = makeFooterButton(L("移除自定义", "Remove"), #selector(removeTapped))
        remove.contentTintColor = NSColor.systemRed
        remove.sizeToFit()
        let rw = max(remove.frame.width + 22, 92)
        remove.frame = NSRect(x: contentW - rw - 10, y: contentH - 38, width: rw, height: 28)
        remove.autoresizingMask = [.minXMargin, .minYMargin]
        root.addSubview(remove)

        self.view = root
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        reloadGrid(search.stringValue)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        reloadGrid(search.stringValue)
        view.window?.makeFirstResponder(search)
    }

    // MARK: Grid

    private func reloadGrid(_ query: String) {
        let width = scroll.contentSize.width
        guard width > 1 else { return }
        let q = query.trimmingCharacters(in: .whitespaces)
        var sections: [EmojiGridView.Section] = []
        if q.isEmpty {
            let recent = AppSettings.recentEmojis
            if !recent.isEmpty { sections.append(.init(name: L("最近", "Recent"), emojis: recent)) }
            sections += EmojiCatalog.categories.map { .init(name: $0.name, emojis: $0.emojis) }
        } else {
            sections = [.init(name: L("结果", "Results"), emojis: EmojiCatalog.search(q))]
        }
        grid.reload(sections, width: width)
    }

    @objc private func searchChanged() { reloadGrid(search.stringValue) }

    @objc private func jumpToCategory(_ sender: NSButton) {
        guard search.stringValue.trimmingCharacters(in: .whitespaces).isEmpty,
              let name = sender.identifier?.rawValue,
              let y = grid.sectionOffsets[name] else { return }
        // Flipped grid: scroll so the section top sits at the clip view's top.
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    // MARK: Actions

    private func pick(_ emoji: String) {
        AppSettings.noteRecentEmoji(emoji)
        onPick?(emoji)
    }
    @objc private func randomTapped() {
        if let e = EmojiCatalog.all.randomElement() { pick(e) }
    }
    @objc private func uploadTapped() { onUpload?() }
    @objc private func removeTapped() { onRemove?() }

    // MARK: Helpers

    private func makeFooterButton(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        b.font = Theme.font(12, .medium)
        return b
    }
}

// A y-down container so frame math reads top-to-bottom.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - Floating panel presenter
//
// The picker is shown in its own borderless key panel rather than an NSPopover.
// Why: the header badge often lives inside the menu-bar popover (itself
// `.transient`); a child popover anchored to a view in a transient popover makes
// both fight and dismiss (~0.7s flash — the "闪退" bug). A standalone panel is
// positioned by absolute SCREEN coordinates captured up front, so it doesn't care
// that the anchor view (or its parent popover) goes away. It closes on resign-key
// (click outside), Esc, or a pick/remove.
final class EmojiPickerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { close() }   // Esc
}

extension EmojiIconPicker {
    // Retain the live panel + its controller (borderless panels aren't held by a
    // responder chain the way a window controller would be).
    private static var activePanel: EmojiPickerPanel?
    private static var activeController: EmojiIconPicker?
    private static var globalMonitor: Any?
    private static var localMonitor: Any?

    // Show the picker just below `anchorScreenRect` (a badge's frame in screen
    // coords). Clamps onto the screen that contains the anchor.
    static func present(anchorScreenRect: NSRect,
                        onPick: @escaping (String) -> Void,
                        onUpload: @escaping () -> Void,
                        onRemove: @escaping () -> Void) {
        dismiss()

        let picker = EmojiIconPicker()
        let size = contentSize

        // Frosted rounded container hosting the picker's view.
        let container = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        container.material = .popover
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = 12
        container.layer?.cornerCurve = .continuous
        container.layer?.masksToBounds = true
        container.layer?.borderWidth = 1
        container.layer?.borderColor = Theme.hairline.cgColor
        let pv = picker.view
        pv.frame = container.bounds
        pv.autoresizingMask = [.width, .height]
        container.addSubview(pv)

        let panel = EmojiPickerPanel(contentRect: NSRect(origin: .zero, size: size),
                                     styleMask: [.borderless, .nonactivatingPanel],
                                     backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hidesOnDeactivate = false
        panel.contentView = container

        // Position below the badge, then clamp onto the anchor's screen.
        var origin = NSPoint(x: anchorScreenRect.minX, y: anchorScreenRect.minY - size.height - 6)
        let screen = NSScreen.screens.first { $0.frame.intersects(anchorScreenRect) } ?? NSScreen.main
        if let vis = screen?.visibleFrame {
            origin.x = min(max(origin.x, vis.minX + 6), vis.maxX - size.width - 6)
            // If it would clip off the bottom, flip to above the badge.
            if origin.y < vis.minY + 6 { origin.y = anchorScreenRect.maxY + 6 }
            origin.y = min(origin.y, vis.maxY - size.height - 6)
        }
        panel.setFrameOrigin(origin)

        picker.onPick = { emoji in onPick(emoji); dismiss() }
        // Close BEFORE the file dialog opens: this panel dismisses itself on any
        // mouse-down outside it, so leaving it up under a modal open panel would just
        // make it vanish on the first click in there.
        picker.onUpload = { dismiss(); onUpload() }
        picker.onRemove = { onRemove(); dismiss() }

        activePanel = panel
        activeController = picker
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)

        // Dismiss on a click OUTSIDE the panel. Using mouse-down monitors (not
        // resign-key) sidesteps the focus race with the menu-bar popover closing
        // underneath us: a click is an unambiguous "done" signal, a stray key change
        // is not. Global = clicks in other apps; local = clicks elsewhere in ours.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { _ in
            dismiss()
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            if event.window !== activePanel { dismiss() }
            return event
        }
    }

    static func dismiss() {
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
        activePanel?.orderOut(nil)
        activePanel = nil
        activeController = nil
    }
}

// MARK: - Project icon menu (shared by every place a project icon is shown)
//
// The 编辑图标 / 上传图片 / 随机 emoji / 移除自定义 menu plus the actions behind it.
// Two call sites — the folder header badge (SessionListView) and a recent-projects
// row — so it lives here instead of being copied into either view.
final class ProjectIconMenu: NSObject {

    private var cwd = ""
    private var anchorRect = NSRect.zero

    // Build the menu for `cwd`, anchored at `anchor`. The anchor's SCREEN rect is
    // captured here, while the view is still on screen: the picker floats as its own
    // panel and the anchor (or the menu-bar popover holding it) may be gone by the
    // time the action fires.
    func menu(cwd: String, anchor: NSView) -> NSMenu {
        self.cwd = cwd
        if let win = anchor.window {
            anchorRect = win.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        }
        let menu = NSMenu()
        for (title, action) in [(L("编辑图标…", "Edit Icon…"), #selector(editClicked)),
                                (L("上传图片…", "Upload Image…"), #selector(uploadClicked)),
                                (L("随机 emoji", "Random Emoji"), #selector(randomClicked))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let remove = NSMenuItem(title: L("移除自定义", "Remove Custom"),
                                action: #selector(removeClicked), keyEquivalent: "")
        remove.target = self
        remove.isEnabled = AppSettings.customIcon(cwd: cwd) != nil
        menu.addItem(remove)
        return menu
    }

    @objc private func editClicked() {
        let cwd = self.cwd
        guard anchorRect != .zero else { return }
        EmojiIconPicker.present(
            anchorScreenRect: anchorRect,
            onPick: { AppSettings.setCustomIcon($0, cwd: cwd) },
            onUpload: { [weak self] in self?.pickImage(cwd: cwd) },
            onRemove: { AppSettings.removeCustomIcon(cwd: cwd) })
    }

    @objc private func uploadClicked() { pickImage(cwd: cwd) }

    @objc private func randomClicked() {
        guard let e = EmojiCatalog.all.randomElement() else { return }
        AppSettings.noteRecentEmoji(e)
        AppSettings.setCustomIcon(e, cwd: cwd)
    }

    @objc private func removeClicked() { AppSettings.removeCustomIcon(cwd: cwd) }

    // Ask for an image file and make it the project's badge. Modal rather than a sheet:
    // the header often lives in the menu-bar popover, which has no window worth
    // attaching to (and closes the moment focus moves).
    private func pickImage(cwd: String) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = L("使用", "Use")
        panel.message = L("选一张图片作为项目图标", "Choose an image for this project's icon")
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // Anything NSImage can't decode (a corrupt file wearing an image extension)
        // just beeps — there's nothing to fall back to and nothing was changed.
        guard let file = AppSettings.importIconImage(from: url) else { NSSound.beep(); return }
        AppSettings.setCustomIconImage(file, cwd: cwd)
    }
}
