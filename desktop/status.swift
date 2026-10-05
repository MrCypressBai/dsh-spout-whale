// status.swift — 读取 DeepSeek Harness 的实时运行状态，并渲染状态气泡
//
// 数据源（零侵入：不改 DSH、不装插件、不重启）：
//   ~/.dsh/storages/session_projcache_archive_manager_v2/sessions/session_*.json
//   ~/.dsh/storages/session_projcache/sessions/session-*.json
// 取其中 mtime 最新的那条会话投影（record.rows.*.val），据此判定状态。
//
// 实测到的关键字段（record.rows）：
//   sessionStats.val.openStep       非 null = 有步骤在跑；firstTokenTime=null ⇒ 还在等首 token
//   sessionStats.val.pendingCalls   {callId: 起始时间戳} 非空 = 工具正在执行
//   sessionStats.val.decodeTokens   已解码 token 数
//   turnBoundary.val.openTurnStartSeq  非 null = 本轮未结束
//   userQuestions.val.questions.active 非空 = 在等你回答
//   llmRetry.val                    非空 = 正在重试（视为异常）
//   todos.val                       [{content,status}] 待办清单
//   title.val                       会话标题

import AppKit

enum DshKind {
    case idle, thinking, generating, tool, waiting, done, failed
}

struct DshStatus {
    var kind: DshKind
    var title: String
    var cwd: String
    var toolElapsed: Double      // 工具已执行秒数（kind == .tool 时有意义）
    var retryCount: Int
    var todosDone: Int
    var todosTotal: Int
    var decodeTokens: Int
    var activeQuestions: Int
    var mtime: Date

    var isBusy: Bool {
        switch kind {
        case .idle, .done: return false
        default: return true
        }
    }

    var headline: String {
        switch kind {
        case .idle:       return "空闲中"
        case .thinking:   return "思考中…"
        case .generating: return "生成中…"
        case .tool:       return String(format: "执行中… %.0fs", toolElapsed)
        case .waiting:    return activeQuestions > 1 ? "等你回答 \(activeQuestions) 个问题" : "等你回答"
        case .done:       return "这轮完成了"
        case .failed:     return retryCount > 0 ? "重试中… (\(retryCount))" : "出错了"
        }
    }

    var subline: String {
        var parts: [String] = []
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { parts.append(t.count > 18 ? String(t.prefix(18)) + "…" : t) }
        if todosTotal > 0 { parts.append("待办 \(todosDone)/\(todosTotal)") }
        if decodeTokens > 0 { parts.append("\(decodeTokens / 1000)K tok") }
        return parts.joined(separator: " · ")
    }
}

enum DshStatusReader {
    /// 测试用：覆盖扫描目录，注入受控的假会话文件
    static var overrideDirs: [URL]? = nil

    /// 测试用：把"宿主在不在"钉成固定值，否则自测结果会随 DSH 开关而变。
    static var assumeDshRunning: Bool? = nil

    /// DSH 桌面端的 bundle id（与 DSH NEXT.app 的 Info.plist 一致）。
    static let DSH_BUNDLE_ID = "ai.deepseek.dsh.desktop.next"

    /// 投影文件多久没被写过就当它死了。
    ///
    /// 为什么需要这一层：`pendingCalls` / `openStep` 只在行值**变化**时才落盘，一次
    /// 长工具跑完前文件一直不动。所以不能简单说"文件旧=状态旧"——那会把 20 分钟
    /// 的构建误判成空闲。这里取一个明显大于任何合理单步、又远小于"永远卡住"的界：
    /// 30 分钟。宁可极端情况下早一点安静下来，也不要气泡永远停在"执行中… 3600s"。
    static let staleAfter: TimeInterval = 30 * 60

