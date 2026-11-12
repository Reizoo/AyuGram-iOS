import Foundation
import Postbox
import TelegramApi
import SwiftSignalKit

/// AyuGram client-side settings. Stored in UserDefaults so that any thread
/// (network, postbox) can read them synchronously.
public enum AyuSettings {
    private static var defaults: UserDefaults {
        return UserDefaults.standard
    }

    private static func bool(_ key: String, default defaultValue: Bool) -> Bool {
        if defaults.object(forKey: key) == nil {
            return defaultValue
        }
        return defaults.bool(forKey: key)
    }

    /// Send "online" status updates. When false the client reports itself offline.
    public static var sendOnlinePackets: Bool {
        get { return bool("ayu.sendOnlinePackets", default: true) }
        set { defaults.set(newValue, forKey: "ayu.sendOnlinePackets") }
    }

    /// Send "typing…" and other input activities.
    public static var sendTyping: Bool {
        get { return bool("ayu.sendTyping", default: true) }
        set { defaults.set(newValue, forKey: "ayu.sendTyping") }
    }

    /// Send read receipts for messages.
    public static var sendReadMessages: Bool {
        get { return bool("ayu.sendReadMessages", default: true) }
        set { defaults.set(newValue, forKey: "ayu.sendReadMessages") }
    }

    /// Send read receipts for stories.
    public static var sendReadStories: Bool {
        get { return bool("ayu.sendReadStories", default: true) }
        set { defaults.set(newValue, forKey: "ayu.sendReadStories") }
    }

    /// All four ghost mode switches (online, typing, read messages, read stories) are off.
    public static var isGhostModeEnabled: Bool {
        return !sendOnlinePackets && !sendTyping && !sendReadMessages && !sendReadStories
    }

    public static func setGhostModeEnabled(_ enabled: Bool) {
        sendOnlinePackets = !enabled
        sendTyping = !enabled
        sendReadMessages = !enabled
        sendReadStories = !enabled
    }

    /// With read receipts off, still mark the chat as read when sending a message to it.
    public static var markReadAfterSend: Bool {
        get { return bool("ayu.markReadAfterSend", default: true) }
        set { defaults.set(newValue, forKey: "ayu.markReadAfterSend") }
    }

    /// Keep self-destructing (view once / timer) photos and videos after they are viewed.
    public static var saveSelfDestructingMedia: Bool {
        get { return bool("ayu.saveSelfDestructingMedia", default: true) }
        set { defaults.set(newValue, forKey: "ayu.saveSelfDestructingMedia") }
    }

    /// Do not load sponsored messages in channels.
    public static var hideSponsoredMessages: Bool {
        get { return bool("ayu.hideSponsoredMessages", default: true) }
        set { defaults.set(newValue, forKey: "ayu.hideSponsoredMessages") }
    }

    /// Keep messages that other people deleted.
    public static var saveDeletedMessages: Bool {
        get { return bool("ayu.saveDeletedMessages", default: true) }
        set { defaults.set(newValue, forKey: "ayu.saveDeletedMessages") }
    }

    /// Keep previous versions of edited messages.
    public static var saveEditHistory: Bool {
        get { return bool("ayu.saveEditHistory", default: true) }
        set { defaults.set(newValue, forKey: "ayu.saveEditHistory") }
    }
}

/// Marks a message that was deleted on the server but kept locally.
public final class AyuDeletedMessageAttribute: MessageAttribute {
    public let date: Int32

    public init(date: Int32) {
        self.date = date
    }

    required public init(decoder: PostboxDecoder) {
        self.date = decoder.decodeInt32ForKey("d", orElse: 0)
    }

    public func encode(_ encoder: PostboxEncoder) {
        encoder.encodeInt32(self.date, forKey: "d")
    }
}

/// Previous texts of an edited message, oldest first. `dates[i]` is when `texts[i]` was replaced.
public final class AyuEditHistoryMessageAttribute: MessageAttribute {
    public let texts: [String]
    public let dates: [Int32]

    public init(texts: [String], dates: [Int32]) {
        self.texts = texts
        self.dates = dates
    }

    required public init(decoder: PostboxDecoder) {
        self.texts = decoder.decodeStringArrayForKey("t")
        self.dates = decoder.decodeInt32ArrayForKey("d")
    }

    public func encode(_ encoder: PostboxEncoder) {
        encoder.encodeStringArray(self.texts, forKey: "t")
        encoder.encodeInt32Array(self.dates, forKey: "d")
    }
}

public extension Message {
    var ayuDeletedAttribute: AyuDeletedMessageAttribute? {
        for attribute in self.attributes {
            if let attribute = attribute as? AyuDeletedMessageAttribute {
                return attribute
            }
        }
        return nil
    }

    var ayuEditHistoryAttribute: AyuEditHistoryMessageAttribute? {
        for attribute in self.attributes {
            if let attribute = attribute as? AyuEditHistoryMessageAttribute {
                return attribute
            }
        }
        return nil
    }
}

private func ayuCurrentTimestamp() -> Int32 {
    return Int32(CFAbsoluteTimeGetCurrent() + NSTimeIntervalSince1970)
}

