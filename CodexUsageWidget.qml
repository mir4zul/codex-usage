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
    property real maxDaily: Math.max.apply(null, [1].concat(chartData.map(function(d) { return d.tokens; })))
    property bool detailsExpanded: pluginData.detailsExpanded !== false
    property bool alertsEnabled: pluginData.alertsEnabled === true
    property int chartDays: pluginData.chartDays === 30 ? 30 : 7
    property var chartData: chartDays === 30 ? (stats.daily30 || []) : (stats.daily || [])
    property string hoveredDay: ""
    onChartDaysChanged: hoveredDay = ""
    property real snapshotAge: updatedAt ? Math.max(0, countdownNow - new Date(updatedAt).getTime()) : Infinity
    property bool snapshotStale: !isFinite(snapshotAge) || snapshotAge > 30 * 60000
    property string freshnessText: {
        if (!updatedAt) return "Waiting for a local snapshot";
        if (!isFinite(snapshotAge)) return "Snapshot time unavailable";
        var minutes = Math.floor(snapshotAge / 60000);
        var age = minutes < 1 ? "just now" : (minutes < 60 ? minutes + " min ago" : (minutes < 1440 ? Math.floor(minutes / 60) + "h ago" : Math.floor(minutes / 1440) + "d ago"));
        return (snapshotStale ? "Stale · " : "Updated ") + age;
    }
    property string weekTrend: {
        var previous = stats.previous_week || 0;
        if (!previous) return "Daily tokens · last 7 days";
        var change = Math.round(((stats.week || 0) - previous) / previous * 100);
        return (change > 0 ? "+" : "") + change + "% vs previous 7 days";
    }
    property string breakdownText: {
        var b = stats.breakdown_week || {};
        if (b.input_tokens === undefined && b.output_tokens === undefined) return "Token breakdown unavailable in local logs";
        return "7d input " + compact(b.input_tokens || 0) + " · output " + compact(b.output_tokens || 0)
            + "\nCached input " + compact(b.cached_input_tokens || 0) + " (included in input)";
    }
    function savePreference(key, value) {
        SettingsData.setPluginSetting("codexUsage", key, value);
        pluginData = SettingsData.getPluginSettingsForPlugin("codexUsage");
    }
    function checkAlerts() {
        if (!alertsEnabled || snapshotStale || !loggedIn) return;
        var seen = Object.assign({}, pluginData.alertHistory || {});
        var changed = false;
        ["primary", "secondary"].forEach(function(id) {
            var b = buckets[id];
            if (!b || b.REMAINING === undefined || !b.RESET || new Date(b.RESET).getTime() <= Date.now()) return;
            var used = Math.max(0, Math.min(100, (1 - Number(b.REMAINING)) * 100));
            var level = used >= 90 ? 90 : (used >= 80 ? 80 : 0);
            var prior = seen[id] || {};
            if (!level || (prior.reset === b.RESET && prior.level >= level)) return;
            ToastService.showWarning("Codex " + (id === "primary" ? "5-hour" : "weekly") + " usage: " + Math.round(used) + "%", "Last local snapshot · resets in " + countdown(b.RESET));
            seen[id] = {reset: b.RESET, level: level};
            changed = true;
        });
        if (changed) savePreference("alertHistory", seen);
    }
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

    popoutWidth: 420
    popoutHeight: detailsExpanded ? 820 : 500

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
            if (exitCode === 0) root.checkAlerts();
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
            Behavior on value { NumberAnimation { duration: 350; easing.type: Easing.OutCubic } }
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
            text: Math.round(parent.percent) + "%\nused"
            horizontalAlignment: Text.AlignHCenter
            color: Theme.surfaceText
            font.pixelSize: 17
            font.weight: Font.DemiBold
        }
    }

    component ActionChip: Rectangle {
        id: chip
        property string label: ""
        property bool selected: false
        signal clicked()
        width: chipText.implicitWidth + 22
        height: 30
        radius: 15
        color: selected ? Theme.withAlpha(Theme.primary, 0.16) : (chipMouse.containsMouse ? Theme.surfaceContainerHigh : "transparent")
        StyledText {
            id: chipText
            anchors.centerIn: parent
            text: chip.label
            font.pixelSize: 12
            font.weight: chip.selected ? Font.DemiBold : Font.Normal
            color: chip.selected ? Theme.primary : Theme.surfaceVariantText
        }
        MouseArea {
            id: chipMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: chip.clicked()
        }
    }

    popoutContent: Component {
        PopoutComponent {
            headerText: "Codex Usage"
            detailsText: (root.plan || "Codex") + " · Local usage insights"
            showCloseButton: true
            Column {
                width: parent.width - 16
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: 12

                Row {
                    width: parent.width
                    spacing: 6
                    Rectangle {
                        width: 7; height: 7; radius: 4
                        anchors.verticalCenter: parent.verticalCenter
                        color: root.snapshotStale ? Theme.warning : Theme.primary
                    }
                    StyledText {
                        width: parent.width - refreshChip.width - 19
                        anchors.verticalCenter: parent.verticalCenter
                        text: root.freshnessText
                        color: root.snapshotStale ? Theme.warning : Theme.surfaceVariantText
                        font.pixelSize: 12
                        elide: Text.ElideRight
                    }
                    ActionChip {
                        id: refreshChip
                        label: root.isLoading ? "Reading…" : "Refresh"
                        onClicked: {
                            if (!usageProcess.running) {
                                root.isLoading = true;
                                usageProcess.running = true;
                            }
                        }
                    }
                }

                Rectangle {
                    visible: !root.loggedIn
                    width: parent.width; height: 72; radius: 16
                    color: Theme.surfaceContainerHigh
                    StyledText {
                        anchors.fill: parent; anchors.margins: 16
                        text: root.isLoading ? "Reading local usage…" : "No quota snapshot yet. Use Codex to record your limits."
                        wrapMode: Text.WordWrap; font.pixelSize: 13
                        color: Theme.surfaceVariantText
                    }
                }

                Row {
                    width: parent.width
                    spacing: 12
                    visible: root.loggedIn
                    Repeater {
                        model: ["primary", "secondary"]
                        delegate: Rectangle {
                            id: quotaCard
                            required property string modelData
                            property var bucket: root.buckets[modelData] || ({})
                            property bool recorded: bucket.REMAINING !== undefined
                            property real used: recorded ? Math.max(0, Math.min(100, (1-bucket.REMAINING)*100)) : 0
                            property bool expired: bucket.RESET ? new Date(bucket.RESET).getTime() <= root.countdownNow : false
                            property color accent: used >= 80 ? Theme.error : (used >= 50 ? Theme.warning : (modelData === "primary" ? Theme.primary : Theme.secondary))
                            width: (parent.width - 12) / 2
                            height: 208; radius: 20
                            color: Theme.surfaceContainerHigh
                            border.width: 1
                            border.color: Theme.withAlpha(accent, 0.16)
                            Column {
                                anchors.fill: parent; anchors.margins: 14
                                spacing: 9
                                StyledText {
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    text: quotaCard.modelData === "primary" ? "5-hour limit" : "Weekly limit"
                                    font.pixelSize: 14; font.weight: Font.DemiBold
                                    color: Theme.surfaceText
                                }
                                UsageRing {
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    width: 88; height: 88
                                    percent: quotaCard.used
                                    accent: quotaCard.accent
                                    opacity: quotaCard.recorded ? 1 : 0.35
                                }
                                StyledText {
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    text: quotaCard.recorded ? (100-Math.round(quotaCard.used)) + "% remaining" : "Not recorded"
                                    font.pixelSize: 13; color: quotaCard.accent
                                }
                                StyledText {
                                    width: parent.width
                                    horizontalAlignment: Text.AlignHCenter
                                    text: quotaCard.expired ? "Waiting for fresh data" : (quotaCard.bucket.RESET ? "Reset in " + root.countdown(quotaCard.bucket.RESET) : "Reset unavailable")
                                    font.pixelSize: 11
                                    color: quotaCard.expired ? Theme.warning : Theme.surfaceVariantText
                                    wrapMode: Text.WordWrap
                                }
                            }
                        }
                    }
                }

                Rectangle {
                    width: parent.width; height: 94; radius: 18
                    color: Theme.surfaceContainerHigh
                    Column {
                        anchors.fill: parent; anchors.margins: 14; spacing: 10
                        StyledText { text: "Token activity"; font.pixelSize: 13; color: Theme.surfaceVariantText }
                        Row {
                            width: parent.width
                            Repeater {
                                model: [{label:"Today",value:root.stats.today || 0},{label:"7 days",value:root.stats.week || 0},{label:"30 days",value:root.stats.month || 0}]
                                delegate: Column {
                                    required property var modelData
                                    width: parent.width / 3; spacing: 3
                                    StyledText { text: root.compact(modelData.value); color: Theme.surfaceText; font.pixelSize: 23; font.weight: Font.DemiBold }
                                    StyledText { text: modelData.label; color: Theme.surfaceVariantText; font.pixelSize: 12 }
                                }
                            }
                        }
                    }
                }

                Row {
                    width: parent.width; spacing: 6
                    ActionChip {
                        label: root.detailsExpanded ? "Less detail ↑" : "More detail ↓"
                        selected: root.detailsExpanded
                        onClicked: root.savePreference("detailsExpanded", !root.detailsExpanded)
                    }
                    ActionChip {
                        label: root.alertsEnabled ? "Alerts on · 80/90%" : "Alerts off"
                        selected: root.alertsEnabled
                        onClicked: root.savePreference("alertsEnabled", !root.alertsEnabled)
                    }
                }

                Rectangle {
                    visible: root.detailsExpanded
                    width: parent.width; height: 180; radius: 18
                    color: Theme.surfaceContainerHigh
                    Column {
                        anchors.fill: parent; anchors.margins: 14; spacing: 8
                        Row {
                            width: parent.width
                            StyledText {
                                text: "Activity"; width: parent.width - 112
                                anchors.verticalCenter: parent.verticalCenter
                                font.pixelSize: 14; font.weight: Font.DemiBold; color: Theme.surfaceText
                            }
                            ActionChip { label: "7d"; selected: root.chartDays === 7; onClicked: root.savePreference("chartDays", 7) }
                            ActionChip { label: "30d"; selected: root.chartDays === 30; onClicked: root.savePreference("chartDays", 30) }
                        }
                        StyledText {
                            text: root.hoveredDay || (root.chartDays === 7 ? root.weekTrend : "Daily tokens · last 30 days")
                            width: parent.width; elide: Text.ElideRight
                            font.pixelSize: 12; color: root.hoveredDay ? Theme.primary : Theme.surfaceVariantText
                        }
                        Row {
                            width: parent.width; spacing: root.chartDays === 7 ? 8 : 3
                            Repeater {
                                model: root.chartData
                                delegate: Column {
                                    required property var modelData
                                    required property int index
                                    width: (parent.width - parent.spacing * (root.chartData.length - 1)) / Math.max(1, root.chartData.length)
                                    spacing: 6
                                    Item {
                                        width: parent.width; height: 64
                                        Rectangle {
                                            anchors.bottom: parent.bottom
                                            width: parent.width
                                            height: modelData.tokens > 0 ? Math.max(3, 64 * modelData.tokens / root.maxDaily) : 2
                                            radius: Math.min(4, width / 2)
                                            color: dayHover.containsMouse || index === root.chartData.length - 1 ? Theme.primary : Theme.withAlpha(Theme.primary, 0.36)
                                            Behavior on height { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
                                        }
                                        MouseArea {
                                            id: dayHover
                                            anchors.fill: parent; hoverEnabled: true
                                            onEntered: root.hoveredDay = modelData.date + " · " + Number(modelData.tokens).toLocaleString(Qt.locale(), 'f', 0) + " tokens"
                                            onExited: root.hoveredDay = ""
                                        }
                                    }
                                    StyledText {
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        text: root.chartDays === 7 ? modelData.day : ((index === 0 || index === 14 || index === 29) ? modelData.date.slice(8) : "")
                                        font.pixelSize: 10; color: Theme.surfaceVariantText
                                    }
                                }
                            }
                        }
                    }
                }

                Rectangle {
                    visible: root.detailsExpanded
                    width: parent.width; height: modelColumn.implicitHeight + 28; radius: 18
                    color: Theme.surfaceContainerHigh
                    Column {
                        id: modelColumn
                        anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
                        anchors.margins: 14; spacing: 10
                        StyledText { text: "Top models · 7 days"; font.pixelSize: 14; font.weight: Font.DemiBold; color: Theme.surfaceText }
                        StyledText { visible: !(root.stats.models || []).length; text: "No local token activity yet"; font.pixelSize: 12; color: Theme.surfaceVariantText }
                        Repeater {
                            model: root.stats.models || []
                            delegate: Column {
                                required property var modelData
                                width: modelColumn.width; spacing: 5
                                Row {
                                    width: parent.width
                                    StyledText { text: modelData.name; width: parent.width - 106; elide: Text.ElideRight; font.pixelSize: 12; color: Theme.surfaceText }
                                    StyledText { text: root.compact(modelData.tokens) + " · " + Math.round(100 * modelData.tokens / Math.max(1, root.stats.week || 0)) + "%"; width: 106; horizontalAlignment: Text.AlignRight; font.pixelSize: 12; color: Theme.surfaceVariantText }
                                }
                                Rectangle {
                                    width: parent.width; height: 4; radius: 2; color: Theme.surfaceVariant
                                    Rectangle {
                                        width: parent.width * Math.min(1, modelData.tokens / Math.max(1, root.stats.week || 0))
                                        height: 4; radius: 2; color: Theme.secondary
                                        Behavior on width { NumberAnimation { duration: 220 } }
                                    }
                                }
                            }
                        }
                        StyledText {
                            width: parent.width
                            text: root.breakdownText
                            font.pixelSize: 11; color: Theme.surfaceVariantText; wrapMode: Text.WordWrap
                        }
                    }
                }
                StyledText {
                    width: parent.width
                    text: "Local estimates · " + (root.stats.sessions || 0) + " sessions / 7 days\nRefresh reads local logs; it does not fetch live quota."
                    font.pixelSize: 11; color: Theme.surfaceVariantText
                    horizontalAlignment: Text.AlignHCenter; wrapMode: Text.WordWrap
                }
                Item { width: 1; height: 4 }
            }
        }
    }
}