    static var dirs: [URL] {
        if let o = overrideDirs { return o }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent(".dsh/storages/session_projcache_archive_manager_v2/sessions"),
            home.appendingPathComponent(".dsh/storages/session_projcache/sessions"),
        ]
    }

    /// 宿主进程在不在。宿主被杀（或中途崩溃）时，投影文件会停在最后一刻，
    /// 里面的 `pendingCalls` 永远非空 ⇒ 不加这道闸就会一直显示"执行中…"。
    static func dshRunning() -> Bool {
        if let forced = assumeDshRunning { return forced }
        return !NSRunningApplication.runningApplications(withBundleIdentifier: DSH_BUNDLE_ID).isEmpty
    }

    /// 这份投影还算不算"活着"。now 可注入，保证自测确定性。
    static func isStale(mtime: Date, now: Date = Date()) -> Bool {
        if !dshRunning() { return true }
        return now.timeIntervalSince(mtime) > staleAfter
    }

    static func rowVal(_ rows: [String: Any], _ key: String) -> Any? {
        guard let r = rows[key] as? [String: Any], let v = r["val"], !(v is NSNull) else { return nil }
        return v
    }

    /// watchCwd 非空时优先只看该工作区的会话；找不到再退回全部。
    /// 宿主不在跑、或所有候选都过期 ⇒ 返回 nil（宠物回到自主行为、气泡收起）。
    static func read(watchCwd: String?) -> DshStatus? {
        guard dshRunning() else { return nil }
        var candidates: [(Date, URL)] = []
        let fm = FileManager.default
        for d in dirs {
            guard let names = try? fm.contentsOfDirectory(atPath: d.path) else { continue }
            for n in names where n.hasSuffix(".json") {
                let u = d.appendingPathComponent(n)
                guard let attrs = try? fm.attributesOfItem(atPath: u.path),
                      let m = attrs[.modificationDate] as? Date else { continue }
                candidates.append((m, u))
            }
        }
        candidates.sort { $0.0 > $1.0 }
        candidates.removeAll { isStale(mtime: $0.0) }

        var best: DshStatus?
        var fallback: DshStatus?
        for (mtime, url) in candidates.prefix(40) {
            guard let data = try? Data(contentsOf: url),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let record = root["record"] as? [String: Any],
                  let rows = record["rows"] as? [String: Any],
                  let identity = record["identity"] as? [String: Any] else { continue }
            let cwd = (identity["cwd"] as? String) ?? ""
            guard let st = derive(rows: rows, cwd: cwd, mtime: mtime) else { continue }
            if fallback == nil { fallback = st }
            if let want = watchCwd, !want.isEmpty {
                if cwd == want { best = st; break }
            } else {
                best = st; break
            }
        }
        return best ?? fallback
    }

    static func derive(rows: [String: Any], cwd: String, mtime: Date) -> DshStatus? {
        guard let stats = rowVal(rows, "sessionStats") as? [String: Any] else { return nil }

        let pending = stats["pendingCalls"] as? [String: Any] ?? [:]
        let openStep = stats["openStep"] as? [String: Any]
        let decodeTokens = stats["decodeTokens"] as? Int ?? 0

        let tb = rowVal(rows, "turnBoundary") as? [String: Any]
        let openTurn = tb?["openTurnStartSeq"] as? Int

        let questions = (rowVal(rows, "userQuestions") as? [String: Any])?["questions"] as? [String: Any]
        let active = questions?["active"] as? [Any] ?? []

        let retry = rowVal(rows, "llmRetry") as? [String: Any] ?? [:]
        let goal = rowVal(rows, "goal") as? [String: Any]
        let goalFailed = !(goal?["failure"] is NSNull) && goal?["failure"] != nil

        let todos = rowVal(rows, "todos") as? [[String: Any]] ?? []
        let todosDone = todos.filter { ($0["status"] as? String) == "completed" }.count

        let title = (rowVal(rows, "title") as? String) ?? ""

        // 工具已跑多久：取 pendingCalls 里最早的起始时间戳
        var toolElapsed: Double = 0
        if let start = pending.values.compactMap({ ($0 as? NSNumber)?.doubleValue }).min() {
            toolElapsed = max(0, Date().timeIntervalSince1970 - start / 1000.0)
        }

        let kind: DshKind
        if !active.isEmpty {
            kind = .waiting
        } else if goalFailed {
            kind = .failed
        } else if !retry.isEmpty {
            kind = .failed
        } else if !pending.isEmpty {
            kind = .tool
        } else if let os = openStep {
            let firstToken = os["firstTokenTime"]
            kind = (firstToken == nil || firstToken is NSNull) ? .thinking : .generating
        } else if openTurn != nil {
            kind = .generating          // 步骤间隙，仍属本轮进行中
        } else {
            kind = .idle
        }

        return DshStatus(kind: kind, title: title, cwd: cwd,
                         toolElapsed: toolElapsed, retryCount: retry.count,
                         todosDone: todosDone, todosTotal: todos.count,
                         decodeTokens: decodeTokens, activeQuestions: active.count,
                         mtime: mtime)
    }
}

// MARK: - 气泡

final class BubbleView: NSView {
    var headline = "" { didSet { needsDisplay = true } }
    var subline = "" { didSet { needsDisplay = true } }
    var tailFraction: CGFloat = 0.5 { didSet { needsDisplay = true } }

    static let tailH: CGFloat = 7
    static let padX: CGFloat = 12
    static let padY: CGFloat = 9
    static let maxBodyW: CGFloat = 240

