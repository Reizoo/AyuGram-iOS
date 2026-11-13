// Ферма: пишет «ферма» в выбранный чат каждые 4 часа.
//
// Сообщения ставятся как ОТЛОЖЕННЫЕ на сервер Telegram, поэтому уходят вовремя,
// даже если AyuGram закрыт или телефон выключен. Скрипт держит запас примерно на 15 дней
// и пополняет его каждый раз, когда приложение запущено.
//
// Включить: открой нужный чат и отправь туда  .ферма вкл
//           (команда сама превратится в первую «ферма»).
// Выключить: выключи этот скрипт в Настройки → AyuGram → Скрипты,
//           потом в чате открой «Отложенные сообщения» и удали оставшиеся.

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

ayu.onOutgoing(function (msg) {
    if (msg.text.trim().toLowerCase() === ".ферма вкл") {
        ayu.storage.set("ferma.peerId", msg.peerId);
        ayu.storage.set("ferma.last", String(now()));
        setTimeout(topUp, 2000);
        return TEXT;
    }
});

topUp();
setInterval(topUp, 30 * 60 * 1000);
