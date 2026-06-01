import Foundation

/// 监听每个活跃会话的 subagents 目录,把子 agent 的执行(model / token / 状态)增量喂给 SessionStore。
///
/// 作为 Dashboard 的兄弟服务存在(像 DashboardHTTPServer),**不**放进 SessionStore actor ——
/// 后者保持纯状态 + 注入时钟的可测模型,不持有非 Sendable 的 fd / 不在审批的串行执行器上做文件 IO。
/// watcher 通过订阅 store 的事件流感知会话生死,结果再 `await store.upsertAgentRun(...)` 推回去。
///
/// 监听用 DispatchSource(kqueue):监听的是少量已知目录(每会话一个、生命周期受限),不需要
/// FSEvents 的子树合并;DispatchSource 原生贴 GCD、无需 CFRunLoop、配 per-file 字节偏移读最自然。
actor SubagentWatcher {
    private let store: SessionStore
    private let now: @Sendable () -> Date
    private let delay: @Sendable (UInt64) async -> Void
    private let queue = DispatchQueue(label: "com.heypanda.cc-dashboard.subagent-watcher", qos: .utility)

    private var watched: [String: SessionWatch] = [:]   // sessionId → watch
    private var pendingDirs: [String: String] = [:]      // sessionId → transcriptPath(目录还没出现)
    private var pollRunning = false

    init(
        store: SessionStore,
        now: @Sendable @escaping () -> Date = { Date() },
        delay: @Sendable @escaping (UInt64) async -> Void = { try? await Task.sleep(nanoseconds: $0) }
    ) {
        self.store = store
        self.now = now
        self.delay = delay
    }

    /// 长生命周期循环:订阅 store,跟随会话生死起停监听。Dashboard.init 里 `Task.detached` 拉起。
    func run() async {
        let stream = await store.subscribe()
        for await event in stream {
            switch event {
            case .snapshot(let sessions, _):
                for s in sessions { await ensureWatch(sessionID: s.id, transcriptPath: s.transcriptPath) }
            case .sessionUpsert(let s):
                await ensureWatch(sessionID: s.id, transcriptPath: s.transcriptPath)
            case .sessionRemove(let id):
                stopWatch(sessionID: id)
            default:
                break
            }
        }
    }

    // MARK: - Lifecycle

    private func ensureWatch(sessionID: String, transcriptPath: String?) async {
        guard let transcriptPath, !transcriptPath.isEmpty else { return }
        // 已在监听 / 已在等目录出现 → 直接返回(sessionUpsert 很频繁,避免每次都 stat)。
        guard watched[sessionID] == nil, pendingDirs[sessionID] == nil else { return }

        let dir = SubagentParsing.subagentsDir(forTranscriptPath: transcriptPath)
        if FileManager.default.fileExists(atPath: dir.path) {
            await startDirWatch(sessionID: sessionID, dir: dir)
        } else {
            // 不能 kqueue 一个不存在的路径 —— 进 pendingDirs,低频轮询等它出现(子 agent 首次派生后才有)。
            pendingDirs[sessionID] = transcriptPath
            startPollIfNeeded()
        }
    }

    private func startDirWatch(sessionID: String, dir: URL) async {
        let fd = open(dir.path, O_EVTONLY)   // 目录只监听不读(列目录走 FileManager),O_EVTONLY 够用
        guard fd >= 0 else { return }
        let watch = SessionWatch(sessionID: sessionID, subagentsDir: dir)
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write], queue: queue
        )
        src.setEventHandler { @Sendable [weak self] in
            Task { await self?.scanDir(sessionID: sessionID) }
        }
        src.setCancelHandler { close(fd) }   // fd 的关闭只在 cancel handler 里做(捕获值,不读 watch.fd)
        watch.dirSource = src
        watched[sessionID] = watch
        src.resume()
        await scanDir(sessionID: sessionID)   // 首次全量发现已存在的子 agent 文件
    }

    private func stopWatch(sessionID: String) {
        pendingDirs.removeValue(forKey: sessionID)
        guard let watch = watched.removeValue(forKey: sessionID) else { return }
        watch.dirSource?.cancel()
        for (_, fw) in watch.files { fw.source?.cancel() }   // cancel handler 各自 close(fd)
        Log.agent.info("stop watch session=\(sessionID, privacy: .public) agents=\(watch.files.count)")
    }

    // MARK: - Directory scan → per-file watch

    /// 目录有变(新增 agent-*.jsonl)时触发。只负责发现新文件并装 per-file 监听;
    /// 已存在文件的追加由各自的 file source 处理,不在这里。
    private func scanDir(sessionID: String) async {
        guard let watch = watched[sessionID] else { return }
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: watch.subagentsDir.path) else { return }
        for name in entries where name.hasSuffix(".jsonl") {
            guard let agentId = SubagentParsing.agentId(fromFileName: name) else { continue }
            guard watch.files[agentId] == nil else { continue }
            await startFileWatch(sessionID: sessionID, agentId: agentId, fileName: name)
        }
    }

    private func startFileWatch(sessionID: String, agentId: String, fileName: String) async {
        guard let watch = watched[sessionID] else { return }
        let fileURL = watch.subagentsDir.appendingPathComponent(fileName)
        let fd = open(fileURL.path, O_RDONLY)   // 要读,必须 O_RDONLY(O_EVTONLY 不能 read)
        guard fd >= 0 else { return }

        let fw = FileWatch(agentId: agentId, fd: fd, startedAt: now())
        let metaURL = watch.subagentsDir.appendingPathComponent("agent-\(agentId).meta.json")
        if let data = try? Data(contentsOf: metaURL) { fw.meta = SubagentParsing.parseMeta(data) }

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend], queue: queue
        )
        src.setEventHandler { @Sendable [weak self] in
            Task { await self?.readFile(sessionID: sessionID, agentId: agentId) }
        }
        src.setCancelHandler { close(fd) }
        fw.source = src
        watch.files[agentId] = fw
        src.resume()
        await readFile(sessionID: sessionID, agentId: agentId)   // 首读:从 offset 0 到 EOF
    }

    // MARK: - Incremental read

    /// 增量读一个子 agent 文件。绝不全量重解 —— 从已提交 offset lseek 到 EOF,只处理到最后一个换行,
    /// 末尾半行留到下次。读+推进 offset+累加是一段同步块(无 await),对本 actor 原子;唯一的 await 是
    /// 末尾推 store,此时 offset 已推进,重入的下一次 read 自然从新位置开始,不会双读。
    private func readFile(sessionID: String, agentId: String) async {
        guard let watch = watched[sessionID], let fw = watch.files[agentId], !fw.done else { return }

        lseek(fw.fd, fw.offset, SEEK_SET)
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = buf.withUnsafeMutableBytes { read(fw.fd, $0.baseAddress, $0.count) }
            if n <= 0 { break }
            data.append(contentsOf: buf[0..<n])
        }
        guard !data.isEmpty, let lastNL = data.lastIndex(of: 0x0A) else { return }
        let consumed = data.distance(from: data.startIndex, to: lastNL) + 1
        fw.offset += off_t(consumed)

        let chunk = String(decoding: data.prefix(consumed), as: UTF8.self)
        let records = SubagentParsing.records(from: chunk)
        let result = SubagentParsing.accumulate(into: &fw.usage, model: &fw.model, toolCalls: &fw.toolCalls, records: records)
        if result.terminalEndTurn {
            fw.status = .done
            fw.done = true
            fw.endedAt = result.lastTimestamp ?? now()
        }

        await store.upsertAgentRun(makeRun(fw, sessionID: sessionID))
        if fw.done { closeFile(watch: watch, agentId: agentId) }   // 完成即释放 fd,保留记录防重开
    }

    private func closeFile(watch: SessionWatch, agentId: String) {
        guard let fw = watch.files[agentId] else { return }
        fw.source?.cancel()   // cancel handler close(fd);done 后 readFile 提前 return,fd 不再被读
        fw.source = nil
    }

    private func makeRun(_ fw: FileWatch, sessionID: String) -> AgentRun {
        AgentRun(
            id: fw.agentId,
            sessionId: sessionID,
            toolUseId: fw.meta?.toolUseId,
            agentType: fw.meta?.agentType ?? "agent",
            description: fw.meta?.description ?? "",
            prompt: nil,                       // watcher 无 prompt;store.upsertAgentRun 从占位带过来
            model: fw.model,
            status: fw.status,
            startedAt: fw.startedAt,
            endedAt: fw.done ? (fw.endedAt ?? now()) : nil,
            usage: fw.usage,
            estCostUSD: ModelPricing.estimatedCostUSD(model: fw.model, usage: fw.usage),
            toolCalls: fw.toolCalls
        )
    }

    // MARK: - Pending-dir poll

    /// subagents 目录尚不存在时的兜底:低频轮询等它出现。单条循环,所有 pending 会话共用。
    /// 走注入 delay(默认 Task.sleep(nanoseconds:)) —— 禁用 Clock.sleep / Task.sleep(for:),见 commit fffadbc。
    private func startPollIfNeeded() {
        guard !pollRunning else { return }
        pollRunning = true
        Task { await self.pollLoop() }
    }

    private func pollLoop() async {
        while !pendingDirs.isEmpty {
            await delay(2 * 1_000_000_000)
            for (sid, transcriptPath) in pendingDirs {
                let dir = SubagentParsing.subagentsDir(forTranscriptPath: transcriptPath)
                guard FileManager.default.fileExists(atPath: dir.path) else { continue }
                pendingDirs.removeValue(forKey: sid)
                if watched[sid] == nil { await startDirWatch(sessionID: sid, dir: dir) }
            }
        }
        pollRunning = false
    }

    // MARK: - Test entry

    /// 测试入口:对给定 transcriptPath 的 subagents 目录做一次性全量扫描 + 读取 + upsert,
    /// 不依赖 kqueue 投递时序。复用与实时路径相同的解析 / 累加 / 计价积木。
    func scanOnce(transcriptPath: String) async {
        let dir = SubagentParsing.subagentsDir(forTranscriptPath: transcriptPath)
        let sessionID = URL(fileURLWithPath: transcriptPath).deletingPathExtension().lastPathComponent
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        for name in entries where name.hasSuffix(".jsonl") {
            guard let agentId = SubagentParsing.agentId(fromFileName: name),
                  let chunk = try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
            else { continue }
            var usage = TokenUsage()
            var model: String?
            var toolCalls: [AgentToolCall] = []
            let result = SubagentParsing.accumulate(
                into: &usage, model: &model, toolCalls: &toolCalls, records: SubagentParsing.records(from: chunk)
            )
            let meta = (try? Data(contentsOf: dir.appendingPathComponent("agent-\(agentId).meta.json")))
                .flatMap { SubagentParsing.parseMeta($0) }
            let run = AgentRun(
                id: agentId, sessionId: sessionID, toolUseId: meta?.toolUseId,
                agentType: meta?.agentType ?? "agent", description: meta?.description ?? "",
                prompt: nil, model: model,
                status: result.terminalEndTurn ? .done : .running,
                startedAt: now(),
                endedAt: result.terminalEndTurn ? (result.lastTimestamp ?? now()) : nil,
                usage: usage,
                estCostUSD: ModelPricing.estimatedCostUSD(model: model, usage: usage),
                toolCalls: toolCalls
            )
            await store.upsertAgentRun(run)
        }
    }
}

// MARK: - Per-session / per-file watch state（actor 隔离,持非 Sendable 的 DispatchSource,绝不跨边界逃逸）

private final class SessionWatch {
    let sessionID: String
    let subagentsDir: URL
    var dirSource: (any DispatchSourceFileSystemObject)?
    var files: [String: FileWatch] = [:]

    init(sessionID: String, subagentsDir: URL) {
        self.sessionID = sessionID
        self.subagentsDir = subagentsDir
    }
}

private final class FileWatch {
    let agentId: String
    var fd: Int32
    var source: (any DispatchSourceFileSystemObject)?
    var offset: off_t = 0
    var usage = TokenUsage()
    var toolCalls: [AgentToolCall] = []
    var model: String?
    var status: AgentRunStatus = .running
    var startedAt: Date
    var endedAt: Date?
    var meta: SubagentParsing.Meta?
    var done = false

    init(agentId: String, fd: Int32, startedAt: Date) {
        self.agentId = agentId
        self.fd = fd
        self.startedAt = startedAt
    }
}
