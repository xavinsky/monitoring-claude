import QtQuick
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.plasma5support as P5Support
import org.kde.kirigami as Kirigami
import "../code/quota-core.js" as Core
import "../code/palette.js" as Palette
// Genere par install.sh dans la copie installee : chemin du dashboard.
import "../code/install.js" as Install

// Widget Plasma : dans la barre, mini-graphes et % des quotas (CompactView) ;
// au clic, vue compacte du dashboard (FullView). Lit usage.csv, alimente
// par le timer claude-usage-log, sans aucun appel reseau.
PlasmoidItem {
    id: root

    property var points: []
    property real now: Date.now()

    readonly property var summary: Core.quotaSummary(points, now)
    readonly property int fontSize: Math.round(Kirigami.Units.gridUnit * 0.72)

    // 3 semaines de mesures (une toutes les 10 min) suffisent aux graphes.
    readonly property string readCommand: 'tail -n 3300 "$HOME/.config/monitoring-claude/usage.csv"'

    function refresh() {
        exec.connectSource(readCommand);
    }

    function gaugeLine(label, gauge) {
        if (!gauge) return "";
        let line = `${label} : ${gauge.usage.toFixed(0)}% - zone ${gauge.zone === "alert" ? "alerte" : "standard"}`;
        if (gauge.exitAt) line += `, sortie vers ${Core.fmtHM(new Date(gauge.exitAt))}`;
        if (gauge.reset) line += ` (reset dans ${Core.fmtResetDuration(new Date(gauge.reset).getTime() - now)})`;
        return line;
    }

    toolTipMainText: summary ? `Quota Claude - ${Core.tierName(summary.tier)}` : "Quota Claude"
    toolTipSubText: {
        if (!summary) return "Aucune mesure dans ~/.config/monitoring-claude/usage.csv";
        const lines = [
            gaugeLine("5h", summary.session),
            gaugeLine("7j", summary.weekly),
            gaugeLine("Fable", summary.fable),
            `Derniere mesure il y a ${Core.fmtAge(summary.ageMs)}${summary.stale ? " (perimee)" : ""}`,
        ];
        return lines.filter(l => l).join("\n");
    }

    // Vue de la barre quand la place manque (panneau), vue complete des
    // qu'il y a la place (bureau, fenetre).
    switchWidth: Kirigami.Units.gridUnit * 36
    switchHeight: Kirigami.Units.gridUnit * 14

    compactRepresentation: MouseArea {
        readonly property bool vertical: Plasmoid.formFactor === PlasmaCore.Types.Vertical
        Layout.minimumWidth: vertical ? -1 : compactView.implicitWidth
        Layout.preferredWidth: vertical ? -1 : compactView.implicitWidth
        Layout.minimumHeight: vertical ? compactView.implicitHeight : -1
        Layout.preferredHeight: vertical ? compactView.implicitHeight : -1

        onClicked: root.expanded = !root.expanded

        CompactView {
            id: compactView
            anchors.fill: parent
            points: root.points
            now: root.now
            colors: Palette.LIGHT
            fontSize: root.fontSize
            vertical: parent.vertical
        }
    }

    // Popup en clair, comme la barre et le dashboard.
    fullRepresentation: Rectangle {
        Layout.minimumWidth: Kirigami.Units.gridUnit * 36
        Layout.preferredWidth: Kirigami.Units.gridUnit * 56
        Layout.minimumHeight: Kirigami.Units.gridUnit * 14
        Layout.preferredHeight: Kirigami.Units.gridUnit * 20
        color: Palette.LIGHT["--bg"]
        radius: 6

        FullView {
            anchors.fill: parent
            anchors.margins: Kirigami.Units.largeSpacing
            points: root.points
            now: root.now
            colors: Palette.LIGHT
            fontSize: root.fontSize
            onOpenDashboard: {
                Qt.openUrlExternally("file://" + encodeURI(Install.DASHBOARD_FILE));
                root.expanded = false;
            }
        }
    }

    onExpandedChanged: if (root.expanded) refresh()

    P5Support.DataSource {
        id: exec
        engine: "executable"
        connectedSources: []
        onNewData: (source, data) => {
            disconnectSource(source);
            if (source === root.readCommand) {
                root.points = Core.parseUsageCsv(data["stdout"] || "");
                root.now = Date.now();
            }
        }
    }

    // Le CSV change toutes les 10 min ; relu chaque minute pour que la ligne
    // "maintenant" et les zones avancent.
    Timer {
        interval: 60 * 1000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: root.refresh()
    }
}
