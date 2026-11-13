import Foundation
import JavaScriptCore
import ImageIO
import Postbox
import SwiftSignalKit
import TelegramApi

// AyuGram user scripts: network, timers, history, edit/delete/react, media and forwarding.

let ayuScriptsPrelude = """
(function () {
    var g = globalThis;
    g.console = { log: ayu.log, error: ayu.log, warn: ayu.log, info: ayu.log };
    g.setTimeout = function (fn, ms) {
        var args = Array.prototype.slice.call(arguments, 2);
        return ayu._setTimer(function () { fn.apply(null, args); }, ms || 0, false);
    };
    g.setInterval = function (fn, ms) {
        var args = Array.prototype.slice.call(arguments, 2);
        return ayu._setTimer(function () { fn.apply(null, args); }, ms || 0, true);
    };
    g.clearTimeout = function (id) { if (id) { ayu._clearTimer(id); } };
    g.clearInterval = g.clearTimeout;
    function promisify(f) {
        return function () {
            var args = Array.prototype.slice.call(arguments);
            return new Promise(function (resolve, reject) {
                args.push(function (err, res) { if (err) { reject(new Error(err)); } else { resolve(res); } });
                f.apply(null, args);
            });
        };
    }
    g.fetch = function (url, opts) {
        return new Promise(function (resolve, reject) {
            ayu._fetch(String(url), opts || {}, function (err, res) {
                if (err) { reject(new Error(err)); return; }
                resolve({
                    status: res.status,
                    ok: res.status >= 200 && res.status < 300,
                    headers: res.headers,
                    text: function () { return Promise.resolve(res.body); },
                    json: function () { return Promise.resolve(JSON.parse(res.body)); }
                });
            });
        });
    };
    ayu.getHistory = promisify(ayu._getHistory);
    ayu.sendMedia = promisify(ayu._sendMedia);
    ayu.sendPhoto = function (peerId, src, caption, replyTo) {
        return ayu.sendMedia(peerId, { src: src, type: "photo", caption: caption || "", replyTo: replyTo });
    };
    ayu.sendFile = function (peerId, src, fileName, caption, replyTo) {
        return ayu.sendMedia(peerId, { src: src, type: "file", fileName: fileName || "file", caption: caption || "", replyTo: replyTo });
    };
    ayu.sendSticker = function (peerId, src, replyTo) {
        return ayu.sendMedia(peerId, { src: src, type: "sticker", replyTo: replyTo });
    };
})();
"""

func ayuMediaType(_ media: [Media]) -> String {
    for item in media {
        if item is TelegramMediaImage {
            return "photo"
        } else if let file = item as? TelegramMediaFile {
            if file.isSticker {
                return "sticker"
            } else if file.isVoice {
                return "voice"
            } else if file.isInstantVideo {
                return "videoMessage"
            } else if file.isVideo {
                return "video"
            } else {
                return "file"
            }
        }
    }
    return ""
}

private func ayuImageDimensions(_ data: Data) -> PixelDimensions? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil), let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
        return nil
    }
    guard let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int else {
        return nil
    }
    return PixelDimensions(width: Int32(width), height: Int32(height))
}

private func ayuDecodeDataSource(_ src: String) -> Data? {
    if src.hasPrefix("data:") {
        guard let comma = src.firstIndex(of: ",") else {
            return nil
        }
        return Data(base64Encoded: String(src[src.index(after: comma)...]), options: .ignoreUnknownCharacters)
    }
    return Data(base64Encoded: src, options: .ignoreUnknownCharacters)
}

private func ayuJSIntList(_ value: JSValue) -> [Int32] {
    guard let array = value.toArray() else {
        return []
    }
    return array.compactMap { ($0 as? NSNumber)?.int32Value }
}

private func ayuJSString(_ value: JSValue?, _ key: String) -> String? {
    guard let property = value?.forProperty(key), property.isString else {
        return nil
    }
    return property.toString()
}