/// Instead of deleting, marks the messages as deleted. Returns the ids that could not be
/// kept (not in the local database or service messages) and must be deleted normally.
func ayuMarkMessagesDeleted(transaction: Transaction, ids: [MessageId]) -> [MessageId] {
    var remaining: [MessageId] = []
    let timestamp = ayuCurrentTimestamp()
    for id in ids {
        guard let message = transaction.getMessage(id) else {
            remaining.append(id)
            continue
        }
        if message.media.contains(where: { $0 is TelegramMediaAction }) {
            remaining.append(id)
            continue
        }
        if message.ayuDeletedAttribute != nil {
            continue
        }
        transaction.updateMessage(id, update: { current in
            var attributes = current.attributes
            attributes.append(AyuDeletedMessageAttribute(date: timestamp))
            var storeForwardInfo: StoreMessageForwardInfo?
            if let forwardInfo = current.forwardInfo {
                storeForwardInfo = StoreMessageForwardInfo(forwardInfo)
            }
            return .update(StoreMessage(id: current.id, customStableId: nil, globallyUniqueId: current.globallyUniqueId, groupingKey: current.groupingKey, threadId: current.threadId, timestamp: current.timestamp, flags: StoreMessageFlags(current.flags), tags: current.tags, globalTags: current.globalTags, localTags: current.localTags, forwardInfo: storeForwardInfo, authorId: current.author?.id, text: current.text, attributes: attributes, media: current.media))
        })
    }
    return remaining
}

/// Read receipts are off but the user just wrote to the chat: mark its history read on the
/// server, as AyuGram's "read on interaction" does.
func ayuMarkReadAfterSend(account: Account, peerId: PeerId) {
    if AyuSettings.sendReadMessages || !AyuSettings.markReadAfterSend {
        return
    }
    let network = account.network
    let stateManager = account.stateManager
    let _ = (account.postbox.transaction { transaction -> (Api.InputPeer, Int32)? in
        guard let peer = transaction.getPeer(peerId), let inputPeer = apiInputPeer(peer) else {
            return nil
        }
        guard let maxId = transaction.getTopPeerMessageId(peerId: peerId, namespace: Namespaces.Message.Cloud)?.id else {
            return nil
        }
        return (inputPeer, maxId)
    }
    |> mapToSignal { value -> Signal<Never, NoError> in
        guard let (inputPeer, maxId) = value else {
            return .complete()
        }
        if case let .inputPeerChannel(channelData) = inputPeer {
            return network.request(Api.functions.channels.readHistory(channel: .inputChannel(.init(channelId: channelData.channelId, accessHash: channelData.accessHash)), maxId: maxId))
            |> `catch` { _ -> Signal<Api.Bool, NoError> in
                return .single(.boolFalse)
            }
            |> ignoreValues
        } else {
            return network.request(Api.functions.messages.readHistory(peer: inputPeer, maxId: maxId))
            |> map(Optional.init)
            |> `catch` { _ -> Signal<Api.messages.AffectedMessages?, NoError> in
                return .single(nil)
            }
            |> mapToSignal { result -> Signal<Never, NoError> in
                if let result = result, case let .affectedMessages(affectedMessagesData) = result {
                    stateManager?.addUpdateGroups([.updatePts(pts: affectedMessagesData.pts, ptsCount: affectedMessagesData.ptsCount)])
                }
                return .complete()
            }
        }
    }).start()
}

/// An edit from the server that turns a viewed self-destructing photo or video into expired
/// content: keep the previous media and drop the timers.
func ayuKeepSelfDestructingMedia(previous: Message, media: [Media], attributes: [MessageAttribute]) -> (media: [Media], attributes: [MessageAttribute]) {
    if !AyuSettings.saveSelfDestructingMedia {
        return (media, attributes)
    }
    if !media.contains(where: { $0 is TelegramMediaExpiredContent }) {
        return (media, attributes)
    }
    if !previous.media.contains(where: { $0 is TelegramMediaImage || $0 is TelegramMediaFile }) {
        return (media, attributes)
    }
    let updatedAttributes = attributes.filter { !($0 is AutoremoveTimeoutMessageAttribute) && !($0 is AutoclearTimeoutMessageAttribute) }
    return (previous.media, updatedAttributes)
}

/// Deletes messages the server no longer has (history validation), or only marks them as
/// deleted when deleted messages are kept.
func ayuDeleteOrMarkMessages(transaction: Transaction, mediaBox: MediaBox, ids: [MessageId]) {
    let idsToDelete = AyuSettings.saveDeletedMessages ? ayuMarkMessagesDeleted(transaction: transaction, ids: ids) : ids
    if !idsToDelete.isEmpty {
        _internal_deleteMessages(transaction: transaction, mediaBox: mediaBox, ids: idsToDelete)
    }
}

/// Attributes for an edited message: carries over the edit history of the previous
/// version and appends its text when the text changed.
func ayuEditHistoryAttributes(previous: Message, updatedText: String, updatedAttributes: [MessageAttribute]) -> [MessageAttribute] {
    var attributes = updatedAttributes.filter { !($0 is AyuEditHistoryMessageAttribute) && !($0 is AyuDeletedMessageAttribute) }
    var texts = previous.ayuEditHistoryAttribute?.texts ?? []
    var dates = previous.ayuEditHistoryAttribute?.dates ?? []
    if AyuSettings.saveEditHistory && previous.text != updatedText && !previous.text.isEmpty {
        texts.append(previous.text)
        var editDate: Int32 = ayuCurrentTimestamp()
        for attribute in updatedAttributes {
            if let attribute = attribute as? EditedMessageAttribute {
                editDate = attribute.date
            }
        }
        dates.append(editDate)
    }
    if !texts.isEmpty {
        attributes.append(AyuEditHistoryMessageAttribute(texts: texts, dates: dates))
    }
    if let deleted = previous.ayuDeletedAttribute {
        attributes.append(deleted)
    }
    return attributes
}
