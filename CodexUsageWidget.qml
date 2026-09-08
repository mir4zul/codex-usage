import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins
import "translations.js" as Tr

PluginComponent {
    id: root

    // i18n
    property string lang: Qt.locale().name.split(/[_-]/)[0]
    function tr(key) {
        return Tr.tr(key, lang);
    }

    // Settings
    property int refreshInterval: 30000
    property bool showIcon: pluginData.showIcon !== false       // default on

    // Account/session state
    property bool loggedIn: false
    property bool isLoading: true
    property string account: ""
    property string plan: ""
    property string cliVersion: ""
    property string updatedAt: ""
    property var stats: ({})
    property real maxDaily: Math.max.apply(null, [1].concat((stats.daily || []).map(function(d) { return d.tokens; })))
    function compact(value) {
        if (value >= 1000000000) return (value / 1000000000).toFixed(1) + "B";
        if (value >= 1000000) return (value / 1000000).toFixed(1) + "M";
        if (value >= 1000) return (value / 1000).toFixed(1) + "K";
        return String(Math.round(value));
    }

    // Quota buckets: id -> { GROUP, GROUP_DESC, LABEL, WINDOW, REMAINING, RESET, DESC }
    property var buckets: ({})
    property var bucketOrder: []

    // Live countdown clock
    property real countdownNow: Date.now()

    // --- Derived ---

    // Grouped view: [{ name, desc, buckets:[{id,label,window,remaining,reset,desc}] }]
    property var groups: {
        void (buckets);
        void (bucketOrder);
        var seen = {};
        var out = [];
        for (var i = 0; i < bucketOrder.length; i++) {
            var id = bucketOrder[i];
            var b = buckets[id];
            if (!b)
                continue;
            var gname = b.GROUP || "";
            if (!(gname in seen)) {
                seen[gname] = {
                    "name": gname,
                    "desc": b.GROUP_DESC || "",
                    "buckets": []
                };
                out.push(seen[gname]);
            }
            seen[gname].buckets.push({
                "id": id,
                "label": b.LABEL || "",
                "window": b.WINDOW || "",
                "remaining": (b.REMAINING !== undefined ? parseFloat(b.REMAINING) : 1),
                "reset": b.RESET || "",
                "desc": b.DESC || ""
            });
        }
        return out;
    }

    // Tightest (most-consumed) limit across all buckets, as a 0..100 "used" percentage.
    property real tightestUsed: {
        void (buckets);
        void (bucketOrder);
        var maxUsed = 0;
        for (var i = 0; i < bucketOrder.length; i++) {
            var b = buckets[bucketOrder[i]];
            if (!b || b.REMAINING === undefined)
                continue;
            var u = (1 - parseFloat(b.REMAINING)) * 100;
            if (u > maxUsed)
                maxUsed = u;
        }
        return maxUsed;
    }

    popoutWidth: 380
    popoutHeight: 760

    // --- Helpers ---

    function progressColor(usedPct) {
        if (usedPct > 80)
            return Theme.error;
        if (usedPct > 50)
            return Theme.warning;
        return Theme.primary;
    }

    // ISO timestamp -> "2d 3h 04m" / "3h 04m" countdown relative to countdownNow.
    function countdown(resetIso) {
        if (!resetIso)
            return "";
        var resetMs = new Date(resetIso).getTime();
        if (isNaN(resetMs))
            return "";
        var remaining = Math.max(0, resetMs - countdownNow);
        if (remaining <= 0)
            return tr("Resetting...");
        var days = Math.floor(remaining / 86400000);
        var hours = Math.floor((remaining % 86400000) / 3600000);
        var mins = Math.floor((remaining % 3600000) / 60000);
        if (days > 0)
            return days + "d " + hours + "h " + (mins < 10 ? "0" : "") + mins + "m";
        return hours + "h " + (mins < 10 ? "0" : "") + mins + "m";
    }

    function setBucketField(id, field, val) {
        var b = Object.assign({}, buckets);
        var cur = b[id] ? Object.assign({}, b[id]) : {};
        cur[field] = val;
        b[id] = cur;
        buckets = b;
    }

    // Field suffixes in priority order (longest/ambiguous first).
    property var _bucketFields: ["GROUP_DESC", "GROUP", "LABEL", "WINDOW", "REMAINING", "RESET", "DESC"]

    function parseLine(line) {
        var idx = line.indexOf("=");
        if (idx < 0)
            return;
        var key = line.substring(0, idx);
        var val = line.substring(idx + 1);

        if (key.indexOf("BUCKET_") === 0) {
            var rest = key.substring(7);
            for (var i = 0; i < _bucketFields.length; i++) {
                var suf = "_" + _bucketFields[i];
                if (rest.length > suf.length && rest.substring(rest.length - suf.length) === suf) {
                    var id = rest.substring(0, rest.length - suf.length);
                    setBucketField(id, _bucketFields[i], val);
                    return;
                }
            }
            return;
        }

        switch (key) {
        case "STATS":
            try { stats = JSON.parse(val); } catch (e) { stats = ({}); }
            break;
        case "LOGGED_IN":
            loggedIn = (val === "true");
            break;
        case "ACCOUNT":
            account = val;
            break;
        case "PLAN":
            plan = val;
            break;
        case "UPDATED_AT":
            updatedAt = val;
            break;
        case "CLI_VERSION":
            cliVersion = val;
            break;
        case "GROUPS":
            // New refresh: reset the bucket store, set the canonical order.
            buckets = ({});
            bucketOrder = val.length > 0 ? val.split(",") : [];
            break;
        }
    }

    // --- Data fetching ---

    property string scriptPath: PluginService.pluginDirectory + "/codexUsage/get-codex-usage.py"
    property string logoSource: "file://" + PluginService.pluginDirectory + "/codexUsage/icon.svg"

    Process {
        id: usageProcess
        command: ["python3", root.scriptPath]
        running: false

        stdout: SplitParser {
            onRead: data => root.parseLine(data.trim())
        }

        onExited: (exitCode, exitStatus) => {
            root.isLoading = false;
        }
    }

    Timer {
        interval: root.refreshInterval
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: {
            if (!usageProcess.running)
                usageProcess.running = true;
        }
    }

    // Live countdown + wake-from-sleep detection
    Timer {
        interval: 60000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: {
            var now = Date.now();
            var elapsed = now - root.countdownNow;
            root.countdownNow = now;
            if (elapsed > 120000 && !usageProcess.running)
                usageProcess.running = true;
        }
    }

    // --- Taskbar pills (ring shows tightest used limit) ---

    function limitText(id) {
        var b = buckets[id];
        return b && b.REMAINING !== undefined
            ? Math.round((1 - parseFloat(b.REMAINING)) * 100) + "%" : "—";
    }

    horizontalBarPill: Component {
        Row {
            spacing: Theme.spacingS
            StyledText {
                text: "5h " + root.limitText("primary")
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceText
            }
            StyledText {
                text: "Week " + root.limitText("secondary")
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceText
            }
        }
    }

    verticalBarPill: Component {
        Column {
            spacing: Theme.spacingXS || 4

            Image {
                source: root.logoSource
                sourceSize.width: 16
                sourceSize.height: 16
                width: 16
                height: 16
                anchors.horizontalCenter: parent.horizontalCenter
                visible: root.showIcon
                layer.enabled: true
                layer.effect: MultiEffect {
                    colorization: 1.0
                    colorizationColor: Theme.primary
                }
            }

            Repeater {
                model: ["primary", "secondary"]
                delegate: Column {
                    required property string modelData
                    anchors.horizontalCenter: parent.horizontalCenter
                    spacing: 2

                    Canvas {
                        width: 20
                        height: 20
                        anchors.horizontalCenter: parent.horizontalCenter
                        renderStrategy: Canvas.Cooperative
                        property real percent: {
                            var b = root.buckets[modelData];
                            return b && b.REMAINING !== undefined
                                ? Math.max(0, Math.min(100, (1 - parseFloat(b.REMAINING)) * 100)) : 0;
                        }
                        property color ringColor: root.progressColor(percent)
                        property color trackColor: Theme.surfaceVariant
                        onPercentChanged: requestPaint()
                        onRingColorChanged: requestPaint()
                        onTrackColorChanged: requestPaint()
                        onPaint: {
                            var ctx = getContext("2d");
                            ctx.reset();
                            var cx = width / 2, cy = height / 2, r = 7.5;
                            ctx.beginPath();
                            ctx.arc(cx, cy, r, 0, 2 * Math.PI);
                            ctx.lineWidth = 2.5;
                            ctx.strokeStyle = trackColor;
                            ctx.stroke();
                            if (percent > 0) {
                                ctx.beginPath();
                                ctx.arc(cx, cy, r, -Math.PI / 2, -Math.PI / 2 + 2 * Math.PI * percent / 100);
                                ctx.strokeStyle = ringColor;
                                ctx.lineCap = "round";
                                ctx.stroke();
                            }
                        }
                    }

                    StyledText {
                        text: root.limitText(modelData)
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceText
                        anchors.horizontalCenter: parent.horizontalCenter
                    }
                }
            }
        }
    }

    component UsageRing: Item {
        property real percent: 0
        property color accent: Theme.primary
        width: 76
        height: 76
        Canvas {
            anchors.fill: parent
            property real value: parent.percent
            property color ink: parent.accent
            property color track: Theme.surfaceVariant
            onValueChanged: requestPaint()
            onInkChanged: requestPaint()
            onTrackChanged: requestPaint()
            onPaint: {
                var ctx = getContext("2d");
                ctx.reset();
                ctx.lineWidth = 5;
                ctx.lineCap = "round";
                ctx.beginPath(); ctx.arc(width/2, height/2, width/2-5, 0, Math.PI*2);
                ctx.strokeStyle = track; ctx.stroke();
                if (value > 0) {
                    ctx.beginPath();
                    ctx.arc(width/2, height/2, width/2-5, -Math.PI/2, -Math.PI/2+Math.PI*2*Math.min(100,value)/100);
                    ctx.strokeStyle = ink; ctx.stroke();
                }
            }
        }
        StyledText {
            anchors.centerIn: parent
            text: Math.round(parent.percent) + "%"
            color: Theme.surfaceText
            font.pixelSize: 20
            font.weight: Font.DemiBold
        }
    }

    popoutContent: Component {
        PopoutComponent {
            headerText: "Codex Usage"
            detailsText: (root.plan ? root.plan + " subscription" : "Local session insights") + "  ·  Last recorded limits"
            showCloseButton: true
            Column {
                width: parent.width - 16
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: 10

                Rectangle {
                    visible: !root.loggedIn
                    width: parent.width
                    height: 76
                    radius: 14
                    color: Theme.surfaceContainerHigh
                    StyledText {
                        anchors.fill: parent
                        anchors.margins: 16
                        text: root.isLoading ? "Reading local usage…" : "No quota recorded yet. Run codex login, then use Codex."
                        color: Theme.surfaceText
                        font.pixelSize: 13
                        wrapMode: Text.WordWrap
                    }
                }

                Repeater {
                    model: root.loggedIn ? ["primary", "secondary"] : []
                    delegate: Rectangle {
                        required property string modelData
                        property var bucket: root.buckets[modelData] || ({})
                        property real used: bucket.REMAINING !== undefined ? Math.max(0, Math.min(100, (1-bucket.REMAINING)*100)) : 0
                        property color accent: modelData === "primary" ? Theme.primary : Theme.secondary
                        width: parent.width
                        height: 108
                        radius: 16
                        color: Theme.surfaceContainerHigh
                        border.color: Theme.outline
                        Row {
                            anchors.fill: parent
                            anchors.margins: 16
                            spacing: 18
                            UsageRing { percent: used; accent: parent.parent.accent }
                            Column {
                                width: parent.width - 94
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: 5
                                StyledText {
                                    text: modelData === "primary" ? "5-HOUR WINDOW" : "WEEKLY WINDOW"
                                    font.pixelSize: 11
                                    font.letterSpacing: 1.1
                                    color: Theme.surfaceVariantText
                                }
                                StyledText {
                                    text: bucket.REMAINING !== undefined ? (100-Math.round(used)) + "% available" : "Not recorded"
                                    font.pixelSize: 18
                                    font.weight: Font.DemiBold
                                    color: accent
                                }
                                StyledText {
                                    text: bucket.RESET ? "Resets in " + root.countdown(bucket.RESET) : "Reset time unavailable"
                                    font.pixelSize: 11
                                    color: Theme.surfaceVariantText
                                    width: parent.width
                                    elide: Text.ElideRight
                                }
                            }
                        }
                    }
                }

                Rectangle {
                    width: parent.width
                    height: 98
                    radius: 14
                    color: Theme.surfaceContainerHigh
                    Column {
                        anchors.fill: parent
                        anchors.margins: 14
                        spacing: 12
                        StyledText { text: "TOKEN CONSUMPTION"; font.pixelSize: 10; font.letterSpacing: 1.2; color: Theme.surfaceVariantText }
                        Row {
                            width: parent.width
                            Repeater {
                                model: [{label:"Today",value:root.stats.today || 0},{label:"7 days",value:root.stats.week || 0},{label:"30 days",value:root.stats.month || 0}]
                                delegate: Column {
                                    required property var modelData
                                    width: parent.width / 3
                                    spacing: 4
                                    StyledText { text: root.compact(modelData.value); color: Theme.primary; font.pixelSize: 21; font.weight: Font.DemiBold }
                                    StyledText { text: modelData.label; color: Theme.surfaceVariantText; font.pixelSize: 11 }
                                }
                            }
                        }
                    }
                }

                Rectangle {
                    width: parent.width
                    height: 128
                    radius: 14
                    color: Theme.surfaceContainerHigh
                    Column {
                        anchors.fill: parent
                        anchors.margins: 14
                        spacing: 12
                        StyledText { text: "DAILY ACTIVITY · TOKENS"; font.pixelSize: 10; font.letterSpacing: 1.2; color: Theme.surfaceVariantText }
                        Row {
                            width: parent.width
                            spacing: 7
                            Repeater {
                                model: root.stats.daily || []
                                delegate: Column {
                                    required property var modelData
                                    required property int index
                                    width: (parent.width - 42) / 7
                                    spacing: 6
                                    Item {
                                        width: parent.width
                                        height: 56
                                        Rectangle {
                                            width: parent.width
                                            height: modelData.tokens > 0 ? Math.max(3, 56 * modelData.tokens / root.maxDaily) : 2
                                            anchors.bottom: parent.bottom
                                            radius: 3
                                            color: index === 6 ? Theme.secondary : Theme.withAlpha(Theme.primary, 0.45)
                                        }
                                    }
                                    StyledText { text: modelData.day; anchors.horizontalCenter: parent.horizontalCenter; font.pixelSize: 10; color: index === 6 ? Theme.secondary : Theme.surfaceVariantText }
                                }
                            }
                        }
                    }
                }

                Rectangle {
                    width: parent.width
                    height: modelColumn.implicitHeight + 28
                    radius: 14
                    color: Theme.surfaceContainerHigh
                    Column {
                        id: modelColumn
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: parent.top
                        anchors.margins: 14
                        spacing: 10
                        StyledText { text: "MODELS · LAST 7 DAYS"; font.pixelSize: 10; font.letterSpacing: 1.2; color: Theme.surfaceVariantText }
                        StyledText { visible: !(root.stats.models || []).length; text: "No local token activity yet"; color: Theme.surfaceVariantText; font.pixelSize: 12 }
                        Repeater {
                            model: root.stats.models || []
                            delegate: Column {
                                required property var modelData
                                width: modelColumn.width
                                spacing: 5
                                Row {
                                    width: parent.width
                                    StyledText { text: modelData.name; width: parent.width - 65; elide: Text.ElideRight; color: Theme.surfaceText; font.pixelSize: 11 }
                                    StyledText { text: root.compact(modelData.tokens); width: 65; horizontalAlignment: Text.AlignRight; color: Theme.surfaceVariantText; font.pixelSize: 11 }
                                }
                                Rectangle {
                                    width: parent.width
                                    height: 4
                                    radius: 2
                                    color: Theme.surfaceVariant
                                    Rectangle { width: parent.width * Math.min(1, modelData.tokens / Math.max(1, root.stats.week || 0)); height: 4; radius: 2; color: Theme.secondary }
                                }
                            }
                        }
                    }
                }

                StyledText {
                    width: parent.width
                    text: "LOCAL LOGS  ·  " + (root.stats.sessions || 0) + " sessions / 7d\n" + (root.updatedAt ? "Quota snapshot: " + new Date(root.updatedAt).toLocaleString(Qt.locale(), "MMM d, hh:mm AP") : "Waiting for a quota snapshot")
                    font.pixelSize: 10
                    color: Theme.surfaceVariantText
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.WordWrap
                }
                Item { width: 1; height: 4 }
            }
        }
    }
}
