import Foundation
import JavaScriptCore
import Postbox
import SwiftSignalKit

/// AyuGram user scripts: JavaScript files run in JavaScriptCore with a small `ayu` API.
///
///     ayu.onOutgoing(function (msg) { return msg.text.toUpperCase() })   // return a string to replace the text
///     ayu.onIncoming(function (msg) { ayu.log(msg.authorName + ": " + msg.text) })
///     ayu.sendMessage(msg.peerId, "text")            // optional 3rd argument: message id to reply to
///     ayu.storage.set("key", "value"); ayu.storage.get("key")
///     ayu.log("anything", 1, 2)
///
/// `msg` has: text, peerId (string), id, date, authorId, authorName, chatTitle, outgoing, mediaType.
///
/// Also: fetch(url, {method, headers, body}) -> Promise, setTimeout/setInterval/clear*, console.log,
/// ayu.getHistory(peerId, limit) -> Promise<[msg]>, ayu.editMessage(peerId, id, text),
/// ayu.deleteMessages(peerId, [ids], forEveryone), ayu.react(peerId, id, emoji),
/// ayu.sendPhoto/sendFile/sendSticker(peerId, src, ...) -> Promise (src: http(s) URL, data: URL or base64),
/// ayu.forwardMessages(fromPeerId, [ids], toPeerId).
public final class AyuScripts: @unchecked Sendable {
    public struct Script: Codable, Equatable {
        public var id: String
        public var name: String
        public var enabled: Bool
    }

    public static let shared = AyuScripts()

    private let lock = NSRecursiveLock()
    let dispatchQueue = DispatchQueue(label: "AyuScripts")
    private var timers: [Int: DispatchSourceTimer] = [:]
    private var nextTimerId = 1
    private var context: JSContext?
    private var outgoingHandlers: [JSValue] = []
    private var incomingHandlers: [JSValue] = []
    private var isLoaded = false
    private weak var account: Account?
    private var logLines: [String] = []

    private init() {
    }

    // MARK: Storage

