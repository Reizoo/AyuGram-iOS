import Foundation
import Postbox
import SwiftSignalKit

/// The server refuses to forward messages from chats with "restrict saving content"
/// (CHAT_FORWARDS_RESTRICTED) and also refuses their photos and files as input media.
/// With `AyuSettings.saveRestrictedContent` such a forward is sent as a new message instead:
/// the text and entities are kept, and a photo or file is downloaded and uploaded again.
func ayuIsServerCopyProtected(transaction: Transaction, message: Message) -> Bool {
    if message.ayuIsCopyProtectedOnServer() {
        return true
    }
    if message.id.peerId.namespace == Namespaces.Peer.CloudUser, let cachedUserData = transaction.getPeerCachedData(peerId: message.id.peerId) as? CachedUserData {
        return cachedUserData.flags.contains(.copyProtectionEnabled) || cachedUserData.flags.contains(.myCopyProtectionEnabled)
    }
    return false
}

func ayuConvertProtectedForwards(account: Account, messages: [EnqueueMessage]) -> Signal<[EnqueueMessage], NoError> {
    if !AyuSettings.saveRestrictedContent {
        return .single(messages)
    }
    let hasForwards = messages.contains(where: { message in
        if case .forward = message {
            return true
        } else {
            return false
        }
    })
    if !hasForwards {
        return .single(messages)
    }
    return account.postbox.transaction { transaction -> [Int: Message] in
        var result: [Int: Message] = [:]
        for i in 0 ..< messages.count {
            if case let .forward(source, _, _, _, _) = messages[i], let message = transaction.getMessage(source), ayuIsServerCopyProtected(transaction: transaction, message: message) {
                result[i] = message
            }
        }
        return result
    }
    |> mapToSignal { protectedMessages -> Signal<[EnqueueMessage], NoError> in
        if protectedMessages.isEmpty {
            return .single(messages)
        }
        var groupingKeys: [Int64: Int64] = [:]
        var signals: [Signal<EnqueueMessage, NoError>] = []
        for i in 0 ..< messages.count {
            let original = messages[i]
            guard let source = protectedMessages[i], case let .forward(_, threadId, _, forwardAttributes, correlationId) = original else {
                signals.append(.single(original))
                continue
            }
            var localGroupingKey: Int64?
            if let groupingKey = source.groupingKey {
                if let existing = groupingKeys[groupingKey] {
                    localGroupingKey = existing
                } else {
                    let value = Int64.random(in: Int64.min ... Int64.max)
                    groupingKeys[groupingKey] = value
                    localGroupingKey = value
                }
            }
            var attributes: [MessageAttribute] = forwardAttributes.filter { !($0 is ForwardOptionsMessageAttribute) }
            if let entities = source.textEntitiesAttribute {
                attributes.append(entities)
            }
            let text = source.text
            let makeMessage: (AnyMediaReference?) -> EnqueueMessage = { mediaReference in
                return .message(text: text, attributes: attributes, inlineStickers: [:], mediaReference: mediaReference, threadId: threadId, replyToMessageId: nil, replyToStoryId: nil, localGroupingKey: localGroupingKey, correlationId: correlationId, bubbleUpEmojiOrStickersets: [])
            }

            var uploadMedia: Media?
            var directMedia: Media?
            for media in source.media {
                if media is TelegramMediaImage || media is TelegramMediaFile {
                    uploadMedia = media
                    break
                } else if media is TelegramMediaMap || media is TelegramMediaContact || media is TelegramMediaDice {
                    directMedia = media
                    break
                }
            }

            if let uploadMedia = uploadMedia {
                signals.append(ayuLocalMediaCopy(account: account, message: source, media: uploadMedia)
                |> map { copy -> EnqueueMessage in
                    if let copy = copy {
                        return makeMessage(.standalone(media: copy))
                    } else if !text.isEmpty {
                        return makeMessage(nil)
                    } else {
                        return original
                    }
                })
            } else if let directMedia = directMedia {
                signals.append(.single(makeMessage(.standalone(media: directMedia))))
            } else if !text.isEmpty {
                signals.append(.single(makeMessage(nil)))
            } else {
                signals.append(.single(original))
            }
        }
        return combineLatest(signals)
    }
}

/// Downloads the photo or file of `message` and returns a copy that points at a local resource,
/// so that sending it uploads the bytes again. Nil when it cannot be downloaded in time.
func ayuLocalMediaCopy(account: Account, message: Message, media: Media) -> Signal<Media?, NoError> {
    let resource: MediaResource
    let userContentType: MediaResourceUserContentType
    if let image = media as? TelegramMediaImage, let representation = largestImageRepresentation(image.representations) {
        resource = representation.resource
        userContentType = .image
    } else if let file = media as? TelegramMediaFile {
        resource = file.resource
        userContentType = .file
    } else {
        return .single(nil)
    }
    let mediaBox = account.postbox.mediaBox
    let reference = MediaResourceReference.media(media: .message(message: MessageReference(message), media: media), resource: resource)

    let copy = Signal<Media?, NoError> { subscriber in
        let fetchDisposable = fetchedMediaResource(mediaBox: mediaBox, userLocation: .peer(message.id.peerId), userContentType: userContentType, reference: reference).start()
        let dataDisposable = (mediaBox.resourceData(resource)
        |> filter { $0.complete }
        |> take(1)).start(next: { data in
            let localResource = LocalFileMediaResource(fileId: Int64.random(in: Int64.min ... Int64.max))
            mediaBox.copyResourceData(from: resource.id, to: localResource.id, synchronous: true)
            var result: Media?
            if let image = media as? TelegramMediaImage, let representation = largestImageRepresentation(image.representations) {
                result = TelegramMediaImage(imageId: MediaId(namespace: Namespaces.Media.LocalImage, id: Int64.random(in: Int64.min ... Int64.max)), representations: [TelegramMediaImageRepresentation(dimensions: representation.dimensions, resource: localResource, progressiveSizes: [], immediateThumbnailData: nil, hasVideo: false, isPersonal: false)], immediateThumbnailData: image.immediateThumbnailData, reference: nil, partialReference: nil, flags: [])
            } else if let file = media as? TelegramMediaFile {
                result = TelegramMediaFile(fileId: MediaId(namespace: Namespaces.Media.LocalFile, id: Int64.random(in: Int64.min ... Int64.max)), partialReference: nil, resource: localResource, previewRepresentations: [], videoThumbnails: [], immediateThumbnailData: file.immediateThumbnailData, mimeType: file.mimeType, size: data.size, attributes: file.attributes, alternativeRepresentations: [])
            }
            subscriber.putNext(result)
            subscriber.putCompletion()
        })
        return ActionDisposable {
            fetchDisposable.dispose()
            dataDisposable.dispose()
        }
    }
    return copy
    |> timeout(600.0, queue: Queue.concurrentDefaultQueue(), alternate: .single(nil))
}