extension AyuScripts {
    func installExtendedApi(ayu: JSValue) {
        let fetch: @convention(block) (String, JSValue, JSValue) -> Void = { [weak self] url, options, callback in
            self?.scriptFetch(url: url, options: options, callback: callback)
        }
        ayu.setObject(unsafeBitCast(fetch, to: AnyObject.self), forKeyedSubscript: "_fetch" as NSString)

        let setTimer: @convention(block) (JSValue, Double, Bool) -> Int = { [weak self] function, milliseconds, isRepeating in
            return self?.scriptSetTimer(function: function, milliseconds: milliseconds, isRepeating: isRepeating) ?? 0
        }
        ayu.setObject(unsafeBitCast(setTimer, to: AnyObject.self), forKeyedSubscript: "_setTimer" as NSString)

        let clearTimer: @convention(block) (Int) -> Void = { [weak self] id in
            self?.removeTimer(id: id)
        }
        ayu.setObject(unsafeBitCast(clearTimer, to: AnyObject.self), forKeyedSubscript: "_clearTimer" as NSString)

        let getHistory: @convention(block) (String, Int, JSValue) -> Void = { [weak self] peerIdString, limit, callback in
            self?.scriptGetHistory(peerIdString: peerIdString, limit: limit, callback: callback)
        }
        ayu.setObject(unsafeBitCast(getHistory, to: AnyObject.self), forKeyedSubscript: "_getHistory" as NSString)

        let editMessage: @convention(block) (String, Int32, String) -> Void = { [weak self] peerIdString, id, text in
            self?.scriptEditMessage(peerIdString: peerIdString, id: id, text: text)
        }
        ayu.setObject(unsafeBitCast(editMessage, to: AnyObject.self), forKeyedSubscript: "editMessage" as NSString)

        let deleteMessages: @convention(block) (String, JSValue, Bool) -> Void = { [weak self] peerIdString, ids, forEveryone in
            self?.scriptDeleteMessages(peerIdString: peerIdString, ids: ayuJSIntList(ids), forEveryone: forEveryone)
        }
        ayu.setObject(unsafeBitCast(deleteMessages, to: AnyObject.self), forKeyedSubscript: "deleteMessages" as NSString)

        let react: @convention(block) (String, Int32, String) -> Void = { [weak self] peerIdString, id, emoji in
            self?.scriptReact(peerIdString: peerIdString, id: id, emoji: emoji)
        }
        ayu.setObject(unsafeBitCast(react, to: AnyObject.self), forKeyedSubscript: "react" as NSString)

        let sendMedia: @convention(block) (String, JSValue, JSValue) -> Void = { [weak self] peerIdString, options, callback in
            self?.scriptSendMedia(peerIdString: peerIdString, options: options, callback: callback)
        }
        ayu.setObject(unsafeBitCast(sendMedia, to: AnyObject.self), forKeyedSubscript: "_sendMedia" as NSString)

        let forwardMessages: @convention(block) (String, JSValue, String) -> Void = { [weak self] fromPeerIdString, ids, toPeerIdString in
            self?.scriptForwardMessages(fromPeerIdString: fromPeerIdString, ids: ayuJSIntList(ids), toPeerIdString: toPeerIdString)
        }
        ayu.setObject(unsafeBitCast(forwardMessages, to: AnyObject.self), forKeyedSubscript: "forwardMessages" as NSString)
        
        let scheduleMessage: @convention(block) (String, String, Double) -> Void = { [weak self] peerIdString, text, time in
            self?.scriptScheduleMessage(peerIdString: peerIdString, text: text, time: Int32(clamping: Int64(time)))
        }
        ayu.setObject(unsafeBitCast(scheduleMessage, to: AnyObject.self), forKeyedSubscript: "scheduleMessage" as NSString)
    }

    private func parsePeerId(_ string: String) -> PeerId? {
        guard let raw = Int64(string) else {
            self.appendLog("неверный peerId: \(string)")
            return nil
        }
        return PeerId(raw)
    }

