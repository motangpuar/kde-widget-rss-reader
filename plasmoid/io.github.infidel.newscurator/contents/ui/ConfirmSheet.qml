import QtQuick
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.plasma.components as PlasmaComponents3

// Small modal confirmation. Used before sweeps that touch a lot of state at once, so the
// destructive action is a deliberate second decision instead of a double click.
Item {
    id: sheet

    property string title: ""
    property string message: ""
    property string detail: ""
    property string confirmLabel: ""
    property string confirmIcon: "dialog-ok-apply"

    signal confirmed()
    signal cancelled()

    Rectangle {
        anchors.fill: parent
        color: "black"
        opacity: 0.45
        MouseArea {
            anchors.fill: parent
            onClicked: sheet.cancelled()
        }
    }

    Rectangle {
        anchors.centerIn: parent
        width: Math.min(parent.width - Kirigami.Units.gridUnit * 2,
                        Kirigami.Units.gridUnit * 22)
        height: body.implicitHeight + Kirigami.Units.gridUnit * 1.5
        radius: Kirigami.Units.smallSpacing + 2
        color: Kirigami.Theme.backgroundColor
        border.width: 1
        border.color: Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g,
                              Kirigami.Theme.textColor.b, 0.35)

        ColumnLayout {
            id: body
            anchors.fill: parent
            anchors.margins: Kirigami.Units.gridUnit * 0.75
            spacing: Kirigami.Units.smallSpacing

            RowLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing
                Kirigami.Icon {
                    source: sheet.confirmIcon
                    implicitWidth: Kirigami.Units.iconSizes.smallMedium
                    implicitHeight: Kirigami.Units.iconSizes.smallMedium
                }
                Text {
                    Layout.fillWidth: true
                    text: sheet.title
                    color: Kirigami.Theme.textColor
                    font.bold: true
                    font.pixelSize: Math.round(Kirigami.Units.gridUnit * 0.92)
                    elide: Text.ElideRight
                }
            }

            Text {
                Layout.fillWidth: true
                text: sheet.message
                color: Kirigami.Theme.textColor
                wrapMode: Text.WordWrap
                font.pixelSize: Math.round(Kirigami.Units.gridUnit * 0.78)
            }

            Text {
                Layout.fillWidth: true
                visible: sheet.detail.length > 0
                text: sheet.detail
                color: Kirigami.Theme.disabledTextColor
                wrapMode: Text.WordWrap
                font.pixelSize: Math.round(Kirigami.Units.gridUnit * 0.7)
            }

            RowLayout {
                Layout.fillWidth: true
                Layout.topMargin: Kirigami.Units.smallSpacing
                spacing: Kirigami.Units.smallSpacing
                Item { Layout.fillWidth: true }
                PlasmaComponents3.Button {
                    text: i18n("Cancel")
                    onClicked: sheet.cancelled()
                }
                PlasmaComponents3.Button {
                    text: sheet.confirmLabel
                    icon.name: sheet.confirmIcon
                    onClicked: sheet.confirmed()
                }
            }
        }
    }
}
