import Foundation
import UIKit
import UniformTypeIdentifiers
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import ItemListUI
import PresentationDataUtils
import AccountContext

private let ayuExampleScript = """
// Пример скрипта AyuGram.
// Команды в своих сообщениях:
//   .upper текст    — заглавными
//   .rev текст      — задом наперёд
//   .btc            — курс биткоина (fetch)
//   .last           — последние 5 сообщений чата в лог (getHistory)
//   .del5           — отправить и удалить через 5 секунд (setTimeout + deleteMessages)
ayu.onOutgoing(function (msg) {
    if (msg.text.startsWith(".upper ")) {
        return msg.text.slice(7).toUpperCase();
    }
    if (msg.text.startsWith(".rev ")) {
        return msg.text.slice(5).split("").reverse().join("");
    }
    if (msg.text === ".btc") {
        fetch("https://api.coinbase.com/v2/prices/BTC-USD/spot")
            .then(function (r) { return r.json(); })
            .then(function (j) { ayu.sendMessage(msg.peerId, "BTC: $" + j.data.amount); })
            .catch(function (e) { ayu.log("btc: " + e); });
        return "⏳";
    }
    if (msg.text === ".last") {
        ayu.getHistory(msg.peerId, 5).then(function (list) {
            list.forEach(function (m) { ayu.log((m.authorName || "?") + ": " + m.text); });
        });
    }
    if (msg.text.startsWith(".del5 ")) {
        var text = msg.text.slice(6);
        setTimeout(function () {
            ayu.getHistory(msg.peerId, 5).then(function (list) {
                var mine = list.filter(function (m) { return m.outgoing && m.text === text; });
                if (mine.length > 0) { ayu.deleteMessages(msg.peerId, [mine[0].id], true); }
            });
        }, 5000);
        return text;
    }
});

// Все входящие пишутся в лог скриптов.
ayu.onIncoming(function (msg) {
    console.log((msg.authorName || "?") + " в " + (msg.chatTitle || "?") + ": " + msg.text);
});
"""

private final class AyuScriptsControllerArguments {
    let toggle: (String, Bool) -> Void
    let openScript: (AyuScripts.Script) -> Void
    let addFromFile: () -> Void
    let addFromClipboard: () -> Void
    let addExample: () -> Void
    let showLog: () -> Void

    init(toggle: @escaping (String, Bool) -> Void, openScript: @escaping (AyuScripts.Script) -> Void, addFromFile: @escaping () -> Void, addFromClipboard: @escaping () -> Void, addExample: @escaping () -> Void, showLog: @escaping () -> Void) {
        self.toggle = toggle
        self.openScript = openScript
        self.addFromFile = addFromFile
        self.addFromClipboard = addFromClipboard
        self.addExample = addExample
        self.showLog = showLog
    }
}

private enum AyuScriptsSection: Int32 {
    case scripts
    case add
    case log
}

private enum AyuScriptsEntry: ItemListNodeEntry {
    case scriptsHeader
    case script(Int32, AyuScripts.Script)
    case scriptsFooter
    case addFromFile
    case addFromClipboard
    case addExample
    case addFooter
    case log

    var section: ItemListSectionId {
        switch self {
        case .scriptsHeader, .script, .scriptsFooter:
            return AyuScriptsSection.scripts.rawValue
        case .addFromFile, .addFromClipboard, .addExample, .addFooter:
            return AyuScriptsSection.add.rawValue
        case .log:
            return AyuScriptsSection.log.rawValue
        }
    }

    var stableId: Int32 {
        switch self {
        case .scriptsHeader:
            return 0
        case let .script(index, _):
            return 100 + index
        case .scriptsFooter:
            return 10000
        case .addFromFile:
            return 10001
        case .addFromClipboard:
            return 10002
        case .addExample:
            return 10003
        case .addFooter:
            return 10004
        case .log:
            return 10005
        }
    }

    static func <(lhs: AyuScriptsEntry, rhs: AyuScriptsEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! AyuScriptsControllerArguments
        switch self {
        case .scriptsHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: "СКРИПТЫ", sectionId: self.section)
        case let .script(_, script):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: script.name, value: script.enabled, sectionId: self.section, style: .blocks, updated: { value in
                arguments.toggle(script.id, value)
            }, action: {
                arguments.openScript(script)
            })
        case .scriptsFooter:
            return ItemListTextItem(presentationData: presentationData, text: .plain("Нажми на скрипт, чтобы удалить его. Скрипты работают с твоим аккаунтом: могут читать входящие и отправлять сообщения. Не загружай скрипты, которым не доверяешь."), sectionId: self.section)
        case .addFromFile:
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: "Добавить из файла (.js)", kind: .generic, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                arguments.addFromFile()
            })
        case .addFromClipboard:
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: "Вставить из буфера обмена", kind: .generic, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                arguments.addFromClipboard()
            })
        case .addExample:
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: "Добавить пример", kind: .generic, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                arguments.addExample()
            })
        case .addFooter:
            return ItemListTextItem(presentationData: presentationData, text: .plain("Хуки: ayu.onOutgoing(fn) — вернуть строку, чтобы заменить текст своего сообщения; ayu.onIncoming(fn) — каждое новое входящее. Сообщения: ayu.sendMessage(peerId, text, replyToId), ayu.editMessage(peerId, id, text), ayu.deleteMessages(peerId, [ids], forEveryone), ayu.react(peerId, id, \"👍\"), ayu.forwardMessages(from, [ids], to), ayu.getHistory(peerId, limit) → Promise. Медиа (src: ссылка http(s), data: или base64): ayu.sendPhoto(peerId, src, caption), ayu.sendFile(peerId, src, fileName, caption), ayu.sendSticker(peerId, src) — webp. Ещё: fetch, setTimeout/setInterval, console.log, ayu.storage.get/set. У msg: text, peerId, id, date, authorId, authorName, chatTitle, outgoing, mediaType."), sectionId: self.section)
        case .log:
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: "Лог скриптов", kind: .generic, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                arguments.showLog()
            })
        }
    }
}