    private func scriptFetch(url: String, options: JSValue, callback: JSValue) {
        guard let requestUrl = URL(string: url) else {
            self.callBack(callback, ["неверный URL"])
            return
        }
        var request = URLRequest(url: requestUrl)
        if let method = ayuJSString(options, "method") {
            request.httpMethod = method
        }
        if let headers = options.forProperty("headers"), headers.isObject, let dict = headers.toDictionary() {
            for (key, value) in dict {
                request.setValue("\(value)", forHTTPHeaderField: "\(key)")
            }
        }
        if let body = ayuJSString(options, "body") {
            request.httpBody = body.data(using: .utf8)
        }
        URLSession.shared.dataTask(with: request, completionHandler: { [weak self] data, response, error in
            guard let self = self else {
                return
            }
            if let error = error {
                self.callBack(callback, [error.localizedDescription])
                return
            }
            var headers: [String: String] = [:]
            var status = 0
            if let httpResponse = response as? HTTPURLResponse {
                status = httpResponse.statusCode
                for (key, value) in httpResponse.allHeaderFields {
                    headers["\(key)".lowercased()] = "\(value)"
                }
            }
            let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let result: [String: Any] = ["status": status, "headers": headers, "body": body]
            self.callBack(callback, [NSNull(), result])
        }).resume()
    }

    private func scriptSetTimer(function: JSValue, milliseconds: Double, isRepeating: Bool) -> Int {
        let timer = DispatchSource.makeTimerSource(queue: self.dispatchQueue)
        let interval = DispatchTimeInterval.milliseconds(max(1, Int(milliseconds)))
        if isRepeating {
            timer.schedule(deadline: .now() + interval, repeating: interval)
        } else {
            timer.schedule(deadline: .now() + interval)
        }
        let id = self.storeTimer(timer)
        timer.setEventHandler { [weak self] in
            guard let self = self else {
                return
            }
            if !isRepeating {
                self.removeTimer(id: id)
            }
            self.callNow(function, [])
        }
        timer.resume()
        return id
    }

    private func scriptGetHistory(peerIdString: String, limit: Int, callback: JSValue) {
        guard let account = self.currentAccount(), let peerId = self.parsePeerId(peerIdString) else {
            self.callBack(callback, ["нет аккаунта или неверный peerId"])
            return
        }
        let accountPeerId = account.peerId
        let network = account.network
        let requestLimit = Int32(max(1, min(limit, 100)))
        let _ = (account.postbox.transaction { transaction -> Peer? in
            return transaction.getPeer(peerId)
        }
        |> mapToSignal { peer -> Signal<[Message], NoError> in
            guard let peer = peer, let inputPeer = apiInputPeer(peer) else {
                return .single([])
            }
            return network.request(Api.functions.messages.getHistory(peer: inputPeer, offsetId: 0, offsetDate: 0, addOffset: 0, limit: requestLimit, maxId: 0, minId: 0, hash: 0))
            |> map(Optional.init)
            |> `catch` { _ -> Signal<Api.messages.Messages?, NoError> in
                return .single(nil)
            }
            |> map { result -> [Message] in
                guard let result = result else {
                    return []
                }
                let apiMessages: [Api.Message]
                let apiChats: [Api.Chat]
                let apiUsers: [Api.User]
                switch result {
                case let .messages(messagesData):
                    apiMessages = messagesData.messages
                    apiChats = messagesData.chats
                    apiUsers = messagesData.users
                case let .messagesSlice(messagesSliceData):
                    apiMessages = messagesSliceData.messages
                    apiChats = messagesSliceData.chats
                    apiUsers = messagesSliceData.users
                case let .channelMessages(channelMessagesData):
                    apiMessages = channelMessagesData.messages
                    apiChats = channelMessagesData.chats
                    apiUsers = channelMessagesData.users
                case .messagesNotModified:
                    return []
                }
                var peers: [PeerId: Peer] = [peer.id: peer]
                for chat in apiChats {
                    if let groupOrChannel = parseTelegramGroupOrChannel(chat: chat) {
                        peers[groupOrChannel.id] = groupOrChannel
                    }
                }
                for user in apiUsers {
                    let telegramUser = TelegramUser(user: user)
                    peers[telegramUser.id] = telegramUser
                }
                var messages: [Message] = []
                for apiMessage in apiMessages {
                    if let storeMessage = StoreMessage(apiMessage: apiMessage, accountPeerId: accountPeerId, peerIsForum: peer.isForum), let message = locallyRenderedMessage(message: storeMessage, peers: peers) {
                        messages.append(message)
                    }
                }
                return messages
            }
        }).start(next: { [weak self] messages in
            guard let self = self else {
                return
            }
            let objects = messages.map { self.scriptMessageObject($0) }
            self.callBack(callback, [NSNull(), objects])
        })
    }