    static func headlineAttrs() -> [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: 12, weight: .semibold),
         .foregroundColor: NSColor(calibratedWhite: 0.12, alpha: 1)]
    }
    static func sublineAttrs() -> [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: 11, weight: .regular),
         .foregroundColor: NSColor(calibratedWhite: 0.42, alpha: 1)]
    }

    static func measure(headline: String, subline: String) -> NSSize {
        let a = NSAttributedString(string: headline, attributes: headlineAttrs())
        let b = NSAttributedString(string: subline, attributes: sublineAttrs())
        let wa = a.size().width, wb = b.size().width
        let bodyW = min(maxBodyW, max(wa, wb) + padX * 2)
        let ha = a.size().height
        let hb = subline.isEmpty ? 0 : b.size().height + 1
        let bodyH = ha + hb + padY * 2
        return NSSize(width: max(84, bodyW) + 2, height: bodyH + tailH + 2)
    }

    override var isOpaque: Bool { false }

    override func draw(_ dirty: NSRect) {
        let tailH = Self.tailH
        let body = NSRect(x: 1, y: tailH + 1, width: bounds.width - 2, height: bounds.height - tailH - 2)

        let path = NSBezierPath(roundedRect: body, xRadius: 10, yRadius: 10)
        let tx = body.minX + body.width * min(max(tailFraction, 0.12), 0.88)
        let tri = NSBezierPath()
        tri.move(to: NSPoint(x: tx - 6, y: body.minY + 1.5))
        tri.line(to: NSPoint(x: tx + 6, y: body.minY + 1.5))
        tri.line(to: NSPoint(x: tx, y: body.minY - tailH + 1))
        tri.close()
        path.append(tri)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(calibratedWhite: 0, alpha: 0.18)
        shadow.shadowBlurRadius = 6
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.set()
        NSColor(calibratedWhite: 0.99, alpha: 0.97).setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSColor(calibratedWhite: 0.78, alpha: 1).setStroke()
        path.lineWidth = 1
        path.stroke()

        let a = NSAttributedString(string: headline, attributes: Self.headlineAttrs())
        let h = a.size().height
        a.draw(at: NSPoint(x: body.minX + Self.padX, y: body.maxY - Self.padY - h))
        if !subline.isEmpty {
            let b = NSAttributedString(string: subline, attributes: Self.sublineAttrs())
            b.draw(at: NSPoint(x: body.minX + Self.padX, y: body.maxY - Self.padY - h - b.size().height - 1))
        }
    }
}

final class BubblePanel: NSPanel {
    let bubble = BubbleView(frame: .zero)

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 120, height: 40),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        ignoresMouseEvents = true                       // 纯信息展示，绝不挡点击
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        contentView = bubble
        alphaValue = 0
    }

    func show(headline: String, subline: String, anchor: NSRect) {
        bubble.headline = headline
        bubble.subline = subline
        let s = BubbleView.measure(headline: headline, subline: subline)
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        // 默认贴宠物上方；上方放不下就翻到下方
        var origin = NSPoint(x: anchor.midX - s.width / 2, y: anchor.maxY + 8)
        var tail: CGFloat = 0.5
        if origin.y + s.height > screen.maxY {
            origin.y = anchor.minY - s.height - 8
            tail = 0.5
        }
        origin.x = min(max(origin.x, screen.minX + 4), screen.maxX - s.width - 4)
        origin.y = min(max(origin.y, screen.minY + 4), screen.maxY - s.height - 4)
        // 尾尖对准宠物中线
        tail = min(max((anchor.midX - origin.x) / max(1, s.width), 0.12), 0.88)
        bubble.tailFraction = tail

        setFrame(NSRect(origin: origin, size: s), display: true)
        bubble.frame = NSRect(origin: .zero, size: s)
        bubble.needsDisplay = true
        if alphaValue < 1 { alphaValue = 1 }
        orderFrontRegardless()
    }

    func hide() {
        if alphaValue > 0 { alphaValue = 0 }
        orderOut(nil)
    }
}


// MARK: - 状态推导自测
//
// 真实 DSH 状态随时在变，靠"正好撞见"无法验收。这里用合成 rows 把每个分支钉死。

extension DshStatusReader {
    static func deriveForTest(_ rowsJSON: String) -> DshStatus? {
        guard let d = rowsJSON.data(using: .utf8),
              let rows = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        return derive(rows: rows, cwd: "/tmp/fake", mtime: Date())
    }

