import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import org.kde.kirigami as Kirigami
import org.kde.plasma.components as PlasmaComponents3

// Release details for the version the update check found.
//
// The strip in the list is a notification, not a decision surface: pressing Update here shows
// what the release actually contains (notes fetched lazily from the same GitHub API), the two
// versions side by side, and only then the two ways out — open the release page or skip.
Item {
    id: dialog

    property string installedVersion: ""
    property string version: ""
    property string publishedAt: ""
    property string notes: ""
    property string url: ""
    // True while the release notes request is still out.
    property bool loading: false
    property string errorText: ""

    signal openRequested()
    signal skipRequested()
    signal dismissed()

    function releasedOn(stamp) {
        if (!stamp || stamp.length < 10)
            return ""
        var date = new Date(stamp)
        if (isNaN(date.getTime()))
            return ""
        return Qt.formatDate(date, Qt.locale(), Locale.LongFormat)
    }

    Rectangle {
        anchors.fill: parent
        color: "black"
        opacity: 0.45
        MouseArea {
            anchors.fill: parent
            onClicked: dialog.dismissed()
        }
    }

    Rectangle {
        anchors.centerIn: parent
        width: Math.min(parent.width - Kirigami.Units.gridUnit,
                        Kirigami.Units.gridUnit * 24)
        height: Math.min(parent.height - Kirigami.Units.gridUnit,
                         body.implicitHeight + Kirigami.Units.gridUnit * 2)
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
                    source: "cloud-download"
                    implicitWidth: Kirigami.Units.iconSizes.smallMedium
                    implicitHeight: Kirigami.Units.iconSizes.smallMedium
                }
                Text {
                    Layout.fillWidth: true
                    text: i18n("News Curator %1", dialog.version)
                    color: Kirigami.Theme.textColor
                    font.bold: true
                    font.pixelSize: Math.round(Kirigami.Units.gridUnit * 0.95)
                    elide: Text.ElideRight
                }
                PlasmaComponents3.ToolButton {
                    icon.name: "dialog-cancel"
                    display: AbstractButton.IconOnly
                    onClicked: dialog.dismissed()
                    PlasmaComponents3.ToolTip { text: i18n("Close") }
                }
            }

            Text {
                Layout.fillWidth: true
                text: dialog.releasedOn(dialog.publishedAt).length > 0
                      ? i18n("You have %1 — released %2", dialog.installedVersion,
                             dialog.releasedOn(dialog.publishedAt))
                      : i18n("You have %1", dialog.installedVersion)
                color: Kirigami.Theme.disabledTextColor
                font.pixelSize: Math.round(Kirigami.Units.gridUnit * 0.7)
                elide: Text.ElideRight
            }

            Rectangle {
                Layout.fillWidth: true
                implicitHeight: 1
                color: Kirigami.Theme.textColor
                opacity: 0.12
            }

            // Notes are plain text from the release body; markdown headings become bold lines and
            // the rest is shown as written. No HTML rendering, no links to click by accident.
            Flickable {
                id: notesView
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.preferredHeight: Math.round(Kirigami.Units.gridUnit * 8)
                clip: true
                contentWidth: width
                contentHeight: notesColumn.implicitHeight
                boundsBehavior: Flickable.StopAtBounds
                ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

                ColumnLayout {
                    id: notesColumn
                    width: notesView.width
                    spacing: Kirigami.Units.smallSpacing / 2

                    PlasmaComponents3.BusyIndicator {
                        Layout.alignment: Qt.AlignHCenter
                        running: dialog.loading
                        visible: dialog.loading
                        implicitWidth: Kirigami.Units.iconSizes.medium
                        implicitHeight: implicitWidth
                    }

                    Text {
                        Layout.fillWidth: true
                        visible: !dialog.loading && dialog.errorText.length > 0
                        text: dialog.errorText
                        color: Kirigami.Theme.disabledTextColor
                        font.pixelSize: Math.round(Kirigami.Units.gridUnit * 0.72)
                        wrapMode: Text.WordWrap
                    }

                    Repeater {
                        model: dialog.notes.length > 0 ? dialog.notes.split("\n") : []
                        delegate: Text {
                            required property string modelData
                            readonly property bool heading: modelData.indexOf("#") === 0
                            Layout.fillWidth: true
                            text: modelData.replace(/^#+\s*/, "")
                            visible: text.trim().length > 0
                            color: Kirigami.Theme.textColor
                            font.bold: heading
                            font.pixelSize: Math.round(Kirigami.Units.gridUnit
                                                       * (heading ? 0.78 : 0.72))
                            wrapMode: Text.WordWrap
                        }
                    }

                    Text {
                        Layout.fillWidth: true
                        visible: !dialog.loading && dialog.notes.length === 0
                                 && dialog.errorText.length === 0
                        text: i18n("No release notes were published for this version.")
                        color: Kirigami.Theme.disabledTextColor
                        font.pixelSize: Math.round(Kirigami.Units.gridUnit * 0.72)
                        wrapMode: Text.WordWrap
                    }
                }
            }

            Text {
                Layout.fillWidth: true
                text: i18n("Updates are installed by the store or by a git checkout; "
                           + "this widget only points at the release.")
                color: Kirigami.Theme.disabledTextColor
                font.pixelSize: Math.round(Kirigami.Units.gridUnit * 0.66)
                wrapMode: Text.WordWrap
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing
                PlasmaComponents3.Button {
                    text: i18n("Open release page")
                    icon.name: "cloud-download"
                    onClicked: dialog.openRequested()
                }
                Item { Layout.fillWidth: true }
                PlasmaComponents3.Button {
                    text: i18n("Skip this version")
                    icon.name: "dialog-cancel"
                    onClicked: dialog.skipRequested()
                }
                PlasmaComponents3.Button {
                    text: i18n("Later")
                    onClicked: dialog.dismissed()
                }
            }
        }
    }
}