    private func scriptEditMessage(peerIdString: String, id: Int32, text: String) {
        guard let account = self.currentAccount(), let peerId = self.parsePeerId(peerIdString) else {
            return
        }
        let messageId = MessageId(peerId: peerId, namespace: Namespaces.Message.Cloud, id: id)
        let _ = _internal_requestEditMessage(account: account, messageId: messageId, text: text, media: .keep, entities: nil, richText: nil, inlineStickers: [:], webpagePreviewAttribute: nil, disableUrlPreview: false, scheduleInfoAttribute: nil, invertMediaAttribute: nil).start(error: { [weak self] _ in
            self?.appendLog("editMessage: не удалось изменить \(id)")
        })
    }

    private func scriptDeleteMessages(peerIdString: String, ids: [Int32], forEveryone: Bool) {
        guard let account = self.currentAccount(), let peerId = self.parsePeerId(peerIdString), !ids.isEmpty else {
            return
        }
        let messageIds = ids.map { MessageId(peerId: peerId, namespace: Namespaces.Message.Cloud, id: $0) }
        let _ = _internal_deleteMessagesInteractively(account: account, messageIds: messageIds, type: forEveryone ? .forEveryone : .forLocalPeer).start()
    }

    private func scriptReact(peerIdString: String, id: Int32, emoji: String) {
        guard let account = self.currentAccount(), let peerId = self.parsePeerId(peerIdString) else {
            return
        }
        let messageId = MessageId(peerId: peerId, namespace: Namespaces.Message.Cloud, id: id)
        let reactions: [UpdateMessageReaction] = emoji.isEmpty ? [] : [.builtin(emoji)]
        let _ = updateMessageReactionsInteractively(account: account, messageIds: [messageId], reactions: reactions, isLarge: false, storeAsRecentlyUsed: false).start()
    }

    private func scriptForwardMessages(fromPeerIdString: String, ids: [Int32], toPeerIdString: String) {
        guard let account = self.currentAccount(), let fromPeerId = self.parsePeerId(fromPeerIdString), let toPeerId = self.parsePeerId(toPeerIdString), !ids.isEmpty else {
            return
        }
        let messages: [EnqueueMessage] = ids.map { .forward(source: MessageId(peerId: fromPeerId, namespace: Namespaces.Message.Cloud, id: $0), threadId: nil, grouping: .auto, attributes: [], correlationId: nil) }
        let _ = enqueueMessages(account: account, peerId: toPeerId, messages: messages).start()
    }

    /// Sends a message as scheduled for `time` (unix seconds): the server delivers it even when
    /// the app is not running.
    private func scriptScheduleMessage(peerIdString: String, text: String, time: Int32) {
        guard let account = self.currentAccount(), let peerId = self.parsePeerId(peerIdString), !text.isEmpty else {
            return
        }
        let attributes: [MessageAttribute] = [OutgoingScheduleInfoMessageAttribute(scheduleTime: time, repeatPeriod: nil)]
        let _ = enqueueMessages(account: account, peerId: peerId, messages: [.message(text: text, attributes: attributes, inlineStickers: [:], mediaReference: nil, threadId: nil, replyToMessageId: nil, replyToStoryId: nil, localGroupingKey: nil, correlationId: nil, bubbleUpEmojiOrStickersets: [])]).start()
    }
    
