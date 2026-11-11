import QtQuick
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.plasma.components as PlasmaComponents3

Item {
    id: sheet

    property var folders: []
    property string message: ""
    property bool busy: false

    signal accepted(string url, string folder)
    signal cancelled()

    function submit() {
        if (!urlField.text)
            return
        sheet.busy = true
        sheet.accepted(urlField.text, folderField.text)
    }

    Rectangle {
        anchors.fill: parent
        color: "black"
        opacity: 0.4
        MouseArea {
            anchors.fill: parent
            onClicked: sheet.cancelled()
        }
    }

    Rectangle {
        anchors.centerIn: parent
        width: Math.min(parent.width - Kirigami.Units.gridUnit * 2, Kirigami.Units.gridUnit * 26)
        implicitHeight: cardLayout.implicitHeight + Kirigami.Units.gridUnit * 2
        radius: Kirigami.Units.smallSpacing
        color: Kirigami.Theme.backgroundColor
        border.width: 1
        border.color: Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g,
                              Kirigami.Theme.textColor.b, 0.15)

        ColumnLayout {
            id: cardLayout
            anchors.fill: parent
            anchors.margins: Kirigami.Units.gridUnit
            spacing: Kirigami.Units.smallSpacing

            Text {
                Layout.fillWidth: true
                text: i18n("Add feed")
                color: Kirigami.Theme.textColor
                font.bold: true
                font.pixelSize: Math.round(Kirigami.Units.gridUnit * 1.1)
            }

            Text {
                Layout.fillWidth: true
                text: i18n("Paste a site, feed address, or a YouTube/podcast RSS URL. Feeds are detected automatically.")
                color: Kirigami.Theme.disabledTextColor
                font.pixelSize: Math.round(Kirigami.Units.gridUnit * 0.72)
                wrapMode: Text.WordWrap
            }

            PlasmaComponents3.TextField {
                id: urlField
                Layout.fillWidth: true
                placeholderText: "https://lwn.net/headlines/rss"
                focus: true
                onAccepted: sheet.submit()
            }

            PlasmaComponents3.TextField {
                id: folderField
                Layout.fillWidth: true
                placeholderText: i18n("Folder (optional), e.g. Tech")
                onAccepted: sheet.submit()
            }

            Text {
                Layout.fillWidth: true
                visible: text.length > 0
                text: sheet.message
                color: Kirigami.Theme.negativeTextColor
                font.pixelSize: Math.round(Kirigami.Units.gridUnit * 0.72)
                wrapMode: Text.WordWrap
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
                    text: i18n("Add feed")
                    icon.name: "list-add"
                    enabled: urlField.text.length > 0 && !sheet.busy
                    onClicked: sheet.submit()
                }
            }
        }
    }
}
