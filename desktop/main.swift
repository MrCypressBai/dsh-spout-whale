// SpoutWhale — 独立桌面宠物（原生 AppKit，零第三方依赖）
//
// 图集协议与行为表对齐 @michengai/dsh-codex-pet@0.1.12 的 Codex pet protocol v2：
//   8 列 × 11 行，单格 192×208；行 0..8 为动作，行 9..10 为 16 个注视方向
//   （index 0 = 正上方，顺时针每 22.5°）。
// 与网页版的差别只在"宿主层"：把 CSS background-position 换成 CALayer.contents，
// 把页面内 fixed overlay 换成 borderless + nonactivating 的 NSPanel。

import AppKit

// MARK: - 诊断

var LOG_URL = URL(fileURLWithPath: "/tmp/spoutwhale.log")
var LOG_ENABLED = false
var CLI_AT: NSPoint? = nil
var CLI_POSE: String? = nil
var CLI_LEVEL: Int? = nil

/// 与 Info.plist 的 CFBundleIdentifier 一致，单实例守卫按它去重。
let BUNDLE_ID = "ai.micheng.spoutwhale"

/// 自测模式下**绝不写真实用户首选项**。
///
/// 为什么必须分家：`--drivetest` 会真的拖动窗口、真的遍历大小子菜单、并且断言"位置已落盘"。
/// 这些动作如果写进 `ai.micheng.spoutwhale`，跑一次测试就会把用户的位置/大小改掉——
/// 实测确实发生过（`defaults read` 里躺着测试写下的 originX=400, originY=500, scale=1.5）。
/// 自测仍然要验落盘，所以给它一个独立的 suite，两边互不污染。
let TEST_MODE = CommandLine.arguments.contains("--drivetest")
    || CommandLine.arguments.contains("--selftest")
    || CommandLine.arguments.contains("--statustest")
let PREFS: UserDefaults = TEST_MODE
    ? (UserDefaults(suiteName: "ai.micheng.spoutwhale.test") ?? .standard)
    : .standard

func plog(_ s: String) {
    if !LOG_ENABLED { return }
    let line = "[\(String(format: "%.3f", Date().timeIntervalSince1970))] \(s)\n"
    if let h = try? FileHandle(forWritingTo: LOG_URL) {
        h.seekToEndOfFile()
        h.write(line.data(using: .utf8)!)
        try? h.close()
    } else {
        try? line.write(to: LOG_URL, atomically: true, encoding: .utf8)
    }
}

// MARK: - 协议常量

let CELL_W = 192
let CELL_H = 208
let COLS = 8
let ROWS = 11

/// 各行动作帧数（无效帧留透明，不可渲染）
let FRAME_COUNT: [Int] = [6, 8, 8, 4, 5, 8, 6, 6, 6, 8, 8]

struct AnimSpec {
    let row: Int
    let ms: [Double]          // 每帧时长，逐帧不等（与 client.js ANIMATIONS 一致）
}

let ANIMS: [String: AnimSpec] = [
    "idle":         AnimSpec(row: 0, ms: [280, 110, 110, 140, 140, 320]),
    "runningRight": AnimSpec(row: 1, ms: [120, 120, 120, 120, 120, 120, 120, 220]),
    "runningLeft":  AnimSpec(row: 2, ms: [120, 120, 120, 120, 120, 120, 120, 220]),
    "waving":       AnimSpec(row: 3, ms: [140, 140, 140, 280]),
    "jumping":      AnimSpec(row: 4, ms: [140, 140, 140, 140, 280]),
    "failed":       AnimSpec(row: 5, ms: [140, 140, 140, 140, 140, 140, 140, 240]),
    "waiting":      AnimSpec(row: 6, ms: [150, 150, 150, 150, 150, 260]),
    "running":      AnimSpec(row: 7, ms: [120, 120, 120, 120, 120, 220]),
    "review":       AnimSpec(row: 8, ms: [150, 150, 150, 150, 150, 280]),
]

