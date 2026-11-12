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
    // Article rows grow with the reader-independent text size preference; the whole widget scales
    // off one multiplier so the title, the meta line and the summary keep their relative weights.
    property real textScale: 1.0

    function feedIcon(feedId) {
        return iconFor ? (iconFor(feedId) || "") : ""
    }

    // ------------------------------------------------------------- scope helpers
    function isFeedScope() {
        return selectedFeedId > 0
    }

    // The button carries the icon of whatever is being listed, so the current source is readable
    // without opening the menu.
    function scopeIconName() {
        if (isFeedScope())
            return ""
        if (selectedFolder.length > 0)
            return "folder"
        if (view === "starred")
            return "rating"
        if (view === "all")
            return "view-list-details"
        return "mail-unread"
    }

    function scopeIconSource() {
        if (!isFeedScope())
            return ""
        var uri = feedIcon(selectedFeedId)
        return uri.length > 0 ? uri : ""
    }

    function scopeFallbackIconName() {
        return isFeedScope() && feedIcon(selectedFeedId).length === 0 ? "application-rss+xml" : ""
    }

    function folderFeeds(name) {
        var out = []
        for (var i = 0; i < feeds.length; ++i) {
            if (String(feeds[i].folder || "") === name)
                out.push(feeds[i])
        }
        return out
    }

    function looseFeedList() {
        return folderFeeds("")
    }

    function feedUnread(feed) {
        return typeof feed.unread === "number" ? feed.unread : 0
    }

    function folderUnread(name) {
        var list = folderFeeds(name)
        var sum = 0
        for (var i = 0; i < list.length; ++i)
            sum += feedUnread(list[i])
        return sum
    }

    function isSmartSelected(kind) {
        return selectedFeedId === 0 && selectedFolder.length === 0 && view === kind
    }

    // The source menu is rebuilt from scratch on every open: a Repeater delegate must be an Item
    // and a submenu is a Popup, so the rows are created in JS. A fresh menu also keeps the bold
    // state truthful without a long-lived binding. The menu itself is JS-owned, which is what makes
    // destroying it (together with the rows Qt generates for submenus) possible.
    property var scopeMenu: null

    function newMenuObject(source, parent) {
        return Qt.createQmlObject("import QtQuick; import org.kde.plasma.components as PC3; "
                                  + source, parent)
    }

    function addSourceRow(menu, text, iconName, iconSource, bold, kind, value) {
        var row = newMenuObject("PC3.MenuItem { }", menu)
        row.text = text
        row.icon.name = iconName
        row.icon.source = iconSource
        row.font.bold = bold
        row.triggered.connect(function () { listRoot.sourceSelected(kind, value) })
        menu.addItem(row)
    }

    function addSourceSeparator(menu) {
        menu.addItem(newMenuObject("PC3.MenuSeparator { }", menu))
    }

    function addFolderSubmenu(menu, name) {
        var sub = newMenuObject("PC3.Menu { }", menu)
        sub.title = name
        sub.icon.name = "folder"

        var head = newMenuObject("PC3.MenuItem { }", sub)
        head.text = i18n("Everything in %1", name)
        head.icon.name = "folder-open"
        head.triggered.connect(function () { listRoot.sourceSelected("folder", name) })
        sub.addItem(head)

        var list = folderFeeds(name)
        if (list.length > 0)
            sub.addItem(newMenuObject("PC3.MenuSeparator { }", sub))
        for (var i = 0; i < list.length; ++i) {
            var feed = list[i]
            var uri = feedIcon(feed.id)
            var row = newMenuObject("PC3.MenuItem { }", sub)
            row.text = feed.title || feed.url
            row.icon.name = uri.length > 0 ? "" : "application-rss+xml"
            row.icon.source = uri
            row.font.bold = selectedFeedId === feed.id
            row.triggered.connect((function (id) {
                return function () { listRoot.sourceSelected("feed", String(id)) }
            })(feed.id))
            sub.addItem(row)
        }

        // addMenu() wraps the Menu in a generated row that carries the title and icon.
        menu.addMenu(sub)
    }

    function openSources() {
        if (scopeMenu) {
            scopeMenu.close()
            scopeMenu.destroy()
            scopeMenu = null
        }
        var menu = newMenuObject("PC3.Menu { }", listRoot)
        addSourceRow(menu, i18n("Unread"), "mail-unread", "", isSmartSelected("unread"),
                     "view", "unread")
        addSourceRow(menu, i18n("Starred"), "rating", "", isSmartSelected("starred"),
                     "view", "starred")
        addSourceRow(menu, i18n("All items"), "view-list-details", "", isSmartSelected("all"),
                     "view", "all")
        if (folders.length > 0)
            addSourceSeparator(menu)
        for (var i = 0; i < folders.length; ++i)
            addFolderSubmenu(menu, String(folders[i]))
        var loose = looseFeedList()
        if (loose.length > 0)
            addSourceSeparator(menu)
        for (var j = 0; j < loose.length; ++j) {
            var feed = loose[j]
            var uri = feedIcon(feed.id)
            addSourceRow(menu, feed.title || feed.url,
                         uri.length > 0 ? "" : "application-rss+xml", uri,
                         selectedFeedId === feed.id, "feed", String(feed.id))
        }
        scopeMenu = menu
        // Left edge under the button: a centred popup is what made the old menu hard to read.
        menu.popup(sourceButton, 0, sourceButton.height)
    }

    property string selectionTitle: ""
    property string thumbBase: ""
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

                // The current scope doubles as the filter control, so the way to change what the
                // list shows is visible instead of hidden behind an unlabelled icon.
                PlasmaComponents3.ToolButton {
                    id: sourceButton
                    objectName: "source-button"
                    Layout.fillWidth: true
                    text: listRoot.selectionTitle
                    icon.name: listRoot.scopeIconName().length > 0
                               ? listRoot.scopeIconName()
                               : listRoot.scopeFallbackIconName()
                    icon.source: listRoot.scopeIconSource()
                    display: AbstractButton.TextBesideIcon
                    onClicked: listRoot.openSources()
                    PlasmaComponents3.ToolTip { text: i18n("Filter by folder or source") }
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
                    height: cardLayout.implicitHeight + Math.round(Kirigami.Units.gridUnit * 0.55)
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
                            spacing: Math.round(Kirigami.Units.gridUnit * 0.2)

                            Text {
                                Layout.fillWidth: true
                                text: card.modelData.title
                                color: card.unread ? Kirigami.Theme.textColor
                                                   : Kirigami.Theme.disabledTextColor
                                font.bold: card.unread
                                font.pixelSize:
                                    Math.round(Kirigami.Units.gridUnit * 0.82 * listRoot.textScale)
                                lineHeight: 1.15
                                lineHeightMode: Text.ProportionalHeight
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
                                    font.pixelSize:
                                        Math.round(Kirigami.Units.gridUnit * 0.66 * listRoot.textScale)
                                    elide: Text.ElideRight
                                }
                            }

                            Text {
                                Layout.fillWidth: true
                                visible: text.length > 0 && card.width > Kirigami.Units.gridUnit * 20
                                text: card.modelData.summary || ""
                                color: Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g,
                                               Kirigami.Theme.textColor.b, 0.7)
                                font.pixelSize:
                                    Math.round(Kirigami.Units.gridUnit * 0.72 * listRoot.textScale)
                                lineHeight: 1.2
                                lineHeightMode: Text.ProportionalHeight
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