    private func scriptSendMedia(peerIdString: String, options: JSValue, callback: JSValue) {
        guard let account = self.currentAccount(), let peerId = self.parsePeerId(peerIdString) else {
            self.callBack(callback, ["нет аккаунта или неверный peerId"])
            return
        }
        let src = ayuJSString(options, "src") ?? ""
        let type = ayuJSString(options, "type") ?? "file"
        let fileName = ayuJSString(options, "fileName")
        let mimeType = ayuJSString(options, "mimeType")
        let caption = ayuJSString(options, "caption") ?? ""
        var replyTo: Int32?
        if let value = options.forProperty("replyTo"), value.isNumber {
            replyTo = value.toInt32()
        }

        let send: (Data) -> Void = { [weak self] data in
            let resource = LocalFileMediaResource(fileId: Int64.random(in: Int64.min ... Int64.max))
            account.postbox.mediaBox.storeResourceData(resource.id, data: data, synchronous: true)
            let media: Media
            switch type {
            case "photo":
                let dimensions = ayuImageDimensions(data) ?? PixelDimensions(width: 1280, height: 1280)
                media = TelegramMediaImage(imageId: MediaId(namespace: Namespaces.Media.LocalImage, id: Int64.random(in: Int64.min ... Int64.max)), representations: [TelegramMediaImageRepresentation(dimensions: dimensions, resource: resource, progressiveSizes: [], immediateThumbnailData: nil, hasVideo: false, isPersonal: false)], immediateThumbnailData: nil, reference: nil, partialReference: nil, flags: [])
            case "sticker":
                let dimensions = ayuImageDimensions(data) ?? PixelDimensions(width: 512, height: 512)
                media = TelegramMediaFile(fileId: MediaId(namespace: Namespaces.Media.LocalFile, id: Int64.random(in: Int64.min ... Int64.max)), partialReference: nil, resource: resource, previewRepresentations: [], videoThumbnails: [], immediateThumbnailData: nil, mimeType: mimeType ?? "image/webp", size: Int64(data.count), attributes: [.FileName(fileName: fileName ?? "sticker.webp"), .Sticker(displayText: "", packReference: nil, maskData: nil), .ImageSize(size: dimensions)], alternativeRepresentations: [])
            default:
                media = TelegramMediaFile(fileId: MediaId(namespace: Namespaces.Media.LocalFile, id: Int64.random(in: Int64.min ... Int64.max)), partialReference: nil, resource: resource, previewRepresentations: [], videoThumbnails: [], immediateThumbnailData: nil, mimeType: mimeType ?? "application/octet-stream", size: Int64(data.count), attributes: [.FileName(fileName: fileName ?? "file")], alternativeRepresentations: [])
            }
            var replySubject: EngineMessageReplySubject?
            if let replyTo = replyTo {
                replySubject = EngineMessageReplySubject(messageId: MessageId(peerId: peerId, namespace: Namespaces.Message.Cloud, id: replyTo), quote: nil, innerSubject: nil)
            }
            let _ = enqueueMessages(account: account, peerId: peerId, messages: [.message(text: caption, attributes: [], inlineStickers: [:], mediaReference: .standalone(media: media), threadId: nil, replyToMessageId: replySubject, replyToStoryId: nil, localGroupingKey: nil, correlationId: nil, bubbleUpEmojiOrStickersets: [])]).start(next: { _ in
                self?.callBack(callback, [NSNull(), true])
            })
        }

        if src.hasPrefix("http://") || src.hasPrefix("https://"), let url = URL(string: src) {
            URLSession.shared.dataTask(with: url, completionHandler: { [weak self] data, _, error in
                if let data = data, error == nil {
                    send(data)
                } else {
                    self?.callBack(callback, ["не удалось скачать \(src)"])
                }
            }).resume()
        } else if let data = ayuDecodeDataSource(src), !data.isEmpty {
            send(data)
        } else {
            self.callBack(callback, ["src должен быть URL, data: URL или base64"])
        }
    }
}