    static func selfTest() -> Int32 {
        var fails: [String] = []
        func check(_ name: String, _ rows: String, _ expect: DshKind, _ expectHead: String? = nil) {
            guard let st = deriveForTest(rows) else { fails.append(name + ": 推导返回 nil"); return }
            if st.kind != expect { fails.append(name + ": 得到 \(st.kind) 期望 \(expect)") }
            if let h = expectHead, st.headline != h { fails.append(name + ": 文案 '\(st.headline)' 期望 '\(h)'") }
        }
        func rows(_ stats: String, extra: String = "") -> String {
            var s = #"{"sessionStats":{"val":{"decodeTokens":123456,"# + stats
                + #"}},"turnBoundary":{"val":{"openTurnStartSeq":1187}},"title":{"val":"测试会话"}"#
            if !extra.isEmpty { s += "," + extra }
            return s + "}"
        }
        let nowMs = Int(Date().timeIntervalSince1970 * 1000)

        check("思考中", rows(#""pendingCalls":{},"openStep":{"firstTokenTime":null}"#), .thinking, "思考中…")
        check("生成中", rows(#""pendingCalls":{},"openStep":{"firstTokenTime":1791216000000}"#), .generating, "生成中…")
        check("执行中", rows(#""pendingCalls":{"c1":\#(nowMs - 3000)},"openStep":null"#), .tool)
        if let st = deriveForTest(rows(#""pendingCalls":{"c1":\#(nowMs - 3000)},"openStep":null"#)) {
            if !(st.toolElapsed > 2.5 && st.toolElapsed < 6) { fails.append("执行中: 耗时 \(st.toolElapsed) 期望≈3s") }
        }
        check("等待用户", rows(#""pendingCalls":{},"openStep":null"#,
              extra: #""userQuestions":{"val":{"questions":{"active":[{"id":"q1"},{"id":"q2"}]}}}"#),
              .waiting, "等你回答 2 个问题")
        check("重试中", rows(#""pendingCalls":{},"openStep":null"#,
              extra: #""llmRetry":{"val":{"1":{"n":1}}}"#), .failed)
        check("目标失败", rows(#""pendingCalls":{},"openStep":null"#,
              extra: #""goal":{"val":{"failure":{"message":"boom"}}}"#), .failed)
        check("轮次间隙", rows(#""pendingCalls":{},"openStep":null"#), .generating)
        check("空闲",
              #"{"sessionStats":{"val":{"decodeTokens":1000,"pendingCalls":{},"openStep":null}},"turnBoundary":{"val":{"openTurnStartSeq":null}},"title":{"val":"测试会话"}}"#,
              .idle, "空闲中")
        if let st = deriveForTest(rows(#""pendingCalls":{},"openStep":null"#,
              extra: #""todos":{"val":[{"content":"a","status":"completed"},{"content":"b","status":"in_progress"},{"content":"c","status":"pending"}]}"#)) {
            if st.todosTotal != 3 || st.todosDone != 1 { fails.append("待办: 得到 \(st.todosDone)/\(st.todosTotal) 期望 1/3") }
            if !st.subline.contains("待办 1/3") { fails.append("副行缺待办: '\(st.subline)'") }
        } else { fails.append("待办: 推导 nil") }
        if deriveForTest(#"{"title":{"val":"x"}}"#) != nil { fails.append("缺 sessionStats 时应返回 nil") }

        // —— 新鲜度闸门 ——
        // 真实坑：DSH 被杀/崩在工具执行中，投影文件停在最后一刻，`pendingCalls` 永远非空，
        // 气泡就会一直显示"执行中… 3600s"。所以"宿主在不在"必须是硬闸。
        let savedAssume = assumeDshRunning
        let t0 = Date()
        assumeDshRunning = true
        if isStale(mtime: t0, now: t0) { fails.append("新鲜度: 刚写过的投影不该判陈旧") }
        if !isStale(mtime: t0, now: t0.addingTimeInterval(staleAfter + 1)) {
            fails.append("新鲜度: 超过 staleAfter 应判陈旧")
        }
        assumeDshRunning = false
        if !isStale(mtime: t0, now: t0) { fails.append("新鲜度: 宿主不在跑时应判陈旧") }
        if read(watchCwd: nil) != nil { fails.append("宿主不在跑时 read() 应返回 nil") }
        assumeDshRunning = savedAssume

        print("状态推导自测失败项: \(fails.count)")
        for f in fails { print("  - \(f)") }
        if let live = DshStatusReader.read(watchCwd: nil) {
            print("实时状态: [\(live.headline)] \(live.subline)  cwd=\(live.cwd)")
        } else {
            print("实时状态: 未找到可读的会话投影（DSH 未运行？）")
        }
        print(fails.isEmpty ? "STATUSTEST PASS" : "STATUSTEST FAIL")
        return fails.isEmpty ? 0 : 1
    }
}
