import QtQuick
import "../code/quota-core.js" as Core

// Graphe complet d'un quota en vue compacte (meme dessin que le dashboard,
// voir drawChart), avec la valeur du point le plus proche au survol.
Item {
    id: root

    property var points: []
    property real now: 0
    property var colors: ({})
    property var opts: ({})
    property int fontSize: 12

    // Projection temps -> abscisse et points affiches, pour le survol.
    property var mapping: null

    Canvas {
        id: canvas
        anchors.fill: parent

        onPaint: {
            if (width <= 0 || height <= 0) return;
            const ctx = getContext("2d");
            ctx.reset();
            root.mapping = Core.drawChart(ctx, width, height, root.points, root.opts, {
                col: name => root.colors[name] || "gray",
                compact: true,
                now: root.now,
                fontAxis: root.fontSize,
                fontDayLabel: root.fontSize,
                fontEmpty: root.fontSize,
            });
        }
    }

    onPointsChanged: canvas.requestPaint()
    onNowChanged: canvas.requestPaint()
    onColorsChanged: canvas.requestPaint()
    onWidthChanged: canvas.requestPaint()
    onHeightChanged: canvas.requestPaint()

    MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        onExited: tip.visible = false
        onPositionChanged: mouse => {
            const m = root.mapping;
            if (!m || !m.visible.length) return;
            let nearest = m.visible[0];
            let best = Infinity;
            m.visible.forEach(p => {
                const d = Math.abs(m.x(p.ts.getTime()) - mouse.x);
                if (d < best) { best = d; nearest = p; }
            });
            const time = Core.fmtHM(nearest.ts);
            const when = root.opts.tooltipShowDate ? `${Core.fmtDM(nearest.ts)} (${time})` : time;
            const sk = root.opts.secondaryKey;
            const secondary = (sk && !isNaN(nearest[sk])) ? ` - ${root.opts.secondaryLabel} ${nearest[sk].toFixed(0)}%` : "";
            tipText.text = `${when} ${nearest[root.opts.valueKey].toFixed(0)}%${secondary}`;
            tip.x = Math.min(mouse.x + 12, root.width - tip.width);
            tip.visible = true;
        }
    }

    Rectangle {
        id: tip
        visible: false
        y: 4
        width: tipText.implicitWidth + 12
        height: tipText.implicitHeight + 6
        color: root.colors["--panel"] || "white"
        border.color: root.colors["--border"] || "gray"
        radius: 4

        Text {
            id: tipText
            anchors.centerIn: parent
            color: root.colors["--text"] || "black"
            font.pixelSize: root.fontSize
        }
    }
}
