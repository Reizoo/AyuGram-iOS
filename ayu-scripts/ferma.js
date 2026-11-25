// Ферма: пишет «ферма» в выбранный чат каждые 4 часа.
//
// Сообщения ставятся как ОТЛОЖЕННЫЕ на сервер Telegram, поэтому уходят вовремя,
// даже если AyuGram закрыт или телефон выключен. Скрипт держит запас примерно на 15 дней
// и пополняет его каждый раз, когда приложение запущено.
//
// Включить: открой нужный чат и отправь туда  .ферма вкл
//           (команда сама превратится в первую «ферма»).
// Выключить: в том же чате отправь  .ферма выкл
//           (скрипт перестанет планировать и удалит все отложенные «ферма» в этом чате).
//           Нужна сборка AyuGram с ayu.clearScheduled.

var TEXT = "ферма";
var INTERVAL = 4 * 60 * 60;   // 4 часа, в секундах
var AHEAD = 90;               // сколько держать запланированными (лимит Telegram — 100 на чат)

function now() {
    return Math.floor(Date.now() / 1000);
}

function topUp() {
    var peerId = ayu.storage.get("ferma.peerId");
    if (!peerId) {
        return;
    }
    var t = now();
    var last = parseInt(ayu.storage.get("ferma.last") || "0", 10);
    if (!last) {
        last = t;
    }
    var next = last + INTERVAL;
    // Если приложение долго не запускалось и запас кончился — пропущенные разы не догоняем.
    while (next <= t + 60) {
        next += INTERVAL;
    }
    var horizon = t + AHEAD * INTERVAL;
    var count = 0;
    while (next <= horizon && count < AHEAD) {
        ayu.scheduleMessage(peerId, TEXT, next);
        last = next;
        next += INTERVAL;
        count++;
    }
    ayu.storage.set("ferma.last", String(last));
    if (count > 0) {
        ayu.log("ферма: запланировано " + count + ", последняя " + new Date(last * 1000).toLocaleString());
    }
}

function turnOff(peerId) {
    ayu.storage.set("ferma.peerId", "");
    ayu.storage.set("ferma.last", "");
    ayu.clearScheduled(peerId, TEXT).then(function (count) {
        ayu.log("ферма: выключена, удалено отложенных: " + count);
    }, function (err) {
        ayu.log("ферма: выключена, но удалить отложенные не вышло: " + err.message);
    });
}

ayu.onOutgoing(function (msg) {
    var command = msg.text.trim().toLowerCase();
    if (command === ".ферма вкл") {
        ayu.storage.set("ferma.peerId", msg.peerId);
        ayu.storage.set("ferma.last", String(now()));
        setTimeout(topUp, 2000);
        return TEXT;
    }
    if (command === ".ферма выкл") {
        var peerId = ayu.storage.get("ferma.peerId") || msg.peerId;
        // Хук вызывается во время отправки, поэтому остальное делаем вне его.
        setTimeout(function () { turnOff(peerId); }, 0);
        // Сама команда уходит обычным сообщением: через 10 секунд находим её и удаляем у всех.
        setTimeout(function () {
            ayu.getHistory(msg.peerId, 10).then(function (messages) {
                var ids = messages.filter(function (m) {
                    return m.outgoing && m.text.trim().toLowerCase() === ".ферма выкл";
                }).map(function (m) { return m.id; });
                if (ids.length > 0) {
                    ayu.deleteMessages(msg.peerId, ids, true);
                }
            });
        }, 10000);
    }
});

topUp();
setInterval(topUp, 30 * 60 * 1000);
