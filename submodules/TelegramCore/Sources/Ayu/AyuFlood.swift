import Foundation
import Postbox
import SwiftSignalKit

/// Sends `count` exact copies of `message` into its own chat: the same text and entities, the same
/// photo, file or sticker, and the same reply (with its quote) when the message is a reply.
/// Copies go one by one, `intervalMs` apart, so the server does not reject a burst.
/// Media of a chat the server protects from copying is downloaded and uploaded again once.
public func ayuFloodMessage(account: Account, message: Message, count: Int, intervalMs: Int) -> Signal<Never, NoError> {
    let count = max(1, min(count, 100))
    var attributes: [MessageAttribute] = []
    if let entities = message.textEntitiesAttribute {
        attributes.append(entities)
    }
    var replySubject: EngineMessageReplySubject?
    for attribute in message.attributes {
        if let reply = attribute as? ReplyMessageAttribute {
            replySubject = resentReplySubject(reply)
        }
    }
    let threadId = message.threadId
    let text = message.text
    let peerId = message.id.peerId

    var sourceMedia: Media?
    for media in message.media {
        if media is TelegramMediaImage || media is TelegramMediaFile || media is TelegramMediaMap || media is TelegramMediaContact || media is TelegramMediaDice {
            sourceMedia = media
            break
        }
    }
    if text.isEmpty && sourceMedia == nil {
        return .complete()
    }

    let mediaReference: Signal<AnyMediaReference?, NoError>
    if let media = sourceMedia {
        if media is TelegramMediaImage || media is TelegramMediaFile {
            mediaReference = account.postbox.transaction { transaction -> Bool in
                return ayuIsServerCopyProtected(transaction: transaction, message: message)
            }
            |> mapToSignal { isProtected -> Signal<AnyMediaReference?, NoError> in
                if isProtected {
                    return ayuLocalMediaCopy(account: account, message: message, media: media)
                    |> map { copy -> AnyMediaReference? in
                        return copy.flatMap { AnyMediaReference.standalone(media: $0) }
                    }
                } else {
                    return .single(AnyMediaReference.message(message: MessageReference(message), media: media))
                }
            }
        } else {
            mediaReference = .single(AnyMediaReference.standalone(media: media))
        }
    } else {
        mediaReference = .single(nil)
    }

    return mediaReference
    |> mapToSignal { mediaReference -> Signal<Never, NoError> in
        if mediaReference == nil && text.isEmpty {
            return .complete()
        }
        var signal: Signal<Never, NoError> = .complete()
        for i in 0 ..< count {
            let send = enqueueMessages(account: account, peerId: peerId, messages: [.message(text: text, attributes: attributes, inlineStickers: [:], mediaReference: mediaReference, threadId: threadId, replyToMessageId: replySubject, replyToStoryId: nil, localGroupingKey: nil, correlationId: nil, bubbleUpEmojiOrStickersets: [])])
            |> ignoreValues
            if i == 0 || intervalMs <= 0 {
                signal = signal |> then(send)
            } else {
                // `delay` holds back events, not the subscription, so the pause is an empty signal first.
                let pause = Signal<Never, NoError>.complete() |> delay(Double(intervalMs) / 1000.0, queue: Queue.concurrentDefaultQueue())
                signal = signal |> then(pause) |> then(send)
            }
        }
        return signal
    }
}
