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
    property bool useAccentColor: pluginData.useAccentColor === true  // default off (brand blue)
    readonly property color brandColor: "#10A37F"               // Antigravity blue

    // Account/session state
    property bool loggedIn: false
    property bool isLoading: true
    property string account: ""
    property string plan: ""
    property string cliVersion: ""
    property string updatedAt: ""

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
    popoutHeight: 520

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
                    colorizationColor: root.useAccentColor ? Theme.primary : root.brandColor
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

    // --- Popout ---

    popoutContent: Component {
        PopoutComponent {
            headerText: root.tr("Codex Usage")
            detailsText: {
                if (!root.loggedIn)
                    return "";
                var parts = [];
                if (root.account)
                    parts.push(root.account);
                if (root.plan)
                    parts.push(root.plan);
                if (root.updatedAt)
                    parts.push("Updated " + new Date(root.updatedAt).toLocaleString());
                return parts.join("  ·  ");
            }
            showCloseButton: true

            Column {
                width: parent.width - Theme.spacingM * 2
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: Theme.spacingL

                // Empty / not-signed-in state
                StyledRect {
                    width: parent.width
                    height: emptyCol.implicitHeight + Theme.spacingL * 2
                    color: Theme.surfaceContainerHigh
                    visible: !root.loggedIn

                    Column {
                        id: emptyCol
                        anchors.centerIn: parent
                        width: parent.width - Theme.spacingM * 2
                        spacing: Theme.spacingS

                        DankIcon {
                            name: root.isLoading ? "hourglass_empty" : "account_circle_off"
                            size: 28
                            color: Theme.surfaceVariantText
                            anchors.horizontalCenter: parent.horizontalCenter
                        }
                        StyledText {
                            text: root.isLoading ? root.tr("Loading...") : root.tr("No usage recorded")
                            font.pixelSize: Theme.fontSizeMedium
                            font.weight: Font.Medium
                            color: Theme.surfaceText
                            anchors.horizontalCenter: parent.horizontalCenter
                        }
                        StyledText {
                            text: root.tr("Run codex login, then use Codex to record usage.")
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceVariantText
                            wrapMode: Text.WordWrap
                            horizontalAlignment: Text.AlignHCenter
                            width: parent.width
                            visible: !root.isLoading
                        }
                    }
                }

                // One card per model group, each with its limit bars.
                Repeater {
                    model: root.loggedIn ? root.groups : []
                    delegate: StyledRect {
                        required property var modelData
                        width: parent.width
                        height: groupCol.implicitHeight + Theme.spacingM * 2
                        color: Theme.surfaceContainerHigh

                        Column {
                            id: groupCol
                            anchors.fill: parent
                            anchors.margins: Theme.spacingM
                            spacing: Theme.spacingM

                            StyledText {
                                text: modelData.name
                                font.pixelSize: Theme.fontSizeMedium
                                font.weight: Font.Medium
                                color: Theme.surfaceText
                            }
                            StyledText {
                                text: modelData.desc
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.surfaceVariantText
                                wrapMode: Text.WordWrap
                                width: parent.width
                                visible: modelData.desc !== ""
                            }

                            // Limit bars (Weekly + Five Hour)
                            Repeater {
                                model: modelData.buckets
                                delegate: Column {
                                    required property var modelData
                                    width: groupCol.width
                                    spacing: 4

                                    property real usedPct: Math.max(0, Math.min(100, (1 - modelData.remaining) * 100))
                                    property string resetCd: root.countdown(modelData.reset)

                                    Row {
                                        width: parent.width
                                        StyledText {
                                            text: modelData.label === "Weekly Limit" ? root.tr("Weekly Limit") : (modelData.label === "Five Hour Limit" ? root.tr("Five Hour Limit") : modelData.label)
                                            font.pixelSize: Theme.fontSizeSmall
                                            color: Theme.surfaceText
                                            width: parent.width - usedLabel.implicitWidth
                                            elide: Text.ElideRight
                                        }
                                        StyledText {
                                            id: usedLabel
                                            text: Math.round(parent.parent.usedPct) + "% " + root.tr("used")
                                            font.pixelSize: Theme.fontSizeSmall
                                            font.weight: Font.Medium
                                            color: root.progressColor(parent.parent.usedPct)
                                        }
                                    }

                                    Rectangle {
                                        width: parent.width
                                        height: 6
                                        radius: 3
                                        color: Theme.surfaceVariant

                                        Rectangle {
                                            width: parent.width * Math.min(parent.parent.usedPct / 100, 1)
                                            height: parent.height
                                            radius: 3
                                            color: root.progressColor(parent.parent.usedPct)
                                            Behavior on width {
                                                NumberAnimation {
                                                    duration: 200
                                                }
                                            }
                                        }
                                    }

                                    StyledText {
                                        text: {
                                            var left = (100 - Math.round(parent.usedPct)) + "% " + root.tr("left");
                                            return parent.resetCd ? left + "  ·  " + root.tr("Resets in") + " " + parent.resetCd : left;
                                        }
                                        font.pixelSize: Theme.fontSizeSmall
                                        color: Theme.surfaceVariantText
                                    }
                                }
                            }
                        }
                    }
                }

                // Bottom padding
                Item {
                    width: 1
                    height: 1
                }
            }
        }
    }
}
