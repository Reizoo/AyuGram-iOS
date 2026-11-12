import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import ItemListUI
import PresentationDataUtils
import AccountContext

private final class AyuSettingsControllerArguments {
    let update: (AyuSettingsToggle, Bool) -> Void

    init(update: @escaping (AyuSettingsToggle, Bool) -> Void) {
        self.update = update
    }
}

private enum AyuSettingsToggle: Int32 {
    case sendOnline
    case sendTyping
    case sendReadMessages
    case sendReadStories
    case readAfterSend
    case saveDeleted
    case saveEdits
    case saveSelfDestructing
    case hideAds

    var title: String {
        switch self {
        case .sendOnline:
            return "Отправлять «в сети»"
        case .sendTyping:
            return "Отправлять «печатает»"
        case .sendReadMessages:
            return "Отмечать сообщения прочитанными"
        case .sendReadStories:
            return "Отмечать истории просмотренными"
        case .readAfterSend:
            return "Читать при ответе"
        case .saveSelfDestructing:
            return "Сохранять одноразовые фото и видео"
        case .hideAds:
            return "Скрывать рекламу в каналах"
        case .saveDeleted:
            return "Сохранять удалённые сообщения"
        case .saveEdits:
            return "Сохранять историю правок"
        }
    }

    var value: Bool {
        switch self {
        case .sendOnline:
            return AyuSettings.sendOnlinePackets
        case .sendTyping:
            return AyuSettings.sendTyping
        case .sendReadMessages:
            return AyuSettings.sendReadMessages
        case .sendReadStories:
            return AyuSettings.sendReadStories
        case .readAfterSend:
            return AyuSettings.markReadAfterSend
        case .saveSelfDestructing:
            return AyuSettings.saveSelfDestructingMedia
        case .hideAds:
            return AyuSettings.hideSponsoredMessages
        case .saveDeleted:
            return AyuSettings.saveDeletedMessages
        case .saveEdits:
            return AyuSettings.saveEditHistory
        }
    }

    func set(_ value: Bool) {
        switch self {
        case .sendOnline:
            AyuSettings.sendOnlinePackets = value
        case .sendTyping:
            AyuSettings.sendTyping = value
        case .sendReadMessages:
            AyuSettings.sendReadMessages = value
        case .sendReadStories:
            AyuSettings.sendReadStories = value
        case .readAfterSend:
            AyuSettings.markReadAfterSend = value
        case .saveSelfDestructing:
            AyuSettings.saveSelfDestructingMedia = value
        case .hideAds:
            AyuSettings.hideSponsoredMessages = value
        case .saveDeleted:
            AyuSettings.saveDeletedMessages = value
        case .saveEdits:
            AyuSettings.saveEditHistory = value
        }
    }
}

private enum AyuSettingsSection: Int32 {
    case ghost
    case history
    case other
}

private enum AyuSettingsEntry: ItemListNodeEntry {
    case ghostHeader
    case toggle(AyuSettingsToggle, Bool)
    case ghostFooter
    case historyHeader
    case historyFooter
    case otherHeader

    var section: ItemListSectionId {
        switch self {
        case .ghostHeader, .ghostFooter:
            return AyuSettingsSection.ghost.rawValue
        case .historyHeader, .historyFooter:
            return AyuSettingsSection.history.rawValue
        case .otherHeader:
            return AyuSettingsSection.other.rawValue
        case let .toggle(toggle, _):
            switch toggle {
            case .sendOnline, .sendTyping, .sendReadMessages, .sendReadStories, .readAfterSend:
                return AyuSettingsSection.ghost.rawValue
            case .saveDeleted, .saveEdits, .saveSelfDestructing:
                return AyuSettingsSection.history.rawValue
            case .hideAds:
                return AyuSettingsSection.other.rawValue
            }
        }
    }

    var stableId: Int32 {
        switch self {
        case .ghostHeader:
            return 0
        case let .toggle(toggle, _):
            switch toggle {
            case .sendOnline:
                return 1
            case .sendTyping:
                return 2
            case .sendReadMessages:
                return 3
            case .sendReadStories:
                return 4
            case .readAfterSend:
                return 5
            case .saveSelfDestructing:
                return 13
            case .hideAds:
                return 21
            case .saveDeleted:
                return 11
            case .saveEdits:
                return 12
            }
        case .ghostFooter:
            return 6
        case .historyHeader:
            return 10
        case .historyFooter:
            return 14
        case .otherHeader:
            return 20
        }
    }

    static func <(lhs: AyuSettingsEntry, rhs: AyuSettingsEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! AyuSettingsControllerArguments
        switch self {
        case .ghostHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: "РЕЖИМ ПРИЗРАКА", sectionId: self.section)
        case .ghostFooter:
            return ItemListTextItem(presentationData: presentationData, text: .plain("Выключенные пункты не отправляются на сервер. Прочитанное отмечается только у тебя. «Читать при ответе» отмечает чат прочитанным, когда ты сам туда пишешь. Кнопка 👻 в списке чатов включает и выключает режим призрака целиком."), sectionId: self.section)
        case .historyHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: "ИСТОРИЯ СООБЩЕНИЙ", sectionId: self.section)
        case .otherHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: "ПРОЧЕЕ", sectionId: self.section)
        case .historyFooter:
            return ItemListTextItem(presentationData: presentationData, text: .plain("Удалённые сообщения остаются в чате с пометкой 🗑. Старые версии правок — в меню сообщения → «История правок»."), sectionId: self.section)
        case let .toggle(toggle, value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: toggle.title, value: value, sectionId: self.section, style: .blocks, updated: { value in
                arguments.update(toggle, value)
            })
        }
    }
}

private func ayuSettingsEntries() -> [AyuSettingsEntry] {
    var entries: [AyuSettingsEntry] = []
    entries.append(.ghostHeader)
    for toggle in [AyuSettingsToggle.sendOnline, .sendTyping, .sendReadMessages, .sendReadStories, .readAfterSend] {
        entries.append(.toggle(toggle, toggle.value))
    }
    entries.append(.ghostFooter)
    entries.append(.historyHeader)
    for toggle in [AyuSettingsToggle.saveDeleted, .saveEdits, .saveSelfDestructing] {
        entries.append(.toggle(toggle, toggle.value))
    }
    entries.append(.historyFooter)
    entries.append(.otherHeader)
    entries.append(.toggle(.hideAds, AyuSettingsToggle.hideAds.value))
    return entries
}

public func ayuSettingsController(context: AccountContext) -> ViewController {
    let revision = ValuePromise<Int>(0, ignoreRepeated: false)
    var currentRevision = 0

    let arguments = AyuSettingsControllerArguments(update: { toggle, value in
        toggle.set(value)
        currentRevision += 1
        revision.set(currentRevision)
    })

    let signal = combineLatest(queue: .mainQueue(),
        context.sharedContext.presentationData,
        revision.get()
    )
    |> map { presentationData, _ -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text("AyuGram"), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: ayuSettingsEntries(), style: .blocks, animateChanges: false)
        return (controllerState, (listState, arguments))
    }

    let controller = ItemListController(context: context, state: signal)
    return controller
}
