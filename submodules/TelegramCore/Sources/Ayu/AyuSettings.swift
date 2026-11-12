import Foundation
import Postbox

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