    private var directoryUrl: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let url = base.appendingPathComponent("ayu-scripts", isDirectory: true)
        let _ = try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
        return url
    }

    private var indexUrl: URL? {
        return self.directoryUrl?.appendingPathComponent("index.json")
    }

    private func codeUrl(id: String) -> URL? {
        return self.directoryUrl?.appendingPathComponent("\(id).js")
    }

    public func scripts() -> [Script] {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard let indexUrl = self.indexUrl, let data = try? Data(contentsOf: indexUrl) else {
            return []
        }
        return (try? JSONDecoder().decode([Script].self, from: data)) ?? []
    }

    private func saveScripts(_ scripts: [Script]) {
        guard let indexUrl = self.indexUrl, let data = try? JSONEncoder().encode(scripts) else {
            return
        }
        let _ = try? data.write(to: indexUrl, options: .atomic)
    }

    public func code(id: String) -> String? {
        guard let url = self.codeUrl(id: id), let data = try? Data(contentsOf: url) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    public func addScript(name: String, code: String) {
        self.lock.lock()
        defer { self.lock.unlock() }
        let id = UUID().uuidString
        guard let url = self.codeUrl(id: id), let data = code.data(using: .utf8) else {
            return
        }
        let _ = try? data.write(to: url, options: .atomic)
        var scripts = self.scripts()
        scripts.append(Script(id: id, name: name.isEmpty ? "script.js" : name, enabled: true))
        self.saveScripts(scripts)
        self.reload()
    }

    public func setEnabled(id: String, enabled: Bool) {
        self.lock.lock()
        defer { self.lock.unlock() }
        var scripts = self.scripts()
        if let index = scripts.firstIndex(where: { $0.id == id }) {
            scripts[index].enabled = enabled
        }
        self.saveScripts(scripts)
        self.reload()
    }

    public func deleteScript(id: String) {
        self.lock.lock()
        defer { self.lock.unlock() }
        if let url = self.codeUrl(id: id) {
            let _ = try? FileManager.default.removeItem(at: url)
        }
        self.saveScripts(self.scripts().filter { $0.id != id })
        self.reload()
    }

    public func logText() -> String {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.logLines.joined(separator: "\n")
    }

    public func clearLog() {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.logLines.removeAll()
    }

    func appendLog(_ line: String) {
        self.lock.lock()
        defer { self.lock.unlock() }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        self.logLines.append("[\(formatter.string(from: Date()))] \(line)")
        if self.logLines.count > 300 {
            self.logLines.removeFirst(self.logLines.count - 300)
        }
    }

    // MARK: Engine

    func register(account: Account) {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.account = account
    }

    /// Rebuilds the JavaScript context from the enabled scripts.
    public func reload() {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.outgoingHandlers.removeAll()
        self.incomingHandlers.removeAll()
        for (_, timer) in self.timers {
            timer.cancel()
        }
        self.timers.removeAll()
        self.context = nil
        self.isLoaded = true

        let enabledScripts = self.scripts().filter { $0.enabled }
        if enabledScripts.isEmpty {
            return
        }
        guard let context = JSContext() else {
            return
        }
        context.exceptionHandler = { [weak self] _, exception in
            self?.appendLog("Ошибка: \(exception?.toString() ?? "?")")
        }
        self.installApi(context: context)
        let _ = context.evaluateScript(ayuScriptsPrelude, withSourceURL: URL(string: "ayu://prelude.js"))
        self.context = context

        for script in enabledScripts {
            guard let code = self.code(id: script.id) else {
                continue
            }
            let _ = context.evaluateScript(code, withSourceURL: URL(string: "ayu://\(script.name)"))
        }
        self.appendLog("Загружено скриптов: \(enabledScripts.count)")
    }

    private func ensureLoaded() {
        if !self.isLoaded {
            self.reload()
        }
    }

    private func installApi(context: JSContext) {
        guard let ayu = JSValue(newObjectIn: context) else {
            return
        }

        let log: @convention(block) () -> Void = { [weak self] in
            let args = (JSContext.currentArguments() as? [JSValue]) ?? []
            self?.appendLog(args.map { $0.toString() ?? "" }.joined(separator: " "))
        }
        ayu.setObject(unsafeBitCast(log, to: AnyObject.self), forKeyedSubscript: "log" as NSString)

        let onOutgoing: @convention(block) (JSValue) -> Void = { [weak self] handler in
            self?.outgoingHandlers.append(handler)
        }
        ayu.setObject(unsafeBitCast(onOutgoing, to: AnyObject.self), forKeyedSubscript: "onOutgoing" as NSString)

        let onIncoming: @convention(block) (JSValue) -> Void = { [weak self] handler in
            self?.incomingHandlers.append(handler)
        }
        ayu.setObject(unsafeBitCast(onIncoming, to: AnyObject.self), forKeyedSubscript: "onIncoming" as NSString)

        let sendMessage: @convention(block) (String, String, JSValue) -> Void = { [weak self] peerIdString, text, replyTo in
            var replyToId: Int32?
            if replyTo.isNumber {
                replyToId = replyTo.toInt32()
            }
            self?.sendMessage(peerIdString: peerIdString, text: text, replyToId: replyToId)
        }
        ayu.setObject(unsafeBitCast(sendMessage, to: AnyObject.self), forKeyedSubscript: "sendMessage" as NSString)

        if let storage = JSValue(newObjectIn: context) {
            let get: @convention(block) (String) -> String? = { key in
                return UserDefaults.standard.string(forKey: "ayu.script.storage.\(key)")
            }
            let set: @convention(block) (String, String) -> Void = { key, value in
                UserDefaults.standard.set(value, forKey: "ayu.script.storage.\(key)")
            }
            storage.setObject(unsafeBitCast(get, to: AnyObject.self), forKeyedSubscript: "get" as NSString)
            storage.setObject(unsafeBitCast(set, to: AnyObject.self), forKeyedSubscript: "set" as NSString)
            ayu.setObject(storage, forKeyedSubscript: "storage" as NSString)
        }

        self.installExtendedApi(ayu: ayu)
        context.setObject(ayu, forKeyedSubscript: "ayu" as NSString)
    }

    func scriptMessageObject(_ message: Message) -> [String: Any] {
        var result: [String: Any] = [
            "text": message.text,
            "peerId": "\(message.id.peerId.toInt64())",
            "id": Int(message.id.id),
            "date": Int(message.timestamp),
            "outgoing": !message.flags.contains(.Incoming),
            "mediaType": ayuMediaType(message.media)
        ]
        if let author = message.author {
            result["authorId"] = "\(author.id.toInt64())"
            result["authorName"] = author.debugDisplayTitle
        }
        if let peer = message.peers[message.id.peerId] {
            result["chatTitle"] = peer.debugDisplayTitle
        }
        return result
    }

    /// Outgoing hook: returns the text to send instead, or nil to keep it.
    func transformOutgoing(text: String, peerId: PeerId) -> String? {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.ensureLoaded()
        if self.outgoingHandlers.isEmpty {
            return nil
        }
        var currentText = text
        var changed = false
        for handler in self.outgoingHandlers {
            let msg: [String: Any] = ["text": currentText, "peerId": "\(peerId.toInt64())", "outgoing": true]
            if let result = handler.call(withArguments: [msg]), result.isString, let value = result.toString() {
                currentText = value
                changed = true
            }
        }
        return changed ? currentText : nil
    }

    /// Incoming hook, called off the postbox queue with the newly received messages.
    func handleIncoming(_ messages: [Message]) {
        self.dispatchQueue.async {
            self.lock.lock()
            defer { self.lock.unlock() }
            self.ensureLoaded()
            if self.incomingHandlers.isEmpty {
                return
            }
            for message in messages {
                let msg = self.scriptMessageObject(message)
                for handler in self.incomingHandlers {
                    let _ = handler.call(withArguments: [msg])
                }
            }
        }
    }

    var hasIncomingHandlers: Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.ensureLoaded()
        return !self.incomingHandlers.isEmpty
    }

    /// Calls a JavaScript callback later on the scripts queue, holding the engine lock.
    func callBack(_ callback: JSValue, _ arguments: [Any]) {
        self.dispatchQueue.async {
            self.callNow(callback, arguments)
        }
    }
    
    /// Calls a JavaScript function now, holding the engine lock.
    func callNow(_ function: JSValue, _ arguments: [Any]) {
        self.lock.lock()
        defer { self.lock.unlock() }
        let _ = function.call(withArguments: arguments)
    }
    
    func currentAccount() -> Account? {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.account
    }
    
    func storeTimer(_ timer: DispatchSourceTimer) -> Int {
        self.lock.lock()
        defer { self.lock.unlock() }
        let id = self.nextTimerId
        self.nextTimerId += 1
        self.timers[id] = timer
        return id
    }
    
    func removeTimer(id: Int) {
        self.lock.lock()
        defer { self.lock.unlock() }
        if let timer = self.timers.removeValue(forKey: id) {
            timer.cancel()
        }
    }
    
    private func sendMessage(peerIdString: String, text: String, replyToId: Int32?) {
        guard let account = self.account, let rawPeerId = Int64(peerIdString), !text.isEmpty else {
            self.appendLog("sendMessage: неверный peerId или пустой текст")
            return
        }
        let peerId = PeerId(rawPeerId)
        var replySubject: EngineMessageReplySubject?
        if let replyToId = replyToId {
            replySubject = EngineMessageReplySubject(messageId: MessageId(peerId: peerId, namespace: Namespaces.Message.Cloud, id: replyToId), quote: nil, innerSubject: nil)
        }
        let _ = enqueueMessages(account: account, peerId: peerId, messages: [.message(text: text, attributes: [], inlineStickers: [:], mediaReference: nil, threadId: nil, replyToMessageId: replySubject, replyToStoryId: nil, localGroupingKey: nil, correlationId: nil, bubbleUpEmojiOrStickersets: [])]).start()
    }
}
