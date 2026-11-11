import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import org.kde.kirigami as Kirigami
import org.kde.plasma.components as PlasmaComponents3

Item {
    id: sidebar

    property var feeds: []
    property var folders: []
    property var counts: ({ "unread": 0, "starred": 0, "all": 0 })
    property int selectedFeedId: 0
    property string selectedFolder: ""
    property string smartView: "unread"

    signal smartSelected(string view)
    signal feedSelected(int id)
    signal folderSelected(string folder)
    signal addFeedRequested()
    signal settingsRequested()
    signal deleteFeedRequested(int id)

    readonly property int rowHeight: Math.round(Kirigami.Units.gridUnit * 1.7)
    readonly property var rows: {
        var out = []
        out.push({ "kind": "smart", "key": "unread", "label": i18n("Unread"),
                   "icon": "mail-unread", "count": counts.unread || 0 })
        out.push({ "kind": "smart", "key": "starred", "label": i18n("Starred"),
                   "icon": "rating", "count": counts.starred || 0 })
        out.push({ "kind": "smart", "key": "all", "label": i18n("All items"),
                   "icon": "view-list-details", "count": counts.all || 0 })
        var grouped = {}
        var loose = []
        for (var i = 0; i < feeds.length; ++i) {
            var feed = feeds[i]
            if (feed.folder) {
                if (!grouped[feed.folder])
                    grouped[feed.folder] = []
                grouped[feed.folder].push(feed)
            } else {
                loose.push(feed)
            }
        }
        var names = folders.slice().sort()
        for (var f = 0; f < names.length; ++f) {
            var name = names[f]
            if (!grouped[name])
                continue
            var total = 0
            for (var k = 0; k < grouped[name].length; ++k)
                total += grouped[name][k].unread || 0
            out.push({ "kind": "folder", "key": name, "label": name, "count": total })
            for (var j = 0; j < grouped[name].length; ++j) {
                out.push({ "kind": "feed", "key": String(grouped[name][j].id),
                           "label": grouped[name][j].title || grouped[name][j].url,
                           "count": grouped[name][j].unread || 0,
                           "error": grouped[name][j].last_error || "",
                           "favicon": grouped[name][j].icon || "",
                           "nested": true })
            }
        }
        for (var l = 0; l < loose.length; ++l) {
            out.push({ "kind": "feed", "key": String(loose[l].id),
                       "label": loose[l].title || loose[l].url,
                       "count": loose[l].unread || 0,
                       "error": loose[l].last_error || "",
                       "favicon": loose[l].icon || "",
                       "nested": false })
        }
        return out
    }

    function isActive(row) {
        if (row.kind === "smart")
            return smartView === row.key && selectedFeedId === 0 && selectedFolder === ""
        if (row.kind === "folder")
            return selectedFolder === row.key && selectedFeedId === 0
        return selectedFeedId === parseInt(row.key)
    }

    Rectangle {
        anchors.fill: parent
        color: Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g,
                       Kirigami.Theme.textColor.b, 0.03)
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: Kirigami.Units.smallSpacing
        spacing: Kirigami.Units.smallSpacing

        RowLayout {
            Layout.fillWidth: true
            spacing: Kirigami.Units.smallSpacing / 2

            Text {
                Layout.fillWidth: true
                text: i18n("News Curator")
                color: Kirigami.Theme.textColor
                font.bold: true
                font.pixelSize: Math.round(Kirigami.Units.gridUnit * 0.85)
                elide: Text.ElideRight
            }

            PlasmaComponents3.ToolButton {
                icon.name: "list-add"
                text: i18n("Add feed")
                display: AbstractButton.IconOnly
                onClicked: sidebar.addFeedRequested()
                PlasmaComponents3.ToolTip { text: i18n("Add feed or import OPML") }
            }
            PlasmaComponents3.ToolButton {
                icon.name: "settings-configure"
                text: i18n("Settings")
                display: AbstractButton.IconOnly
                onClicked: sidebar.settingsRequested()
                PlasmaComponents3.ToolTip { text: i18n("Reader and backend settings") }
            }
        }

        ListView {
            id: rowView
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            model: sidebar.rows
            boundsBehavior: Flickable.StopAtBounds
            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

            delegate: Rectangle {
                id: rowItem
                required property var modelData
                required property int index
                width: rowView.width
                height: rowItemRow.implicitHeight + Kirigami.Units.smallSpacing
                radius: Kirigami.Units.smallSpacing / 2
                readonly property bool active: sidebar.isActive(modelData)
                readonly property bool removable: modelData.kind === "feed"
                property bool confirmDelete: false
                color: active ? Qt.rgba(Kirigami.Theme.highlightColor.r,
                                        Kirigami.Theme.highlightColor.g,
                                        Kirigami.Theme.highlightColor.b, 0.22)
                              : (hoverArea.containsMouse
                                 ? Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g,
                                           Kirigami.Theme.textColor.b, 0.08)
                                 : "transparent")

                RowLayout {
                    id: rowItemRow
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.leftMargin: Kirigami.Units.smallSpacing + (rowItem.modelData.nested ? Kirigami.Units.gridUnit * 0.6 : 0)
                    anchors.rightMargin: Kirigami.Units.smallSpacing
                    spacing: Kirigami.Units.smallSpacing

                    Image {
                        visible: rowItem.modelData.kind === "feed" && rowItem.modelData.favicon
                                 && status === Image.Ready
                        source: rowItem.modelData.favicon || ""
                        sourceSize.width: Kirigami.Units.iconSizes.small
                        sourceSize.height: Kirigami.Units.iconSizes.small
                        Layout.preferredWidth: Kirigami.Units.iconSizes.small
                        Layout.preferredHeight: Kirigami.Units.iconSizes.small
                        fillMode: Image.PreserveAspectFit
                        smooth: true
                    }

                    Kirigami.Icon {
                        visible: rowItem.modelData.kind !== "feed"
                                 || !rowItem.modelData.favicon
                        source: rowItem.modelData.kind === "feed"
                                ? "application-rss+xml"
                                : (rowItem.modelData.icon || "folder")
                        implicitWidth: Kirigami.Units.iconSizes.small
                        implicitHeight: Kirigami.Units.iconSizes.small
                        color: rowItem.active ? Kirigami.Theme.highlightColor : Kirigami.Theme.textColor
                    }

                    Text {
                        Layout.fillWidth: true
                        text: rowItem.modelData.label
                        color: rowItem.modelData.error && rowItem.modelData.kind === "feed"
                               ? Kirigami.Theme.negativeTextColor : Kirigami.Theme.textColor
                        font.bold: rowItem.active || (rowItem.modelData.kind === "folder")
                        font.pixelSize: Math.round(Kirigami.Units.gridUnit * 0.78)
                        elide: Text.ElideRight
                    }

                    Rectangle {
                        visible: (rowItem.modelData.count || 0) > 0
                        implicitWidth: Math.max(Kirigami.Units.gridUnit * 1.1,
                                                countLabel.implicitWidth + Kirigami.Units.smallSpacing)
                        implicitHeight: Math.round(Kirigami.Units.gridUnit * 0.95)
                        radius: implicitHeight / 2
                        color: rowItem.modelData.kind === "smart" && rowItem.modelData.key === "unread"
                               ? Kirigami.Theme.highlightColor
                               : Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g,
                                         Kirigami.Theme.textColor.b, 0.14)
                        Text {
                            id: countLabel
                            anchors.centerIn: parent
                            text: rowItem.modelData.count > 999 ? "999+" : rowItem.modelData.count
                            color: rowItem.modelData.kind === "smart" && rowItem.modelData.key === "unread"
                                   ? Kirigami.Theme.highlightedTextColor : Kirigami.Theme.textColor
                            font.pixelSize: Math.round(Kirigami.Units.gridUnit * 0.66)
                        }
                    }
                }

                MouseArea {
                    id: hoverArea
                    anchors.fill: parent
                    anchors.rightMargin: rowItem.removable
                                       ? Kirigami.Units.iconSizes.small + Kirigami.Units.smallSpacing * 2 : 0
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        if (rowItem.modelData.kind === "smart")
                            sidebar.smartSelected(rowItem.modelData.key)
                        else if (rowItem.modelData.kind === "folder")
                            sidebar.folderSelected(rowItem.modelData.key)
                        else
                            sidebar.feedSelected(parseInt(rowItem.modelData.key))
                    }
                }

                // Unsubscribe: hover reveals the button, the first click arms it for 4 s.
                PlasmaComponents3.ToolButton {
                    id: deleteButton
                    visible: rowItem.removable && (hoverArea.containsMouse || rowItem.confirmDelete)
                    anchors.right: parent.right
                    anchors.rightMargin: Kirigami.Units.smallSpacing
                    anchors.verticalCenter: parent.verticalCenter
                    implicitWidth: Kirigami.Units.iconSizes.small + Kirigami.Units.smallSpacing
                    implicitHeight: Kirigami.Units.iconSizes.small + Kirigami.Units.smallSpacing
                    icon.name: rowItem.confirmDelete ? "dialog-ok-apply" : "edit-delete"
                    display: AbstractButton.IconOnly
                    onClicked: {
                        if (!rowItem.confirmDelete) {
                            rowItem.confirmDelete = true
                            confirmTimer.restart()
                        } else {
                            rowItem.confirmDelete = false
                            sidebar.deleteFeedRequested(parseInt(rowItem.modelData.key))
                        }
                    }
                    PlasmaComponents3.ToolTip {
                        text: rowItem.confirmDelete
                              ? i18n("Click again to unsubscribe from %1", rowItem.modelData.label)
                              : i18n("Unsubscribe from %1", rowItem.modelData.label)
                    }
                    Timer {
                        id: confirmTimer
                        interval: 4000
                        onTriggered: rowItem.confirmDelete = false
                    }
                }
            }
        }

        Text {
            Layout.fillWidth: true
            visible: sidebar.feeds.length === 0
            text: i18n("No feeds yet.\nAdd one with +")
            color: Kirigami.Theme.disabledTextColor
            font.pixelSize: Math.round(Kirigami.Units.gridUnit * 0.72)
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
        }
    }
}
