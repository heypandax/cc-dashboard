import Foundation
import Hummingbird
import HummingbirdWebSocket
import NIOWebSocket

struct DashboardHTTPServer: Sendable {
    let store: SessionStore
    let port: Int

    init(store: SessionStore, port: Int = 7788) {
        self.store = store
        self.port = port
    }

    func run() async throws {
        try await buildApplication().runService()
    }

    func buildApplication() -> some ApplicationProtocol {
        let router = Router(context: BasicWebSocketRequestContext.self)
        let hooks = HookHandlers(store: store)

        router.get("/") { _, _ -> String in
            "cc-dashboard 0.1.0 — GET /sessions · /approvals · WS /ws"
        }
        router.get("/health") { _, _ -> String in "ok" }

        // Hook endpoints
        router.post("/hook/session-start") { request, context -> HookAckResponse in
            let input = try await request.decode(as: HookInput.self, context: context)
            return await hooks.sessionStart(input)
        }
        router.post("/hook/pre-tool-use") { request, context -> HookOutput in
            let input = try await request.decode(as: HookInput.self, context: context)
            return await hooks.preToolUse(input)
        }
        router.post("/hook/notification") { request, context -> HookAckResponse in
            let input = try await request.decode(as: HookInput.self, context: context)
            return await hooks.notification(input)
        }
        router.post("/hook/stop") { request, context -> HookAckResponse in
            let input = try await request.decode(as: HookInput.self, context: context)
            return await hooks.stop(input)
        }
        router.post("/hook/session-end") { request, context -> HookAckResponse in
            let input = try await request.decode(as: HookInput.self, context: context)
            return await hooks.sessionEnd(input)
        }
        router.post("/hook/user-prompt-submit") { request, context -> HookAckResponse in
            let input = try await request.decode(as: HookInput.self, context: context)
            return await hooks.userPromptSubmit(input)
        }

        // Decision from UI
        router.post("/decision/:id") { request, context -> HookAckResponse in
            let id = try context.parameters.require("id")
            let decision = try await request.decode(as: DecisionRequest.self, context: context)
            await store.resolveApproval(
                id: id,
                decision: decision.decision,
                reason: decision.reason,
                trustMinutes: decision.trustMinutes,
                trustForever: decision.trustForever ?? false
            )
            return HookAckResponse(ok: true)
        }

        // Trust grant (UI 可以在无 pending approval 时也为 session 开 auto-allow 窗口)
        router.post("/trust/:sessionId") { request, context -> HookAckResponse in
            let sid = try context.parameters.require("sessionId")
            let body = try await request.decode(as: TrustRequest.self, context: context)
            await store.setAutoAllow(sessionID: sid, minutes: body.minutes)
            return HookAckResponse(ok: true)
        }

        // 永久信任 —— 不带 body,语义上是显式的 "never expire"。
        router.post("/trust/:sessionId/forever") { _, context -> HookAckResponse in
            let sid = try context.parameters.require("sessionId")
            await store.setAutoAllowForever(sessionID: sid)
            return HookAckResponse(ok: true)
        }

        router.delete("/trust/:sessionId") { _, context -> HookAckResponse in
            let sid = try context.parameters.require("sessionId")
            await store.clearAutoAllow(sessionID: sid)
            return HookAckResponse(ok: true)
        }

        // Alias: cwd-binding 在 store 侧做,route 按 sessionId 暴露(cwd 走 URL 不友好)。
        // body 的 alias 为 null / 空串 → 清除。
        router.put("/sessions/:id/alias") { request, context -> HookAckResponse in
            let sid = try context.parameters.require("id")
            let body = try await request.decode(as: AliasRequest.self, context: context)
            await store.setSessionAliasById(sessionID: sid, alias: body.alias)
            return HookAckResponse(ok: true)
        }

        router.delete("/sessions/:id/alias") { _, context -> HookAckResponse in
            let sid = try context.parameters.require("id")
            await store.setSessionAliasById(sessionID: sid, alias: nil)
            return HookAckResponse(ok: true)
        }

        router.get("/sessions") { _, _ -> [SessionState] in
            await store.allSessions()
        }
        router.get("/approvals") { _, _ -> [ApprovalRequest] in
            await store.allApprovals()
        }

        // WebSocket: snapshot on connect, then push all events as they happen
        let storeRef = store
        router.ws("/ws") { inbound, outbound, _ in
            let stream = await storeRef.subscribe()
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601

            let sendTask = Task {
                for await event in stream {
                    if Task.isCancelled { return }
                    do {
                        let data = try encoder.encode(event)
                        if let text = String(data: data, encoding: .utf8) {
                            try await outbound.write(.text(text))
                        }
                    } catch {
                        return
                    }
                }
            }

            // Block until client closes
            do {
                for try await _ in inbound { }
            } catch { }

            sendTask.cancel()
        }

        return Application(
            router: router,
            server: .http1WebSocketUpgrade(webSocketRouter: router),
            configuration: .init(
                address: .hostname("127.0.0.1", port: port),
                serverName: "cc-dashboard"
            )
        )
    }
}

struct HookAckResponse: Codable, ResponseEncodable, Sendable {
    let ok: Bool
}

/// PUT /sessions/:id/alias body。alias 为 nil(JSON null / 缺字段)或空串视作清空。
struct AliasRequest: Codable, Sendable {
    let alias: String?
}

extension HookOutput: ResponseEncodable {}
extension SessionState: ResponseEncodable {}
extension ApprovalRequest: ResponseEncodable {}
extension HookInput: ResponseCodable {}
extension DecisionRequest: ResponseCodable {}
extension TrustRequest: ResponseCodable {}
extension AliasRequest: ResponseCodable {}
