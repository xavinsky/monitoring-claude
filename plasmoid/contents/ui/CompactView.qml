import QtQuick
import QtQuick.Layouts
import "../code/quota-core.js" as Core

// Vue dans la barre : pour chaque quota (5h, 7j, et Fable si le plan en a
// un), une petite carte claire avec libelle + mini-graphe de la periode en
// cours + %, voilee de rouge pale en zone alerte. Attenuee quand la
// derniere mesure est perimee.
GridLayout {
    id: root

    property var points: []
    property real now: 0
    property var colors: ({})
    property bool vertical: false
    property int fontSize: 12

    readonly property var summary: Core.quotaSummary(points, now)
    readonly property var gauges: {
        if (!summary) return [];
        const list = [
            { label: "5h", gauge: summary.session, valueKey: "session", resetKey: "sessionReset", periodMs: Core.SESSION_PERIOD_MS, colorVar: "--standard-text" },
            { label: "7j", gauge: summary.weekly, valueKey: "weekly", resetKey: "weeklyReset", periodMs: Core.WEEKLY_PERIOD_MS, colorVar: "--weekly" },
        ];
        if (summary.fable) {
            list.push({ label: "Fable", gauge: summary.fable, valueKey: "fable", resetKey: "fableReset", periodMs: Core.WEEKLY_PERIOD_MS, colorVar: "--fable" });
        }
        return list;
    }

    // Couleur de la palette (syntaxe CSS, comprise par le Canvas) pour un
    // element QML, qui ne lit pas "rgba(r, g, b, a)".
    function qtColor(css) {
        const m = /^rgba\(([\d.]+),\s*([\d.]+),\s*([\d.]+),\s*([\d.]+)\)$/.exec(css || "");
        return m ? Qt.rgba(m[1] / 255, m[2] / 255, m[3] / 255, Number(m[4])) : (css || "transparent");
    }

    flow: vertical ? GridLayout.TopToBottom : GridLayout.LeftToRight
    columns: vertical ? 1 : -1
    columnSpacing: 3
    rowSpacing: 3
    opacity: summary && summary.stale ? 0.55 : 1

    Text {
        visible: !root.summary
        text: "Claude ?"
        color: root.colors["--muted"] || "gray"
        font.pixelSize: root.fontSize
        Layout.alignment: Qt.AlignCenter
    }

    Repeater {
        model: root.gauges

        // Barre horizontale : libelle, mini-graphe et % sur une ligne. Barre
        // verticale : libelle et % au-dessus du mini-graphe, sur toute la
        // largeur.
        delegate: Rectangle {
            id: cell
            required property var modelData
            readonly property bool alert: modelData.gauge.zone === "alert"
            readonly property real sparkHeight: root.vertical
                ? Math.max(10, Math.round((width - 6) / 1.7))
                : Math.max(10, height - 6)

            color: root.colors["--panel"] || "white"
            border.color: alert ? root.colors["--alert-text"] : (root.colors["--border"] || "gray")
            border.width: 1
            radius: 3
            Layout.fillHeight: !root.vertical
            Layout.fillWidth: root.vertical
            implicitWidth: content.implicitWidth + 8
            implicitHeight: content.implicitHeight + 6

            Rectangle {
                anchors.fill: parent
                anchors.margins: 1
                radius: parent.radius
                visible: cell.alert
                color: root.qtColor(root.colors["--alert-zone"])
            }

            GridLayout {
                id: content
                anchors.centerIn: parent
                flow: root.vertical ? GridLayout.TopToBottom : GridLayout.LeftToRight
                columnSpacing: 3
                rowSpacing: 1

                Row {
                    Layout.alignment: Qt.AlignCenter
                    spacing: 3
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: cell.modelData.label
                        color: root.colors["--muted"] || "gray"
                        font.pixelSize: root.fontSize * 0.85
                    }
                    Text {
                        visible: root.vertical
                        anchors.verticalCenter: parent.verticalCenter
                        text: cell.modelData.gauge.usage.toFixed(0) + "%"
                        color: cell.alert ? root.colors["--alert-text"] : root.colors[cell.modelData.colorVar]
                        font.pixelSize: root.fontSize
                        font.bold: true
                    }
                }

                Sparkline {
                    Layout.alignment: Qt.AlignCenter
                    Layout.preferredHeight: cell.sparkHeight
                    Layout.preferredWidth: root.vertical ? cell.width - 6 : Math.round(cell.sparkHeight * 1.7)
                    points: root.points
                    now: root.now
                    colors: root.colors
                    valueKey: cell.modelData.valueKey
                    resetKey: cell.modelData.resetKey
                    periodMs: cell.modelData.periodMs
                    lineColorVar: cell.modelData.colorVar
                }

                Text {
                    visible: !root.vertical
                    Layout.alignment: Qt.AlignVCenter
                    text: cell.modelData.gauge.usage.toFixed(0) + "%"
                    color: cell.alert ? root.colors["--alert-text"] : root.colors[cell.modelData.colorVar]
                    font.pixelSize: root.fontSize
                    font.bold: true
                }
            }
        }
    }
}
