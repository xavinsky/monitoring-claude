import QtQuick
import "../code/quota-core.js" as Core

// Mini-graphe d'un quota sur sa periode en cours (voir drawSparkline).
Canvas {
    id: canvas

    property var points: []
    property real now: 0
    property var colors: ({})
    property string valueKey
    property string resetKey
    property real periodMs
    property string lineColorVar

    onPointsChanged: requestPaint()
    onNowChanged: requestPaint()
    onColorsChanged: requestPaint()
    onWidthChanged: requestPaint()
    onHeightChanged: requestPaint()

    onPaint: {
        if (width <= 0 || height <= 0) return;
        const ctx = getContext("2d");
        ctx.reset();
        Core.drawSparkline(ctx, width, height, points,
            { valueKey: valueKey, resetKey: resetKey, periodMs: periodMs, lineColorVar: lineColorVar },
            { col: name => colors[name] || "gray", now: now });
    }
}