/// 16 方向注视：dx 向右为正、dy 向下为正（屏幕坐标习惯，与 client.js 同式）；
/// 死区 28px 内不判定方向。
func lookCell(dx: Double, dy: Double) -> (row: Int, col: Int)? {
    if (dx * dx + dy * dy).squareRoot() < 28 { return nil }
    let t = atan2(dx, -dy)
    let raw = ((t + 2 * Double.pi).truncatingRemainder(dividingBy: 2 * Double.pi)) / (Double.pi / 8)
    var idx = Int(raw.rounded())
    idx = ((idx % 16) + 16) % 16
    return (9 + idx / 8, idx % 8)
}

// MARK: - 图集

final class Atlas {
    private(set) var cells: [[CGImage?]] = []
    private(set) var pixelSize = CGSize.zero

    init?(url: URL) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        pixelSize = CGSize(width: img.width, height: img.height)
        var grid = [[CGImage?]](repeating: [CGImage?](repeating: nil, count: COLS), count: ROWS)
        for r in 0..<ROWS {
            for c in 0..<COLS {
                let rect = CGRect(x: c * CELL_W, y: r * CELL_H, width: CELL_W, height: CELL_H)
                grid[r][c] = img.cropping(to: rect)
            }
        }
        cells = grid
    }

    func image(row: Int, col: Int) -> CGImage? {
        guard row >= 0, row < ROWS, col >= 0, col < COLS else { return nil }
        return cells[row][col]
    }

    /// 把整格缩绘到 1×1 位图读 alpha，用来判定该格是否真的有内容（0 = 全透明）
    static func coverage(_ img: CGImage) -> UInt8 {
        var px: [UInt8] = [0, 0, 0, 0]
        guard let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8,
                                  bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
        ctx.interpolationQuality = .medium
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return px[3]
    }
}

// MARK: - 视图

final class PetView: NSView {
    var onTap: (() -> Void)?
    var onDragStart: (() -> Void)?
    var onDragEnd: (() -> Void)?
    var onContextMenu: ((NSEvent) -> Void)?

    var image: CGImage? {
        didSet {
            layer?.contents = image
            layer?.contentsScale = window?.backingScaleFactor ?? 2
        }
    }

    private var dragOriginScreen = NSPoint.zero
    private var windowOriginAtDrag = NSPoint.zero
    private var moved = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.contentsGravity = .resize
        layer?.magnificationFilter = .linear
        layer?.minificationFilter = .linear
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// 至少保留 40pt 在可见区域内，避免被拖出屏幕后抓不回来
    private func clampToScreen(_ o: NSPoint) -> NSPoint {
        guard let f = NSScreen.main?.visibleFrame else { return o }
        let s = window?.frame.size ?? NSSize(width: 96, height: 104)
        let keep: CGFloat = 40
        return NSPoint(x: min(max(o.x, f.minX - s.width + keep), f.maxX - keep),
                       y: min(max(o.y, f.minY - s.height + keep), f.maxY - keep))
    }

    override func mouseDown(with event: NSEvent) {
        plog("mouseDown \(event.locationInWindow)")
        guard let win = window else { return }
        dragOriginScreen = win.convertPoint(toScreen: event.locationInWindow)
        windowOriginAtDrag = win.frame.origin
        moved = false
        onDragStart?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let win = window else { return }
        let p = win.convertPoint(toScreen: event.locationInWindow)
        let dx = p.x - dragOriginScreen.x
        let dy = p.y - dragOriginScreen.y
        if abs(dx) + abs(dy) > 3 { moved = true }
        plog("mouseDragged d=\(Int(dx)),\(Int(dy))")
        win.setFrameOrigin(clampToScreen(NSPoint(x: windowOriginAtDrag.x + dx, y: windowOriginAtDrag.y + dy)))
    }

    override func mouseUp(with event: NSEvent) {
        plog("mouseUp moved=\(moved)")
        if moved { onDragEnd?() } else { onTap?() }
    }

    override func rightMouseDown(with event: NSEvent) {
        plog("rightMouseDown")
        onContextMenu?(event)
    }
}

// MARK: - 面板

final class PetPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - App

final class PetApp: NSObject, NSApplicationDelegate {
    private var panel: PetPanel!
    private var view: PetView!
    private var atlas: Atlas!
    private var statusItem: NSStatusItem!
    private var timer: Timer?

