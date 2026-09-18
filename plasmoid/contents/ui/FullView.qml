import QtQuick
import QtQuick.Layouts
import "../code/quota-core.js" as Core

// Vue compacte du dashboard, ouverte au clic sur le widget : cartes des
// quotas, graphes 5h et 7j cote a cote, derniere mesure.
ColumnLayout {
    id: root

    property var points: []
    property real now: 0
    property var colors: ({})
    property int fontSize: 12

    signal openDashboard()

    readonly property var summary: Core.quotaSummary(points, now)

    spacing: 8

    RowLayout {
        Layout.fillWidth: true
        spacing: 8

        StatCard { label: "5h"; gauge: root.summary ? root.summary.session : null; colorVar: "--standard-text" }
        StatCard { label: "7j"; gauge: root.summary ? root.summary.weekly : null; colorVar: "--weekly" }
        StatCard {
            visible: !!(root.summary && root.summary.fable)
            label: "Fable"
            gauge: root.summary ? root.summary.fable : null
            colorVar: "--fable"
        }
        Card {
            implicitWidth: planRow.implicitWidth + 24
            Row {
                id: planRow
                anchors.centerIn: parent
                spacing: 8
                Text { text: "Plan"; color: root.colors["--muted"] || "gray"; font.pixelSize: root.fontSize }
                Text {
                    text: root.summary ? Core.tierName(root.summary.tier) : "-"
                    color: root.colors["--plan-line"] || "teal"
                    font.pixelSize: root.fontSize
                }
            }
        }
    }

    RowLayout {
        Layout.fillWidth: true
        Layout.fillHeight: true
        spacing: 8

        QuotaChart {
            Layout.fillWidth: true
            Layout.fillHeight: true
            points: root.points
            now: root.now
            colors: root.colors
            fontSize: root.fontSize
            opts: Core.SESSION_CHART_OPTS
        }
        QuotaChart {
            Layout.fillWidth: true
            Layout.fillHeight: true
            points: root.points
            now: root.now
            colors: root.colors
            fontSize: root.fontSize
            opts: Core.WEEKLY_CHART_OPTS
        }
    }

    RowLayout {
        Layout.fillWidth: true

        Text {
            visible: !!root.summary
            text: root.summary
                ? `Derniere mesure : ${Core.fmtDM(root.summary.last.ts)} ${Core.fmtHM(root.summary.last.ts)} - il y a ${Core.fmtAge(root.summary.ageMs)}`
                : ""
            color: root.summary && root.summary.stale ? root.colors["--stale-text"] : (root.colors["--muted"] || "gray")
            font.pixelSize: root.fontSize
        }
        Item { Layout.fillWidth: true }
        // Bouton au style de ceux du dashboard (le bouton Plasma suivrait le
        // theme du systeme, pas la palette de la vue).
        Rectangle {
            implicitWidth: openLabel.implicitWidth + 28
            implicitHeight: openLabel.implicitHeight + 12
            radius: 8
            color: openArea.containsMouse ? (root.colors["--bg"] || "#eee") : (root.colors["--panel"] || "white")
            border.color: root.colors["--border"] || "gray"

            Text {
                id: openLabel
                anchors.centerIn: parent
                text: "Ouvrir le dashboard"
                color: root.colors["--text"] || "black"
                font.pixelSize: root.fontSize
            }
            MouseArea {
                id: openArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.openDashboard()
            }
        }
    }

    component Card: Rectangle {
        color: root.colors["--panel"] || "white"
        border.color: root.colors["--border"] || "gray"
        radius: 6
        Layout.fillWidth: true
        implicitHeight: root.fontSize * 2.4
    }

    // Carte d'un quota : "ALERTE" en zone alerte, libelle, % et temps avant
    // le reset, colores selon la zone comme sur le dashboard.
    component StatCard: Card {
        id: card
        property string label
        property var gauge: null
        property string colorVar
        readonly property bool alert: !!gauge && gauge.zone === "alert"
        readonly property color valueColor: alert ? root.colors["--alert-text"] : root.colors[colorVar]
        readonly property string resetText: {
            if (!gauge || !gauge.reset) return "";
            const diffMs = new Date(gauge.reset).getTime() - root.now;
            return diffMs <= 0 && diffMs > -2 * 60000 ? "imminent" : Core.fmtResetDuration(diffMs);
        }

        implicitWidth: statRow.implicitWidth + 24

        Row {
            id: statRow
            anchors.centerIn: parent
            spacing: 8
            Text {
                visible: card.alert
                text: "ALERTE"
                color: root.colors["--alert-text"] || "red"
                font.pixelSize: root.fontSize
                font.bold: true
            }
            Text { text: card.label; color: root.colors["--muted"] || "gray"; font.pixelSize: root.fontSize }
            Text {
                text: card.gauge ? card.gauge.usage.toFixed(0) + "%" : "-"
                color: card.valueColor
                font.pixelSize: root.fontSize
                font.bold: true
            }
            Text { text: card.resetText; color: card.valueColor; font.pixelSize: root.fontSize }
        }
    }
}
