import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import org.kde.kirigami as Kirigami
import org.kde.plasma.components as PlasmaComponents3
import "Api.js" as Api

Item {
    id: listRoot

    property var items: []
    property int total: 0
    property int currentItemId: 0
    property string view: "unread"
    property bool loading: false
    property bool refreshRunning: false
    property string searchText: ""
    property bool backendUp: true
    property string statusMessage: ""
    property var iconFor: null

    function feedIcon(feedId) {
        return iconFor ? (iconFor(feedId) || "") : ""
    }
    property string selectionTitle: ""
    property string thumbBase: ""
    property bool sidebarVisible: true
    property int selectedFeedId: 0
    property string selectedFolder: ""
    property var feeds: []
    property var folders: []

    signal itemActivated(int id)
    signal starToggled(int id, bool starred)
    signal viewRequested(string view)
    signal searchChanged(string text)
    signal refreshRequested()
    signal markAllRequested()
    signal addFeedRequested()
    signal settingsRequested()
    signal sidebarToggled()
    signal sourceSelected(string kind, string value)
    signal loadMoreRequested()

    Rectangle {
        anchors.fill: parent
        color: Kirigami.Theme.backgroundColor
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        ColumnLayout {
            Layout.fillWidth: true
            Layout.margins: Kirigami.Units.smallSpacing
            spacing: Kirigami.Units.smallSpacing / 2

            RowLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing / 2

                PlasmaComponents3.ToolButton {
                    icon.name: listRoot.sidebarVisible ? "view-split-left-right" : "application-menu"
                    display: AbstractButton.IconOnly
                    onClicked: listRoot.sidebarToggled()
                    PlasmaComponents3.ToolTip {
                        text: listRoot.sidebarVisible ? i18n("Hide feeds") : i18n("Show feeds")
                    }
                }

                // The current scope doubles as the filter control, so the way to change what the
                // list shows is visible instead of hidden behind an unlabelled icon.
                PlasmaComponents3.ToolButton {
                    id: sourceButton
                    Layout.fillWidth: true
                    text: listRoot.selectionTitle
                    icon.name: "view-list-details"
                    display: AbstractButton.TextBesideIcon
                    onClicked: sourceMenu.popup()
                    PlasmaComponents3.ToolTip { text: i18n("Filter by folder or source") }

                    PlasmaComponents3.Menu {
                        id: sourceMenu
                        y: sourceButton.height

                        PlasmaComponents3.MenuItem {
                            text: i18n("Unread")
                            icon.name: listRoot.view === "unread" && listRoot.selectedFeedId === 0
                                       && listRoot.selectedFolder === "" ? "checkmark" : ""
                            onTriggered: listRoot.sourceSelected("view", "unread")
                        }
                        PlasmaComponents3.MenuItem {
                            text: i18n("Starred")
                            icon.name: listRoot.view === "starred" ? "checkmark" : ""
                            onTriggered: listRoot.sourceSelected("view", "starred")
                        }
                        PlasmaComponents3.MenuItem {
                            text: i18n("All items")
                            icon.name: listRoot.view === "all" && listRoot.selectedFeedId === 0
                                       && listRoot.selectedFolder === "" ? "checkmark" : ""
                            onTriggered: listRoot.sourceSelected("view", "all")
                        }

                        PlasmaComponents3.MenuSeparator {
                            visible: listRoot.folders.length > 0
                        }
                        Repeater {
                            model: listRoot.folders
                            delegate: PlasmaComponents3.MenuItem {
                                required property var modelData
                                text: i18n("Folder: %1", String(modelData))
                                icon.name: listRoot.selectedFolder === String(modelData)
                                           ? "checkmark" : ""
                                onTriggered: listRoot.sourceSelected("folder", String(modelData))
                            }
                        }

                        PlasmaComponents3.MenuSeparator {
                            visible: listRoot.feeds.length > 0
                        }
                        Repeater {
                            model: listRoot.feeds
                            delegate: PlasmaComponents3.MenuItem {
                                required property var modelData
                                text: modelData.title || modelData.url
                                icon.name: listRoot.selectedFeedId === modelData.id
                                           ? "checkmark" : ""
                                onTriggered: listRoot.sourceSelected("feed", String(modelData.id))
                            }
                        }
                    }
                }

                Text {
                    visible: listRoot.total > 0
                    text: listRoot.total
                    color: Kirigami.Theme.disabledTextColor
                    font.pixelSize: Math.round(Kirigami.Units.gridUnit * 0.75)
                }

                PlasmaComponents3.ToolButton {
                    icon.name: "mail-mark-read"
                    display: AbstractButton.IconOnly
                    onClicked: listRoot.markAllRequested()
                    PlasmaComponents3.ToolTip { text: i18n("Mark everything here read…") }
                }
                PlasmaComponents3.ToolButton {
                    icon.name: listRoot.refreshRunning ? "view-refresh" : "view-refresh"
                    display: AbstractButton.IconOnly
                    enabled: !listRoot.refreshRunning
                    onClicked: listRoot.refreshRequested()
                    PlasmaComponents3.ToolTip { text: listRoot.refreshRunning ? i18n("Refreshing…") : i18n("Refresh feeds") }
                    PlasmaComponents3.BusyIndicator {
                        anchors.centerIn: parent
                        visible: listRoot.refreshRunning
                        running: listRoot.refreshRunning
                        implicitWidth: parent.width * 0.7
                        implicitHeight: parent.height * 0.7
                    }
                }
                PlasmaComponents3.ToolButton {
                    icon.name: "list-add"
                    display: AbstractButton.IconOnly
                    onClicked: listRoot.addFeedRequested()
                    PlasmaComponents3.ToolTip { text: i18n("Add feed") }
                }
                PlasmaComponents3.ToolButton {
                    icon.name: "settings-configure"
                    display: AbstractButton.IconOnly
                    onClicked: listRoot.settingsRequested()
                    PlasmaComponents3.ToolTip { text: i18n("Settings") }
                }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing / 2

                Repeater {
                    model: [{ "key": "unread", "label": i18n("Unread") },
                            { "key": "starred", "label": i18n("Starred") },
                            { "key": "all", "label": i18n("All") }]
                    delegate: Rectangle {
                        required property var modelData
                        implicitWidth: chipLabel.implicitWidth + Kirigami.Units.gridUnit * 0.7
                        implicitHeight: Math.round(Kirigami.Units.gridUnit * 1.25)
                        radius: implicitHeight / 2
                        readonly property bool active: listRoot.view === modelData.key
                        color: active ? Kirigami.Theme.highlightColor
                                      : Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g,
                                                Kirigami.Theme.textColor.b, 0.1)
                        Text {
                            id: chipLabel
                            anchors.centerIn: parent
                            text: modelData.label
                            color: parent.active ? Kirigami.Theme.highlightedTextColor : Kirigami.Theme.textColor
                            font.pixelSize: Math.round(Kirigami.Units.gridUnit * 0.7)
                        }
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: listRoot.viewRequested(modelData.key)
                        }
                    }
                }

                Item { Layout.fillWidth: true }

                PlasmaComponents3.TextField {
                    id: searchField
                    Layout.fillWidth: true
                    Layout.maximumWidth: Kirigami.Units.gridUnit * 12
                    placeholderText: i18n("Search…")
                    text: listRoot.searchText
                    font.pixelSize: Math.round(Kirigami.Units.gridUnit * 0.75)
                    onTextChanged: listRoot.searchChanged(text)
                }
            }
        }

        Rectangle {
            Layout.fillWidth: true
            implicitHeight: 1
            color: Kirigami.Theme.textColor
            opacity: 0.12
        }

        Item {
            Layout.fillWidth: true
            Layout.fillHeight: true

            ListView {
                id: itemView
                anchors.fill: parent
                clip: true
                model: listRoot.items
                spacing: 1
                boundsBehavior: Flickable.StopAtBounds
                cacheBuffer: 4000
                ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

                onContentYChanged: {
                    if (contentY + height > contentHeight - Kirigami.Units.gridUnit * 8)
                        listRoot.loadMoreRequested()
                }

                delegate: Item {
                    id: card
                    required property var modelData
                    required property int index
                    width: itemView.width
                    height: cardLayout.implicitHeight + Kirigami.Units.smallSpacing * 2
                    readonly property bool current: modelData.id === listRoot.currentItemId
                    readonly property bool unread: modelData.read === 0
                    readonly property string favicon: listRoot.feedIcon(modelData.feed_id)

                    Rectangle {
                        anchors.fill: parent
                        anchors.margins: 1
                        radius: Kirigami.Units.smallSpacing / 2
                        color: card.current
                               ? Qt.rgba(Kirigami.Theme.highlightColor.r,
                                         Kirigami.Theme.highlightColor.g,
                                         Kirigami.Theme.highlightColor.b, 0.18)
                               : (cardArea.containsMouse
                                  ? Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g,
                                            Kirigami.Theme.textColor.b, 0.07)
                                  : "transparent")
                    }

                    RowLayout {
                        id: cardLayout
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: parent.top
                        anchors.margins: Kirigami.Units.smallSpacing
                        spacing: Kirigami.Units.smallSpacing

                        Rectangle {
                            Layout.alignment: Qt.AlignTop
                            Layout.topMargin: Kirigami.Units.smallSpacing * 1.4
                            implicitWidth: Math.round(Kirigami.Units.gridUnit * 0.42)
                            implicitHeight: implicitWidth
                            radius: implicitWidth / 2
                            color: Kirigami.Theme.highlightColor
                            opacity: card.unread ? 1 : 0
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: Math.round(Kirigami.Units.smallSpacing / 3)

                            Text {
                                Layout.fillWidth: true
                                text: card.modelData.title
                                color: card.unread ? Kirigami.Theme.textColor
                                                   : Kirigami.Theme.disabledTextColor
                                font.bold: card.unread
                                font.pixelSize: Math.round(Kirigami.Units.gridUnit * 0.82)
                                wrapMode: Text.WordWrap
                                maximumLineCount: 2
                                elide: Text.ElideRight
                            }

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: Math.round(Kirigami.Units.smallSpacing * 0.6)

                                Image {
                                    visible: status === Image.Ready
                                    source: card.favicon
                                    sourceSize.width: Math.round(Kirigami.Units.gridUnit * 0.8)
                                    sourceSize.height: Math.round(Kirigami.Units.gridUnit * 0.8)
                                    Layout.preferredWidth: Math.round(Kirigami.Units.gridUnit * 0.8)
                                    Layout.preferredHeight: Math.round(Kirigami.Units.gridUnit * 0.8)
                                    fillMode: Image.PreserveAspectFit
                                    smooth: true
                                }

                                Text {
                                    Layout.fillWidth: true
                                    text: {
                                        var parts = [card.modelData.feed_title]
                                        if (card.modelData.author)
                                            parts.push(card.modelData.author)
                                        parts.push(Api.relativeTime(card.modelData.published))
                                        return parts.filter(function (p) { return !!p }).join(" · ")
                                    }
                                    color: Kirigami.Theme.disabledTextColor
                                    font.pixelSize: Math.round(Kirigami.Units.gridUnit * 0.66)
                                    elide: Text.ElideRight
                                }
                            }

                            Text {
                                Layout.fillWidth: true
                                visible: text.length > 0 && card.width > Kirigami.Units.gridUnit * 20
                                text: card.modelData.summary || ""
                                color: Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g,
                                               Kirigami.Theme.textColor.b, 0.7)
                                font.pixelSize: Math.round(Kirigami.Units.gridUnit * 0.72)
                                wrapMode: Text.WordWrap
                                maximumLineCount: 2
                                elide: Text.ElideRight
                            }
                        }

                        Rectangle {
                            visible: card.modelData.thumb === true
                            Layout.alignment: Qt.AlignTop
                            implicitWidth: Kirigami.Units.iconSizes.large
                            implicitHeight: Kirigami.Units.iconSizes.large
                            radius: Kirigami.Units.smallSpacing / 2
                            color: Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g,
                                           Kirigami.Theme.textColor.b, 0.08)
                            clip: true
                            Image {
                                anchors.fill: parent
                                asynchronous: true
                                cache: true
                                fillMode: Image.PreserveAspectCrop
                                source: card.modelData.thumb === true
                                        ? listRoot.thumbBase + card.modelData.id : ""
                            }
                        }

                        ColumnLayout {
                            Layout.alignment: Qt.AlignTop
                            spacing: 0
                            PlasmaComponents3.ToolButton {
                                icon.name: card.modelData.starred === 1 ? "rating" : "rating-unrated"
                                display: AbstractButton.IconOnly
                                implicitWidth: Kirigami.Units.iconSizes.smallMedium
                                implicitHeight: Kirigami.Units.iconSizes.smallMedium
                                opacity: card.modelData.starred === 1 || cardArea.containsMouse ? 1 : 0
                                onClicked: listRoot.starToggled(card.modelData.id,
                                                                card.modelData.starred === 1)
                                PlasmaComponents3.ToolTip { text: i18n("Toggle star") }
                            }
                            PlasmaComponents3.ToolButton {
                                icon.name: "internet-services"
                                display: AbstractButton.IconOnly
                                implicitWidth: Kirigami.Units.iconSizes.smallMedium
                                implicitHeight: Kirigami.Units.iconSizes.smallMedium
                                opacity: cardArea.containsMouse ? 1 : 0
                                onClicked: Qt.openUrlExternally(card.modelData.url)
                                PlasmaComponents3.ToolTip { text: i18n("Open in browser") }
                            }
                        }
                    }

                    MouseArea {
                        id: cardArea
                        anchors.fill: parent
                        anchors.rightMargin: Kirigami.Units.iconSizes.smallMedium
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: listRoot.itemActivated(card.modelData.id)
                    }
                }
            }

            ColumnLayout {
                anchors.centerIn: parent
                width: parent.width * 0.8
                visible: listRoot.items.length === 0 && !listRoot.loading
                spacing: Kirigami.Units.smallSpacing

                Kirigami.Icon {
                    Layout.alignment: Qt.AlignHCenter
                    source: listRoot.backendUp ? "mail-unread" : "network-disconnect"
                    implicitWidth: Kirigami.Units.iconSizes.huge
                    implicitHeight: Kirigami.Units.iconSizes.huge
                    opacity: 0.4
                    color: Kirigami.Theme.textColor
                }
                Text {
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.Wrap
                    color: Kirigami.Theme.disabledTextColor
                    font.pixelSize: Math.round(Kirigami.Units.gridUnit * 0.78)
                    text: !listRoot.backendUp
                          ? (listRoot.statusMessage || i18n("Waiting for the news backend…"))
                          : listRoot.searchText ? i18n("No matches for “%1”.", listRoot.searchText)
                          : listRoot.view === "starred" ? i18n("Nothing starred yet.")
                          : listRoot.view === "all" ? i18n("No articles yet — press refresh.")
                          : i18n("You are all caught up.")
                }
            }

            PlasmaComponents3.BusyIndicator {
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.bottom: parent.bottom
                anchors.bottomMargin: Kirigami.Units.smallSpacing
                visible: listRoot.loading && listRoot.items.length > 0
                running: visible
                implicitWidth: Kirigami.Units.iconSizes.smallMedium
                implicitHeight: implicitWidth
            }
        }
    }
}