    // 行为状态
    private var pose = "idle"
    private var basePose = "idle"
    private var frame = 0
    private var elapsed: Double = 0
    private var cyclesLeft: Int? = nil
    private var lastTick = CACurrentMediaTime()
    private var nextDecision = CACurrentMediaTime() + 5.0
    private var moveDir = 0.0
    private var lastLog: Double = 0
    private var loggedCells = 0
    private var forcePose: String? = nil
    private var lastRow = -1
    private var lastCol = -1

    // 设置
    private var scale: Double = 1.0
    private var paused = false
    private var gazeTracking = true
    /// 仅自测使用：注入假光标位置，避免测试结果依赖真人鼠标当前在哪
    var gazeCursorOverride: NSPoint?

    // DSH 运行状态
    private var bubble: BubblePanel?
    private var statusTimer: Timer?
    private var dshStatus: DshStatus?
    private var showBubble = true
    private var doneUntil: Double = 0
    private var lastBubbleAnchor = NSRect.zero

    private let actions: [(String, Int, Int)] = [   // (pose, cycles, weight)
        ("waving", 1, 22),
        ("jumping", 1, 18),
        ("running", 2, 20),
        ("review", 1, 12),
        ("waiting", 2, 14),
        ("runningRight", 3, 7),
        ("runningLeft", 3, 7),
    ]

    // MARK: 启动

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.setActivationPolicy(.accessory)
        plog("=== 启动 === pid=\(ProcessInfo.processInfo.processIdentifier) 沙箱=\(ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] ?? "无")")
        plog("NSScreen.screens=\(NSScreen.screens.count) main=\(NSScreen.main?.frame ?? .zero) visible=\(NSScreen.main?.visibleFrame ?? .zero) scale=\(NSScreen.main?.backingScaleFactor ?? -1)")

        guard let url = Bundle.main.url(forResource: "spritesheet", withExtension: "png"),
              let a = Atlas(url: url) else {
            plog("FATAL 找不到或无法解码 spritesheet.png")
            NSApp.terminate(nil)
            return
        }
        atlas = a
        plog("图集已载入 \(Int(a.pixelSize.width))×\(Int(a.pixelSize.height))")

        let d = PREFS
        scale = d.object(forKey: "scale") as? Double ?? 1.0
        gazeTracking = d.object(forKey: "gaze") as? Bool ?? true

        if let fp = CLI_POSE, let spec = ANIMS[fp] {
            forcePose = fp
            basePose = fp
            plog("固定姿态模式 pose=\(fp) row=\(spec.row)")
        }

        buildPanel()
        buildMenuBar()
        restorePosition()
        if CommandLine.arguments.contains("--regular") {
            NSApp.setActivationPolicy(.regular)
            plog("激活策略改为 regular（测试用）")
        }
        if let lv = CLI_LEVEL {
            panel.level = NSWindow.Level(rawValue: lv)
            plog("面板层级改为 \(lv)")
        }
        if CommandLine.arguments.contains("--front") {
            NSApp.activate(ignoringOtherApps: true)
            plog("已激活到前台（测试用）")
        }

