import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import org.kde.kirigami as Kirigami
import org.kde.plasma.components as PlasmaComponents3

Item {
    id: sheet

    property var prefs: ({})
    property var feeds: []
    property int port: 8770
    property bool backendUp: false

    signal closed()
    signal prefChanged(string key, var value)
    signal portEdited(int value)
    signal refreshNowRequested()
    signal importOpml(string text)
    signal deleteFeedRequested(int id)

    function pref(key, fallback) {
        var value = prefs ? prefs[key] : undefined
        return value === undefined || value === null ? fallback : value
    }

    Rectangle {
        anchors.fill: parent
        color: "black"
        opacity: 0.4
        MouseArea {
            anchors.fill: parent
            onClicked: sheet.closed()
        }
    }

    Rectangle {
        anchors.centerIn: parent
        width: Math.min(parent.width - Kirigami.Units.gridUnit * 2, Kirigami.Units.gridUnit * 32)
        height: Math.min(parent.height - Kirigami.Units.gridUnit * 2,
                         cardColumn.implicitHeight + Kirigami.Units.gridUnit * 2)
        radius: Kirigami.Units.smallSpacing
        color: Kirigami.Theme.backgroundColor
        border.width: 1
        border.color: Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g,
                              Kirigami.Theme.textColor.b, 0.15)

        ColumnLayout {
            id: cardColumn
            anchors.fill: parent
            anchors.margins: Kirigami.Units.gridUnit
            spacing: Kirigami.Units.smallSpacing

            RowLayout {
                Layout.fillWidth: true
                Text {
                    Layout.fillWidth: true
                    text: i18n("Settings")
                    color: Kirigami.Theme.textColor
                    font.bold: true
                    font.pixelSize: Math.round(Kirigami.Units.gridUnit * 1.1)
                }
                PlasmaComponents3.ToolButton {
                    icon.name: "window-close"
                    display: AbstractButton.IconOnly
                    onClicked: sheet.closed()
                }
            }

            PlasmaComponents3.ScrollView {
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                ScrollBar.vertical.policy: ScrollBar.AsNeeded
                contentWidth: availableWidth

                ColumnLayout {
                    width: sheet.width - Kirigami.Units.gridUnit * 2
                    spacing: Kirigami.Units.smallSpacing

                    Text {
                        Layout.fillWidth: true
                        text: i18n("Backend")
                        color: Kirigami.Theme.textColor
                        font.bold: true
                        font.pixelSize: Math.round(Kirigami.Units.gridUnit * 0.85)
                        Layout.topMargin: Kirigami.Units.smallSpacing
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Kirigami.Units.smallSpacing
                        Text {
                            text: i18n("Port")
                            color: Kirigami.Theme.textColor
                            font.pixelSize: Math.round(Kirigami.Units.gridUnit * 0.78)
                        }
                        SpinBox {
                            from: 1024
                            to: 65535
                            stepSize: 1
                            editable: true
                            value: sheet.port
                            onValueModified: sheet.portEdited(value)
                        }
                        Item { Layout.fillWidth: true }
                        Text {
                            text: sheet.backendUp ? i18n("Connected") : i18n("Offline")
                            color: sheet.backendUp ? Kirigami.Theme.positiveTextColor
                                                   : Kirigami.Theme.negativeTextColor
                            font.pixelSize: Math.round(Kirigami.Units.gridUnit * 0.72)
                        }
                    }

                    Text {
                        Layout.fillWidth: true
                        text: i18n("Run the daemon with: systemctl --user start knewsd")
                        color: Kirigami.Theme.disabledTextColor
                        font.pixelSize: Math.round(Kirigami.Units.gridUnit * 0.68)
                        wrapMode: Text.WordWrap
                    }

                    Rectangle {
                        Layout.fillWidth: true
                        implicitHeight: 1
                        color: Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g,
                                       Kirigami.Theme.textColor.b, 0.12)
                    }

                    Text {
                        Layout.fillWidth: true
                        text: i18n("Reading")
                        color: Kirigami.Theme.textColor
                        font.bold: true
                        font.pixelSize: Math.round(Kirigami.Units.gridUnit * 0.85)
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Kirigami.Units.smallSpacing / 2
                        Repeater {
                            model: ["auto", "light", "sepia", "dark"]
                            delegate: Rectangle {
                                required property string modelData
                                readonly property bool active: sheet.pref("reader_theme", "auto") === modelData
                                implicitWidth: themeLabel.implicitWidth + Kirigami.Units.gridUnit * 0.8
                                implicitHeight: Math.round(Kirigami.Units.gridUnit * 1.3)
                                radius: implicitHeight / 2
                                color: active ? Kirigami.Theme.highlightColor
                                              : Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g,
                                                        Kirigami.Theme.textColor.b, 0.1)
                                Text {
                                    id: themeLabel
                                    anchors.centerIn: parent
                                    text: modelData
                                    color: parent.active ? Kirigami.Theme.highlightedTextColor
                                                         : Kirigami.Theme.textColor
                                    font.pixelSize: Math.round(Kirigami.Units.gridUnit * 0.7)
                                    font.capitalization: Font.Capitalize
                                }
                                MouseArea {
                                    anchors.fill: parent
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: sheet.prefChanged("reader_theme", modelData)
                                }
                            }
                        }
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Kirigami.Units.smallSpacing
                        Text {
                            text: i18n("Text size")
                            color: Kirigami.Theme.textColor
                            font.pixelSize: Math.round(Kirigami.Units.gridUnit * 0.78)
                        }
                        PlasmaComponents3.Slider {
                            Layout.fillWidth: true
                            from: 80
                            to: 170
                            stepSize: 10
                            snapMode: Slider.SnapAlways
                            value: sheet.pref("font_scale", 100)
                            onMoved: sheet.prefChanged("font_scale", Math.round(value))
                        }
                        Text {
                            text: sheet.pref("font_scale", 100) + "%"
                            color: Kirigami.Theme.disabledTextColor
                            font.pixelSize: Math.round(Kirigami.Units.gridUnit * 0.72)
                        }
                    }

                    PlasmaComponents3.CheckBox {
                        text: i18n("Serif body text")
                        checked: sheet.pref("serif", 0) === 1
                        onClicked: sheet.prefChanged("serif", checked ? 1 : 0)
                    }
                    PlasmaComponents3.CheckBox {
                        text: i18n("Mark read when opened")
                        checked: sheet.pref("auto_mark_read", 1) === 1
                        onClicked: sheet.prefChanged("auto_mark_read", checked ? 1 : 0)
                    }
                    PlasmaComponents3.CheckBox {
                        text: i18n("Open articles in the system browser instead of the reader")
                        checked: sheet.pref("open_external", 0) === 1
                        onClicked: sheet.prefChanged("open_external", checked ? 1 : 0)
                    }

                    Rectangle {
                        Layout.fillWidth: true
                        implicitHeight: 1
                        color: Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g,
                                       Kirigami.Theme.textColor.b, 0.12)
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Kirigami.Units.smallSpacing
                        Text {
                            text: i18n("Refresh every")
                            color: Kirigami.Theme.textColor
                            font.pixelSize: Math.round(Kirigami.Units.gridUnit * 0.78)
                        }
                        SpinBox {
                            from: 0
                            to: 720
                            stepSize: 5
                            editable: true
                            value: sheet.pref("refresh_minutes", 30)
                            onValueModified: sheet.prefChanged("refresh_minutes", value)
                        }
                        Text {
                            text: i18n("minutes (0 = manual)")
                            color: Kirigami.Theme.disabledTextColor
                            font.pixelSize: Math.round(Kirigami.Units.gridUnit * 0.72)
                        }
                        Item { Layout.fillWidth: true }
                        PlasmaComponents3.Button {
                            text: i18n("Refresh now")
                            icon.name: "view-refresh"
                            onClicked: sheet.refreshNowRequested()
                        }
                    }

                    Rectangle {
                        Layout.fillWidth: true
                        implicitHeight: 1
                        color: Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g,
                                       Kirigami.Theme.textColor.b, 0.12)
                    }

                    Text {
                        Layout.fillWidth: true
                        text: i18n("Feeds (%1)", sheet.feeds.length)
                        color: Kirigami.Theme.textColor
                        font.bold: true
                        font.pixelSize: Math.round(Kirigami.Units.gridUnit * 0.85)
                    }

                    Repeater {
                        model: sheet.feeds
                        delegate: RowLayout {
                            Layout.fillWidth: true
                            spacing: Kirigami.Units.smallSpacing
                            Text {
                                Layout.fillWidth: true
                                text: (modelData.folder ? modelData.folder + " / " : "")
                                      + (modelData.title || modelData.url)
                                color: modelData.last_error ? Kirigami.Theme.negativeTextColor
                                                            : Kirigami.Theme.textColor
                                font.pixelSize: Math.round(Kirigami.Units.gridUnit * 0.74)
                                elide: Text.ElideRight
                            }
                            PlasmaComponents3.ToolButton {
                                icon.name: "edit-delete"
                                display: AbstractButton.IconOnly
                                onClicked: sheet.deleteFeedRequested(modelData.id)
                                PlasmaComponents3.ToolTip { text: i18n("Remove feed") }
                            }
                        }
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Kirigami.Units.smallSpacing
                        PlasmaComponents3.Button {
                            text: i18n("Export OPML")
                            icon.name: "document-export"
                            onClicked: Qt.openUrlExternally("http://127.0.0.1:" + sheet.port + "/api/opml")
                        }
                        Item { Layout.fillWidth: true }
                    }

                    PlasmaComponents3.TextArea {
                        id: opmlArea
                        Layout.fillWidth: true
                        implicitHeight: Kirigami.Units.gridUnit * 4
                        placeholderText: i18n("Paste OPML here to import feeds")
                        wrapMode: TextEdit.Wrap
                        background: Rectangle {
                            color: Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g,
                                           Kirigami.Theme.textColor.b, 0.06)
                            border.width: 1
                            border.color: Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g,
                                                  Kirigami.Theme.textColor.b, 0.2)
                            radius: Kirigami.Units.smallSpacing / 2
                        }
                    }
                    PlasmaComponents3.Button {
                        text: i18n("Import OPML")
                        icon.name: "document-import"
                        enabled: opmlArea.text.length > 0
                        onClicked: sheet.importOpml(opmlArea.text)
                    }

                    Item { Layout.fillHeight: true; implicitHeight: Kirigami.Units.gridUnit }
                }
            }
        }
    }
}