private func ayuScriptsEntries(scripts: [AyuScripts.Script]) -> [AyuScriptsEntry] {
    var entries: [AyuScriptsEntry] = []
    entries.append(.scriptsHeader)
    for i in 0 ..< scripts.count {
        entries.append(.script(Int32(i), scripts[i]))
    }
    entries.append(.scriptsFooter)
    entries.append(.addFromFile)
    entries.append(.addFromClipboard)
    entries.append(.addExample)
    entries.append(.addFooter)
    entries.append(.log)
    return entries
}

private final class AyuScriptPickerDelegateHolder {
    var delegate: AyuScriptPickerDelegate?
}

private final class AyuScriptPickerDelegate: NSObject, UIDocumentPickerDelegate {
    private let completion: ([URL]) -> Void

    init(completion: @escaping ([URL]) -> Void) {
        self.completion = completion
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        self.completion(urls)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        self.completion([])
    }
}

public func ayuScriptsController(context: AccountContext) -> ViewController {
    let revision = ValuePromise<Int>(0, ignoreRepeated: false)
    var currentRevision = 0
    let refresh: () -> Void = {
        currentRevision += 1
        revision.set(currentRevision)
    }

    var presentImpl: ((ViewController) -> Void)?
    var presentPickerImpl: (() -> Void)?

    let arguments = AyuScriptsControllerArguments(toggle: { id, value in
        AyuScripts.shared.setEnabled(id: id, enabled: value)
        refresh()
    }, openScript: { script in
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        presentImpl?(textAlertController(context: context, title: script.name, text: "Удалить этот скрипт?", actions: [
            TextAlertAction(type: .destructiveAction, title: "Удалить", action: {
                AyuScripts.shared.deleteScript(id: script.id)
                refresh()
            }),
            TextAlertAction(type: .genericAction, title: presentationData.strings.Common_Cancel, action: {})
        ], actionLayout: .vertical))
    }, addFromFile: {
        presentPickerImpl?()
    }, addFromClipboard: {
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        if let code = UIPasteboard.general.string, !code.isEmpty {
            AyuScripts.shared.addScript(name: "Скрипт \(AyuScripts.shared.scripts().count + 1)", code: code)
            refresh()
        } else {
            presentImpl?(textAlertController(context: context, title: nil, text: "В буфере обмена нет текста.", actions: [TextAlertAction(type: .defaultAction, title: presentationData.strings.Common_OK, action: {})]))
        }
    }, addExample: {
        AyuScripts.shared.addScript(name: "Пример", code: ayuExampleScript)
        refresh()
    }, showLog: {
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        var text = AyuScripts.shared.logText()
        if text.isEmpty {
            text = "Лог пуст."
        } else if text.count > 3000 {
            text = "…" + String(text.suffix(3000))
        }
        presentImpl?(textAlertController(context: context, title: "Лог скриптов", text: text, actions: [
            TextAlertAction(type: .genericAction, title: "Очистить", action: {
                AyuScripts.shared.clearLog()
            }),
            TextAlertAction(type: .defaultAction, title: presentationData.strings.Common_OK, action: {})
        ]))
    })

    let signal = combineLatest(queue: .mainQueue(),
        context.sharedContext.presentationData,
        revision.get()
    )
    |> map { presentationData, _ -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text("Скрипты"), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: ayuScriptsEntries(scripts: AyuScripts.shared.scripts()), style: .blocks, animateChanges: true)
        return (controllerState, (listState, arguments))
    }

    let controller = ItemListController(context: context, state: signal)

    presentImpl = { [weak controller] c in
        controller?.present(c, in: .window(.root))
    }

    let pickerDelegateHolder = AyuScriptPickerDelegateHolder()
    presentPickerImpl = { [weak controller] in
        guard let controller = controller else {
            return
        }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.javaScript, UTType.plainText, UTType.text, UTType.data], asCopy: true)
        let delegate = AyuScriptPickerDelegate(completion: { urls in
            for url in urls {
                if let data = try? Data(contentsOf: url), let code = String(data: data, encoding: .utf8) {
                    AyuScripts.shared.addScript(name: url.lastPathComponent, code: code)
                }
            }
            if !urls.isEmpty {
                refresh()
            }
            pickerDelegateHolder.delegate = nil
        })
        pickerDelegateHolder.delegate = delegate
        picker.delegate = delegate
        controller.present(picker, animated: true, completion: nil)
    }

    return controller
}