        // 诊断：事件是否真的到达 App（本地监听在 dispatch 之前触发）
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp,
                                                    .rightMouseDown, .otherMouseDown]) { e in
            plog("本地监听: type=\(e.type.rawValue) win=\(e.windowNumber) loc=\(e.locationInWindow)")
            return e
        }
        plog("面板建立后: frame=\(panel.frame) visible=\(panel.isVisible) key=\(panel.isKeyWindow) level=\(panel.level.rawValue) alpha=\(panel.alphaValue) screen=\(panel.screen?.frame ?? .zero)")

        showBubble = d.object(forKey: "bubble") as? Bool ?? true
        if showBubble {
            bubble = BubblePanel()
        }
        refreshStatus()

        let st = Timer(timeInterval: 0.7, repeats: true) { [weak self] _ in self?.refreshStatus() }
        RunLoop.main.add(st, forMode: .common)
        statusTimer = st

        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.step() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        lastTick = CACurrentMediaTime()

        if CommandLine.arguments.contains("--drivetest") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                guard let self = self else { exit(2) }
                exit(self.driveTest())
            }
        }
    }

    private func cellSize() -> NSSize {
        let bs = Double(NSScreen.main?.backingScaleFactor ?? 2)
        return NSSize(width: Double(CELL_W) * scale / bs, height: Double(CELL_H) * scale / bs)
    }

    private func buildPanel() {
        let s = cellSize()
        let panel = PetPanel(contentRect: NSRect(x: 0, y: 0, width: s.width, height: s.height),
                             styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovableByWindowBackground = false

        let v = PetView(frame: NSRect(x: 0, y: 0, width: s.width, height: s.height))
        v.autoresizingMask = [.width, .height]
        v.onTap = { [weak self] in self?.play("waving", cycles: 1) }
        v.onDragStart = { [weak self] in self?.moveDir = 0 }
        v.onDragEnd = { [weak self] in self?.savePosition() }
        v.onContextMenu = { [weak self] ev in
            guard let self = self, let m = self.panel.menu else { return }
            NSMenu.popUpContextMenu(m, with: ev, for: self.view)
        }
        panel.contentView = v
        panel.orderFrontRegardless()

        self.panel = panel
        self.view = v
        render()
    }

    private func buildMenuBar() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "🐳"
        item.menu = makeMenu()
        statusItem = item
        panel.menu = makeMenu()
    }

    private func makeMenu() -> NSMenu {
        let m = NSMenu()

        let hello = NSMenuItem(title: "打个招呼", action: #selector(actHello), keyEquivalent: "")
        hello.target = self
        m.addItem(hello)

        let splash = NSMenuItem(title: "喷个水 💦", action: #selector(actSplash), keyEquivalent: "")
        splash.target = self
        m.addItem(splash)

        let jump = NSMenuItem(title: "跳一下", action: #selector(actJump), keyEquivalent: "")
        jump.target = self
        m.addItem(jump)

        m.addItem(.separator())

        let sizeItem = NSMenuItem(title: "大小", action: nil, keyEquivalent: "")
        let sizeMenu = NSMenu()
        for (title, v) in [("小", 0.75), ("中", 1.0), ("大", 1.5), ("特大", 2.0)] {
            let it = NSMenuItem(title: "\(title)  (\(Int(v * 192))px)", action: #selector(actSize(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = v
            it.state = (abs(scale - v) < 0.001) ? .on : .off
            sizeMenu.addItem(it)
        }
        sizeItem.submenu = sizeMenu
        m.addItem(sizeItem)

        let gaze = NSMenuItem(title: "注视鼠标", action: #selector(actGaze), keyEquivalent: "")
        gaze.target = self
        gaze.state = gazeTracking ? .on : .off
        m.addItem(gaze)

        let pause = NSMenuItem(title: paused ? "继续动画" : "暂停动画", action: #selector(actPause), keyEquivalent: "")
        pause.target = self
        m.addItem(pause)

        m.addItem(.separator())

        if let st = dshStatus {
            let info = NSMenuItem(title: "DSH：\(st.headline)", action: nil, keyEquivalent: "")
            info.isEnabled = false
            m.addItem(info)
        }
        let bub = NSMenuItem(title: "状态气泡", action: #selector(actBubble), keyEquivalent: "")
        bub.target = self
        bub.state = showBubble ? .on : .off
        m.addItem(bub)

        m.addItem(.separator())

        let home = NSMenuItem(title: "回到左下角", action: #selector(actHome), keyEquivalent: "")
        home.target = self
        m.addItem(home)

        let quit = NSMenuItem(title: "退出喷水鲸鱼", action: #selector(actQuit), keyEquivalent: "q")
        quit.target = self
        m.addItem(quit)
        return m
    }

    // MARK: 位置

    private func screenFrame() -> NSRect {
        return NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
    }

    private func defaultOrigin() -> NSPoint {
        let f = screenFrame(), s = cellSize()
        // 左下角：右下角是宿主插件宠物的默认位置，叠在一起会互相遮挡
        return NSPoint(x: f.minX + 24, y: f.minY + 24)
    }

    private func restorePosition() {
        let d = PREFS
        let f = screenFrame(), s = cellSize()
        if let at = CLI_AT {
            panel.setFrameOrigin(at)
            plog("使用 --at 定位: \(at)")
            return
        }
        var o = defaultOrigin()
        if d.object(forKey: "originX") != nil {
            o = NSPoint(x: d.double(forKey: "originX"), y: d.double(forKey: "originY"))
        }
        // 夹到可见区域，防止换分辨率后跑丢
        o.x = min(max(o.x, f.minX - s.width * 0.5), f.maxX - s.width * 0.5)
        o.y = min(max(o.y, f.minY - s.height * 0.5), f.maxY - s.height * 0.5)
        panel.setFrameOrigin(o)
    }

    private func savePosition() {
        let o = panel.frame.origin
        let d = PREFS
        d.set(Double(o.x), forKey: "originX")
        d.set(Double(o.y), forKey: "originY")
    }

    // MARK: 行为

    private func play(_ key: String, cycles: Int?) {
        guard ANIMS[key] != nil else { return }
        pose = key
        frame = 0
        elapsed = 0
        cyclesLeft = cycles
        if key == "runningRight" { moveDir = 1 }
        else if key == "runningLeft" { moveDir = -1 }
        else { moveDir = 0 }
    }

    private func finishAction() {
        pose = basePose
        frame = 0
        elapsed = 0
        cyclesLeft = nil
        moveDir = 0
        nextDecision = CACurrentMediaTime() + Double.random(in: 4.0...11.0)
    }

    private func decide() {
        let total = actions.reduce(0) { $0 + $1.2 }
        var pick = Int.random(in: 0..<total)
        for (key, cycles, w) in actions {
            if pick < w { play(key, cycles: cycles); return }
            pick -= w
        }
        play("waving", cycles: 1)
    }

    private func step() {
        let now = CACurrentMediaTime()
        let dt = min(now - lastTick, 0.25)
        lastTick = now

        if paused { return }

        if now - lastLog > 2.0 { lastLog = now; heartbeat() }

        // 姿态决策优先级：CLI 固定姿态 > DSH 运行状态 > 刚完成反馈 > 自主随机行为
        if let fp = forcePose {
            if pose != fp { play(fp, cycles: nil) }
        } else if let st = dshStatus, st.isBusy {
            let want = dshPose(for: st.kind)
            if pose != want { play(want, cycles: nil) }
            moveDir = 0
        } else if now < doneUntil {
            if pose != "review" { play("review", cycles: nil) }
            moveDir = 0
        } else if cyclesLeft == nil && now >= nextDecision {
            decide()
        }

        if let spec = ANIMS[pose] {
            elapsed += dt * 1000
            var guardCount = 0
            while elapsed >= spec.ms[frame] && guardCount < 32 {
                elapsed -= spec.ms[frame]
                guardCount += 1
                frame += 1
                if frame >= spec.ms.count {
                    frame = 0
                    if let left = cyclesLeft {
                        if left <= 1 { finishAction(); break }
                        cyclesLeft = left - 1
                    }
                }
            }
        }

        // 游动位移
        if moveDir != 0, cyclesLeft != nil {
            let f = screenFrame(), s = cellSize()
            var o = panel.frame.origin
            o.x += CGFloat(moveDir) * 110 * CGFloat(dt)
            if o.x < f.minX - 8 {
                o.x = f.minX - 8
                play("runningRight", cycles: 3)
            } else if o.x + s.width > f.maxX + 8 {
                o.x = f.maxX + 8 - s.width
                play("runningLeft", cycles: 3)
            }
            panel.setFrameOrigin(o)
        }

        render()
    }

    private func render() {
        var row = ANIMS[pose]?.row ?? 0
        var col = frame

        // 注视优先（仅在静止姿态，否则动画会被注视永久覆盖）
        if gazeTracking, pose == "idle" || pose == "waiting" {
            let f = panel.frame
            let mouse = gazeCursorOverride ?? NSEvent.mouseLocation   // 屏幕坐标，y 向上
            let cx = f.midX, cy = f.midY
            let dx = Double(mouse.x - cx)
            let dyUp = Double(mouse.y - cy)
            let dist = (dx * dx + dyUp * dyUp).squareRoot()
            if dist < 320, let lc = lookCell(dx: dx, dy: -dyUp) {
                row = lc.row
                col = lc.col
            }
        }

        if col >= FRAME_COUNT[row] { col = 0 }
        lastRow = row; lastCol = col
        view.image = atlas.image(row: row, col: col)
        loggedCells += 1
    }

    /// 用真实 NSEvent 走一遍 mouseDown/Dragged/Up 链路，断言窗口位移与点击挥手。
    /// 注意：这验证的是"事件处理器 + 窗口移动 + 落盘"逻辑；OS 层投递需真人点击验证。
    func driveTest() -> Int32 {
        var fails: [String] = []
        func ev(_ t: NSEvent.EventType, _ p: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: t, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        // 真实鼠标语义：屏幕坐标平滑移动，窗口跟随；locationInWindow 必须按当前窗口原点反算
        let o0 = panel.frame.origin
        let s0 = NSPoint(x: o0.x + 48, y: o0.y + 52)
        func local(_ p: NSPoint) -> NSPoint {
            NSPoint(x: p.x - panel.frame.origin.x, y: p.y - panel.frame.origin.y)
        }
        view.mouseDown(with: ev(.leftMouseDown, local(s0)))
        for i in 1...4 {
            let sp = NSPoint(x: s0.x + 50 * Double(i), y: s0.y)
            view.mouseDragged(with: ev(.leftMouseDragged, local(sp)))
        }
        view.mouseUp(with: ev(.leftMouseUp, local(NSPoint(x: s0.x + 200, y: s0.y))))
        let moved = panel.frame.origin.x - o0.x
        if abs(moved - 200) > 1.5 { fails.append("拖拽位移=\(Int(moved)) 期望 200") }
        if abs(panel.frame.origin.y - o0.y) > 1.5 { fails.append("拖拽串改了 y") }

        // 单击 -> 挥手
        forcePose = nil
        gazeTracking = false
        play("idle", cycles: nil)
        let o1 = panel.frame.origin
        view.mouseDown(with: ev(.leftMouseDown, NSPoint(x: 48, y: 52)))
        view.mouseUp(with: ev(.leftMouseUp, NSPoint(x: 48, y: 52)))
        if pose != "waving" { fails.append("单击未触发挥手 pose=\(pose)") }
        if abs(panel.frame.origin.x - o1.x) > 0.5 { fails.append("纯点击却移动了窗口") }

        if panel.menu == nil || (panel.menu?.items.count ?? 0) < 6 { fails.append("右键菜单项不足") }
        if !(panel.menu?.items.contains { $0.submenu != nil } ?? false) { fails.append("菜单缺少大小子菜单") }

        savePosition()
        if abs(PREFS.double(forKey: "originX") - Double(panel.frame.origin.x)) > 1 {
            fails.append("位置未落盘")
        }

        // 每个姿态都必须渲染到自己那一行
        for key in ANIMS.keys.sorted() {
            play(key, cycles: 1)
            render()
            if lastRow != (ANIMS[key]?.row ?? -99) { fails.append("姿态 \(key) 渲染行错误 r\(lastRow)") }
        }
        // 注视覆盖：注入假光标，断言精确命中协议格子（正右=index4=r9c4，正上=index0=r9c0）
        gazeTracking = true
        forcePose = "idle"; basePose = "idle"; play("idle", cycles: nil)
        let mid = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        gazeCursorOverride = NSPoint(x: mid.x + 140, y: mid.y)      // 正右
        render()
        if lastRow != 9 || lastCol != 4 { fails.append("正右注视=\(lastRow),\(lastCol) 期望 r9c4") }
        gazeCursorOverride = NSPoint(x: mid.x, y: mid.y + 140)      // 正上
        render()
        if lastRow != 9 || lastCol != 0 { fails.append("正上注视=\(lastRow),\(lastCol) 期望 r9c0") }
        gazeCursorOverride = NSPoint(x: mid.x - 140, y: mid.y)      // 正左 = index 12 → r10c4
        render()
        if lastRow != 10 || lastCol != 4 { fails.append("正左注视=\(lastRow),\(lastCol) 期望 r10c4") }
        // 死区内不应触发注视
        gazeCursorOverride = NSPoint(x: mid.x + 10, y: mid.y)
        render()
        if lastRow != 0 { fails.append("死区内仍触发注视 r\(lastRow)") }
        gazeCursorOverride = nil
        forcePose = nil
        gazeTracking = false

        print("driveTest 失败项: \(fails.count)")
        for f in fails { print("  - \(f)") }
        print(fails.isEmpty ? "DRIVETEST PASS" : "DRIVETEST FAIL")
        return fails.isEmpty ? 0 : 1
    }

    /// 轮询 DSH 会话投影，推导运行状态
    private func refreshStatus() {
        let prev = dshStatus
        let now = DshStatusReader.read(watchCwd: nil)
        dshStatus = now
        // 由"忙"转"闲"⇒ 认为这一轮跑完了，给 4 秒 review 反馈
        if let p = prev, p.isBusy, let n = now, !n.isBusy {
            doneUntil = CACurrentMediaTime() + 4.0
        }
        if prev?.kind != now?.kind || prev == nil {
            plog("状态变更 -> \(now?.headline ?? "无状态") | \(now?.subline ?? "")")
        }
        lastBubbleAnchor = .zero        // 强制刷新气泡位置
        refreshBubble()
    }

    private func refreshBubble() {
        guard showBubble, let bubble = bubble else { return }
        guard let st = dshStatus else { bubble.hide(); return }

        let inDoneWindow = !st.isBusy && CACurrentMediaTime() < doneUntil
        var disp = st
        if inDoneWindow { disp.kind = .done }

        // 空闲且不在"刚完成"窗口里 ⇒ 不打扰，收起气泡
        if disp.kind == .idle && st.title.isEmpty { bubble.hide(); return }
        if disp.kind == .idle && !inDoneWindow { bubble.hide(); return }

        if panel.frame != lastBubbleAnchor {
            lastBubbleAnchor = panel.frame
            bubble.show(headline: disp.headline, subline: disp.subline, anchor: panel.frame)
        }
    }

    private func dshPose(for kind: DshKind) -> String {
        switch kind {
        case .waiting: return "waiting"
        case .failed:  return "failed"
        case .thinking, .generating, .tool: return "running"
        case .done:    return "review"
        case .idle:    return "idle"
        }
    }

    private func heartbeat() {
        plog("hb n=\(loggedCells) pose=\(pose) 实际格=r\(lastRow)c\(lastCol) frame=\(panel.frame) visible=\(panel.isVisible) occ=\(panel.occlusionState.rawValue)")
    }

    // MARK: 菜单动作

    @objc private func actHello() { play("waving", cycles: 1) }
    @objc private func actSplash() { play("review", cycles: 1) }
    @objc private func actJump() { play("jumping", cycles: 1) }
    @objc private func actBubble() {
        showBubble.toggle()
        PREFS.set(showBubble, forKey: "bubble")
        if showBubble, bubble == nil { bubble = BubblePanel() }
        if !showBubble { bubble?.hide() }
        panel.menu = makeMenu()
        statusItem.menu = makeMenu()
        lastBubbleAnchor = .zero
        refreshBubble()
    }

    @objc private func actPause() {
        paused.toggle()
        panel.menu = makeMenu()
        statusItem.menu = makeMenu()
    }
    @objc private func actGaze() {
        gazeTracking.toggle()
        PREFS.set(gazeTracking, forKey: "gaze")
        panel.menu = makeMenu()
        statusItem.menu = makeMenu()
    }
    @objc private func actSize(_ sender: NSMenuItem) {
        guard let v = sender.representedObject as? Double else { return }
        scale = v
        PREFS.set(v, forKey: "scale")
        let s = cellSize()
        let old = panel.frame
        let newFrame = NSRect(x: old.midX - s.width / 2, y: old.midY - s.height / 2,
                              width: s.width, height: s.height)
        panel.setFrame(newFrame, display: true)
        panel.menu = makeMenu()
        statusItem.menu = makeMenu()
        render()
    }
    @objc private func actHome() {
        panel.setFrameOrigin(defaultOrigin())
        savePosition()
    }
    @objc private func actQuit() {
        savePosition()
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ note: Notification) {
        savePosition()
        bubble?.hide()
    }
}

// MARK: - 自检（CLI：--selftest）

func runSelfTest() -> Int32 {
    guard let url = Bundle.main.url(forResource: "spritesheet", withExtension: "png") else {
        print("FAIL: 找不到 spritesheet.png")
        return 1
    }
    guard let atlas = Atlas(url: url) else {
        print("FAIL: 无法解码 spritesheet.png")
        return 1
    }
    let size = atlas.pixelSize
    print("图集尺寸: \(Int(size.width))×\(Int(size.height))")
    var ok = true
    if Int(size.width) != CELL_W * COLS || Int(size.height) != CELL_H * ROWS {
        print("FAIL: 尺寸应为 \(CELL_W * COLS)×\(CELL_H * ROWS)")
        ok = false
    }
    var emptyValid = 0, filledInvalid = 0
    for r in 0..<ROWS {
        var line = "row \(r):"
        for c in 0..<COLS {
            guard let img = atlas.image(row: r, col: c) else { line += " nil"; ok = false; continue }
            let cov = Atlas.coverage(img)
            let shouldHaveContent = c < FRAME_COUNT[r]
            if shouldHaveContent && cov == 0 { emptyValid += 1; line += " EMPTY!" }
            else if !shouldHaveContent && cov > 0 { filledInvalid += 1; line += " FULL!" }
            else { line += String(format: " %3d", cov) }
        }
        print(line)
    }
    print("有效帧为空的格数: \(emptyValid)   无效帧有内容的格数: \(filledInvalid)")
    if emptyValid > 0 || filledInvalid > 0 { ok = false }
    print(ok ? "SELFTEST PASS" : "SELFTEST FAIL")
    return ok ? 0 : 1
}

// MARK: - main

let args = CommandLine.arguments
do {
    var i = 0
    while i < args.count {
        if args[i] == "--log", i + 1 < args.count {
            LOG_URL = URL(fileURLWithPath: args[i + 1]); LOG_ENABLED = true; i += 2; continue
        }
        if args[i] == "--pose", i + 1 < args.count {
            CLI_POSE = args[i + 1]; i += 2; continue
        }
        if args[i] == "--status-dir", i + 1 < args.count {
            DshStatusReader.overrideDirs = [URL(fileURLWithPath: args[i + 1])]; i += 2; continue
        }
        if args[i] == "--level", i + 1 < args.count {
            CLI_LEVEL = Int(args[i + 1]); i += 2; continue
        }
        if args[i] == "--at", i + 1 < args.count {
            let p = args[i + 1].split(separator: ",")
            if p.count == 2, let x = Double(p[0]), let y = Double(p[1]) { CLI_AT = NSPoint(x: x, y: y) }
            i += 2; continue
        }
        i += 1
    }
}
if args.contains("--selftest") {
    exit(runSelfTest())
}
if args.contains("--statustest") {
    exit(DshStatusReader.selfTest())
}

// 单实例守卫：从 Finder／LaunchServices 启动时系统自动去重，但**直接执行二进制**
// （LaunchAgent、脚本、终端）不会——那会开出第二只鲸鱼，而且两只都记同一个位置。
// 测试模式需要并发实例，显式跳过。
if !args.contains("--drivetest") && !args.contains("--force") {
    let me = ProcessInfo.processInfo.processIdentifier
    let others = NSRunningApplication.runningApplications(withBundleIdentifier: BUNDLE_ID)
        .filter { $0.processIdentifier != me }
    if !others.isEmpty {
        let pids = others.map { String($0.processIdentifier) }.joined(separator: ", ")
        FileHandle.standardError.write(
            "SpoutWhale 已在运行（pid \(pids)），本次启动退出（用 --force 可强行再开一只）。\n"
                .data(using: .utf8)!)
        exit(0)
    }
}

let app = NSApplication.shared
let delegate = PetApp()
app.delegate = delegate
app.run()
