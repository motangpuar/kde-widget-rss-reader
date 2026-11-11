import QtQuick
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.plasma.plasmoid
import "Api.js" as Api

PlasmoidItem {
    id: root

    readonly property int backendPort: Plasmoid.configuration.port
    readonly property var prefs: serverPrefs
    readonly property bool compactUi: width < Kirigami.Units.gridUnit * 34

    // ------------------------------------------------------------- data state
    property var feeds: []
    property var folders: []
    property string exportDir: ""
    property var counts: ({ "unread": 0, "starred": 0, "all": 0, "feeds": 0 })
    property var serverPrefs: ({
        "reader_theme": "auto", "serif": 0, "font_scale": 100, "line_height": 160,
        "auto_mark_read": 1, "refresh_minutes": 30, "open_external": 0
    })
    property var items: []
    property int totalItems: 0
    property bool loadingItems: false
    property string view: "unread"
    property int selectedFeedId: 0
    property string selectedFolder: ""
    property string searchText: ""
    property var article: null
    property int currentItemId: 0
    property bool readerOpen: false
    property bool backendUp: false
    property string statusMessage: ""
    property string notice: ""
    property bool refreshRunning: false
    property bool showSidebar: true
    property bool addFeedOpen: false
    property bool settingsOpen: false

    // ---------------------------------------------------------- reader palette
    readonly property string readerTheme: prefs.reader_theme || "auto"
    readonly property color readBg: readerTheme === "sepia" ? "#f4ecd8"
                                     : readerTheme === "dark" ? "#16181c"
                                     : readerTheme === "light" ? "#fbfbf9"
                                     : Kirigami.Theme.backgroundColor
    readonly property color readFg: readerTheme === "sepia" ? "#3b3226"
                                     : readerTheme === "dark" ? "#d7dae0"
                                     : readerTheme === "light" ? "#1b1b1b"
                                     : Kirigami.Theme.textColor
    readonly property color readLink: readerTheme === "auto" ? Kirigami.Theme.linkColor : "#3d7dd8"
    readonly property bool serifPref: (prefs.serif | 0) === 1
    readonly property int fontScale: prefs.font_scale || 100
    readonly property real bodyFontSize: Math.round(Kirigami.Units.gridUnit * 0.92 * fontScale / 100)
    readonly property string bodyFamily: serifPref ? "Noto Serif, Georgia, serif" : "Noto Sans, sans-serif"

    // ------------------------------------------------------------------ wiring
    Component.onCompleted: {
        Api.setPort(backendPort)
        loadState()
    }

    onBackendPortChanged: {
        Api.setPort(backendPort)
        loadState()
    }

    Timer {
        id: noticeTimer
        interval: 9000
        onTriggered: root.notice = ""
    }

    Timer {
        id: syncTimer
        interval: 60000
        repeat: true
        running: true
        onTriggered: root.loadState(false)
    }

    Timer {
        id: refreshPollTimer
        interval: 1200
        repeat: true
        running: root.refreshRunning
        onTriggered: root.pollRefresh()
    }

    Timer {
        id: searchTimer
        interval: 350
        onTriggered: root.loadItems(true)
    }

    // ------------------------------------------------------------------- state
    function fail(status) {
        backendUp = false
        statusMessage = status === 0
            ? i18n("Backend offline — start the knewsd background service.")
            : i18n("Backend error (HTTP %1).", status)
    }

    function loadState(reloadItems) {
        Api.request("GET", "/api/state", null, function (status, data) {
            if (status === 200 && data) {
                backendUp = true
                statusMessage = ""
                feeds = data.feeds || []
                folders = data.folders || []
                counts = data.counts || root.counts
                exportDir = data.export_dir || root.exportDir
                serverPrefs = data.prefs || root.serverPrefs
                refreshRunning = !!(data.refresh && data.refresh.running)
                if (reloadItems !== false)
                    loadItems(true)
            } else {
                fail(status)
            }
        })
    }

    function loadItems(reset) {
        if (reset !== false) {
            loadingItems = true
            items = []
            totalItems = 0
        } else {
            if (loadingItems || items.length >= totalItems)
                return
            loadingItems = true
        }
        var path = "/api/items?limit=60&view=" + Api.encode(view)
        if (reset === false)
            path += "&offset=" + items.length
        if (selectedFeedId > 0)
            path += "&feed=" + selectedFeedId
        else if (selectedFolder)
            path += "&folder=" + Api.encode(selectedFolder)
        if (searchText)
            path += "&q=" + Api.encode(searchText)
        Api.request("GET", path, null, function (status, data) {
            loadingItems = false
            if (status !== 200 || !data) {
                fail(status)
                return
            }
            backendUp = true
            totalItems = data.total || 0
            items = reset === false ? items.concat(data.items || []) : (data.items || [])
        })
    }

    function loadMore() {
        loadItems(false)
    }

    function selectSmart(name) {
        view = name
        selectedFeedId = 0
        selectedFolder = ""
        readerOpen = false
        loadItems(true)
    }

    function selectFeed(id) {
        selectedFeedId = id
        selectedFolder = ""
        view = "unread"
        readerOpen = false
        loadItems(true)
    }

    function selectFolder(folder) {
        selectedFolder = folder
        selectedFeedId = 0
        view = "unread"
        readerOpen = false
        loadItems(true)
    }

    function openItem(id) {
        currentItemId = id
        if ((prefs.open_external | 0) === 1) {
            var row = itemById(id)
            if (row && row.url)
                Qt.openUrlExternally(row.url)
            return
        }
        readerOpen = true
        article = null
        var readParam = (prefs.auto_mark_read | 0) === 1 ? "&read=1" : ""
        Api.request("GET", "/api/item?id=" + id + readParam, null, function (status, data) {
            if (status !== 200 || !data) {
                fail(status)
                return
            }
            backendUp = true
            article = data
            if ((prefs.auto_mark_read | 0) === 1) {
                markLocalRead(id)
                refreshCounts()
            }
        })
    }

    function itemById(id) {
        for (var i = 0; i < items.length; ++i) {
            if (items[i].id === id)
                return items[i]
        }
        return null
    }

    function markLocalRead(id) {
        var copy = items.slice()
        for (var i = 0; i < copy.length; ++i) {
            if (copy[i].id === id)
                copy[i].read = 1
        }
        items = copy
    }

    function refreshCounts() {
        Api.request("GET", "/api/state", null, function (status, data) {
            if (status === 200 && data) {
                counts = data.counts || counts
                feeds = data.feeds || feeds
                refreshRunning = !!(data.refresh && data.refresh.running)
            }
        })
    }

    function toggleStar(id, starred) {
        Api.request("POST", "/api/item", { "id": id, "starred": !starred }, function (status, data) {
            if (status !== 200)
                return
            var copy = items.slice()
            for (var i = 0; i < copy.length; ++i) {
                if (copy[i].id === id)
                    copy[i].starred = starred ? 0 : 1
            }
            items = copy
            if (article && article.id === id)
                article.starred = starred ? 0 : 1
            refreshCounts()
        })
    }

    function setRead(id, read) {
        Api.request("POST", "/api/item", { "id": id, "read": read }, function (status) {
            if (status === 200) {
                loadItems(true)
                refreshCounts()
            }
        })
    }

    function markAllRead() {
        var body = selectedFeedId > 0 ? { "feed": selectedFeedId }
                 : selectedFolder ? { "folder": selectedFolder } : {}
        Api.request("POST", "/api/mark-all", body, function (status, data) {
            if (status === 200) {
                loadItems(true)
                refreshCounts()
            }
        })
    }

    function startRefresh() {
        Api.request("POST", "/api/refresh", selectedFeedId > 0 ? { "feed": selectedFeedId } : {},
                    function (status, data) {
            if (status === 200 && data) {
                refreshRunning = !!(data.status && data.status.running)
                backendUp = true
            } else {
                fail(status)
            }
        })
    }

    function pollRefresh() {
        Api.request("GET", "/api/refresh/status", null, function (status, data) {
            if (status !== 200 || !data)
                return
            refreshRunning = !!data.running
            if (!data.running) {
                loadState(true)
                if (article)
                    loadItems(true)
            }
        })
    }

    function reextractCurrent() {
        if (!currentItemId)
            return
        article = null
        Api.request("POST", "/api/extract", { "id": currentItemId }, function (status, data) {
            if (status === 200 && data) {
                article = data
                loadItems(true)
            } else {
                fail(status)
            }
        })
    }

    function setPref(key, value) {
        var patch = {}
        patch[key] = value
        var merged = {}
        for (var k in prefs)
            merged[k] = prefs[k]
        for (var j in patch)
            merged[j] = patch[j]
        serverPrefs = merged
        Api.request("POST", "/api/prefs", { "prefs": patch }, function (status, data) {
            if (status === 200 && data)
                serverPrefs = data.prefs
        })
    }

    function addFeed(url, folder) {
        if (!url)
            return
        addFeedOpen = false
        statusMessage = i18n("Adding %1…", url)
        Api.request("POST", "/api/feeds", { "url": url, "folder": folder }, function (status, data) {
            if (status === 200 && data) {
                statusMessage = ""
                loadState(true)
            } else {
                statusMessage = (data && data.error) ? data.error : i18n("Could not add feed.")
                addFeedOpen = true
            }
        })
    }

    function deleteFeed(id) {
        var title = ""
        for (var i = 0; i < feeds.length; ++i) {
            if (feeds[i].id === id)
                title = feeds[i].title || feeds[i].url
        }
        Api.request("POST", "/api/feeds/delete", { "id": id }, function (status, data) {
            if (status !== 200) {
                root.showNotice(i18n("Could not remove %1", title))
                return
            }
            if (root.selectedFeedId === id) {
                root.selectedFeedId = 0
                root.currentItemId = 0
                root.readerOpen = false
                root.loadItems(true)
            }
            root.loadState(false)
            root.showNotice(i18n("Removed %1", title))
        })
    }

    function feedIcon(feedId) {
        for (var i = 0; i < feeds.length; ++i) {
            if (feeds[i].id === feedId)
                return feeds[i].icon || ""
        }
        return ""
    }

    function showNotice(text) {
        notice = text || ""
        if (notice.length > 0)
            noticeTimer.restart()
    }

    function importOpml(text) {
        settingsOpen = false
        Api.request("POST", "/api/opml", { "opml": text }, function (status, data) {
            if (status !== 200 || !data) {
                showNotice(i18n("OPML import failed. Check the file and try again."))
                return
            }
            var entries = data.imported || []
            var ok = 0
            var failures = []
            for (var i = 0; i < entries.length; i++) {
                if (entries[i].error)
                    failures.push(entries[i].url)
                else
                    ok++
            }
            if (failures.length === 0) {
                showNotice(i18n("Imported %1 feeds.", ok))
            } else {
                showNotice(i18np("Imported %1 feed. Failed: ", "Imported %1 feeds. Failed: ", ok)
                           .arg(ok) + failures.slice(0, 3).join(", ")
                           + (failures.length > 3 ? i18n(" and %1 more", failures.length - 3) : ""))
            }
            loadState(true)
        })
    }

    function selectedTitle() {
        if (selectedFeedId > 0) {
            for (var i = 0; i < feeds.length; ++i) {
                if (feeds[i].id === selectedFeedId)
                    return feeds[i].title
            }
        }
        if (selectedFolder)
            return selectedFolder
        return view === "starred" ? i18n("Starred") : view === "all" ? i18n("All items") : i18n("Unread")
    }

    // ------------------------------------------------------------- presentation
    toolTipMainText: i18n("News Curator")
    toolTipSubText: backendUp ? i18np("%1 unread item", "%1 unread items", counts.unread)
                              : i18n("Backend offline")

    compactRepresentation: MouseArea {
        id: compactArea
        implicitWidth: Kirigami.Units.iconSizes.smallMedium
        implicitHeight: Kirigami.Units.iconSizes.smallMedium
        onClicked: root.expanded = !root.expanded

        Kirigami.Icon {
            anchors.fill: parent
            source: "newscurator"
            active: compactArea.containsMouse
        }
        Rectangle {
            visible: root.counts.unread > 0
            anchors.right: parent.right
            anchors.top: parent.top
            width: Math.max(height, badgeLabel.implicitWidth + 4)
            height: Math.round(Kirigami.Units.gridUnit * 0.75)
            radius: height / 2
            color: Kirigami.Theme.highlightColor
            Text {
                id: badgeLabel
                anchors.centerIn: parent
                color: Kirigami.Theme.highlightedTextColor
                font.pixelSize: Math.round(parent.height * 0.7)
                text: root.counts.unread > 99 ? "99+" : root.counts.unread
            }
        }
    }

    fullRepresentation: Item {
        implicitWidth: Kirigami.Units.gridUnit * 62
        implicitHeight: Kirigami.Units.gridUnit * 36
        Layout.minimumWidth: Kirigami.Units.gridUnit * 24
        Layout.minimumHeight: Kirigami.Units.gridUnit * 16

        Rectangle {
            anchors.fill: parent
            color: Kirigami.Theme.backgroundColor
            radius: Kirigami.Units.smallSpacing
        }

        RowLayout {
            anchors.fill: parent
            anchors.margins: 1
            spacing: 0

            FeedSidebar {
                id: sidebar
                Layout.fillHeight: true
                Layout.preferredWidth: Math.min(Kirigami.Units.gridUnit * 14, root.width * 0.3)
                Layout.minimumWidth: Kirigami.Units.gridUnit * 10
                visible: !root.compactUi && (root.showSidebar || root.width > Kirigami.Units.gridUnit * 46)
                feeds: root.feeds
                folders: root.folders
                counts: root.counts
                selectedFeedId: root.selectedFeedId
                selectedFolder: root.selectedFolder
                smartView: root.view
                onSmartSelected: (name) => root.selectSmart(name)
                onFeedSelected: (id) => root.selectFeed(id)
                onFolderSelected: (folder) => root.selectFolder(folder)
                onAddFeedRequested: root.addFeedOpen = true
                onSettingsRequested: root.settingsOpen = true
                onDeleteFeedRequested: (id) => root.deleteFeed(id)
            }

            Rectangle {
                Layout.fillHeight: true
                Layout.preferredWidth: 1
                color: Kirigami.Theme.textColor
                opacity: 0.12
                visible: sidebar.visible
            }

            ArticleList {
                id: list
                Layout.fillHeight: true
                Layout.fillWidth: !root.readerOpen || !root.compactUi
                Layout.preferredWidth: Kirigami.Units.gridUnit * 20
                Layout.minimumWidth: Kirigami.Units.gridUnit * 14
                visible: !root.compactUi || !root.readerOpen
                items: root.items
                total: root.totalItems
                currentItemId: root.currentItemId
                view: root.view
                loading: root.loadingItems
                refreshRunning: root.refreshRunning
                searchText: root.searchText
                backendUp: root.backendUp
                statusMessage: root.statusMessage
                selectionTitle: root.selectedTitle()
                thumbBase: "http://127.0.0.1:" + root.backendPort + "/api/thumb?id="
                iconFor: (feedId) => root.feedIcon(feedId)
                sidebarVisible: sidebar.visible
                onItemActivated: (id) => root.openItem(id)
                onStarToggled: (id, starred) => root.toggleStar(id, starred)
                onViewRequested: (name) => { root.view = name; root.loadItems(true) }
                onSearchChanged: (text) => { root.searchText = text; searchTimer.restart() }
                onRefreshRequested: root.startRefresh()
                onMarkAllRequested: root.markAllRead()
                onAddFeedRequested: root.addFeedOpen = true
                onSettingsRequested: root.settingsOpen = true
                onSidebarToggled: root.showSidebar = !root.showSidebar
                onLoadMoreRequested: root.loadMore()
            }

            Rectangle {
                Layout.fillHeight: true
                Layout.preferredWidth: 1
                color: Kirigami.Theme.textColor
                opacity: 0.12
                visible: root.readerOpen && !root.compactUi
            }

            ReaderView {
                id: reader
                Layout.fillHeight: true
                Layout.fillWidth: true
                visible: root.readerOpen
                article: root.article
                lastItemId: root.currentItemId
                readBg: root.readBg
                readFg: root.readFg
                readLink: root.readLink
                bodyFamily: root.bodyFamily
                bodyFontSize: root.bodyFontSize
                lineHeightPercent: root.prefs.line_height || 160
                themeName: root.readerTheme
                compactMode: root.compactUi
                feedTitle: root.article ? (root.article.feed_title || "") : ""
                onClosed: root.readerOpen = false
                onStarToggled: (id, starred) => root.toggleStar(id, starred)
                onOpenExternal: (url) => Qt.openUrlExternally(url)
                onReextractRequested: root.reextractCurrent()
                onFontScaleChanged: (delta) => root.setPref("font_scale",
                    Math.max(80, Math.min(170, root.fontScale + delta)))
                onThemeCycled: {
                    var order = ["auto", "light", "sepia", "dark"]
                    var idx = order.indexOf(root.readerTheme)
                    root.setPref("reader_theme", order[(idx + 1) % order.length])
                }
            }
        }

        AddFeedSheet {
            anchors.fill: parent
            visible: root.addFeedOpen
            folders: root.folders
            onAccepted: (url, folder) => root.addFeed(url, folder)
            onCancelled: root.addFeedOpen = false
        }

        SettingsSheet {
            anchors.fill: parent
            visible: root.settingsOpen
            prefs: root.prefs
            feeds: root.feeds
            backendUp: root.backendUp
            exportDir: root.exportDir
            onClosed: root.settingsOpen = false
            onPrefChanged: (key, value) => root.setPref(key, value)
            onRefreshNowRequested: root.startRefresh()
            onImportOpml: (text) => root.importOpml(text)
            onDeleteFeedRequested: (id) => root.deleteFeed(id)
            onFeedsAdded: (added, failed) => {
                root.settingsOpen = false
                root.loadState(true)
                if (failed === 0)
                    root.showNotice(added === 1 ? i18n("Added 1 feed")
                                                : i18n("Added %1 feeds", added))
                else
                    root.showNotice(i18n("Added %1, %2 failed", added, failed))
            }
        }

        Rectangle {
            id: noticeBar
            anchors.top: parent.top
            anchors.right: parent.right
            anchors.margins: Kirigami.Units.smallSpacing
            width: Math.min(parent.width - 2 * Kirigami.Units.smallSpacing,
                            noticeText.implicitWidth + Kirigami.Units.gridUnit * 2.5)
            height: noticeText.implicitHeight + Kirigami.Units.smallSpacing * 2
            radius: Kirigami.Units.smallSpacing
            color: Kirigami.Theme.backgroundColor
            border.width: 1
            border.color: Kirigami.Theme.textColor
            opacity: root.notice.length > 0 ? 0.97 : 0
            visible: opacity > 0

            Behavior on opacity { NumberAnimation { duration: 120 } }

            Text {
                id: noticeText
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Kirigami.Units.smallSpacing * 2
                anchors.rightMargin: Kirigami.Units.smallSpacing * 2
                text: root.notice
                color: Kirigami.Theme.textColor
                wrapMode: Text.Wrap
                maximumLineCount: 4
                elide: Text.ElideRight
                font.pixelSize: Math.round(Kirigami.Units.gridUnit * 0.75)
            }
        }
    }
}
