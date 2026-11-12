import QtQuick
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.plasma.plasmoid
import org.kde.plasma.components as PlasmaComponents3
import "Api.js" as Api

PlasmoidItem {
    id: root

    // Connection settings live in KConfig (contents/config/main.xml), so they survive a
    // plasmashell restart and can be set by any KDE tool, not only by this sheet.
    readonly property int configuredPort: Plasmoid.configuration.port || 8770
    readonly property string connectionMode: {
        var value = Plasmoid.configuration.connection
        return (value === 1 || value === "socket" || value === "Socket") ? "socket" : "port"
    }
    readonly property string configuredSocket: Plasmoid.configuration.socketPath || ""
    // Loopback channel the widget itself talks to; in socket mode the daemon publishes an
    // ephemeral port, which the launcher reports back.
    property int activePort: configuredPort
    readonly property int backendPort: activePort > 0 ? activePort : configuredPort
    readonly property string backendEndpointText: {
        if (connectionMode === "socket") {
            var path = configuredSocket.length > 0 ? configuredSocket
                                                   : "$XDG_RUNTIME_DIR/knews-curator/knewsd.sock"
            return i18n("unix socket %1 — widget channel 127.0.0.1:%2", path, backendPort)
        }
        return i18n("127.0.0.1:%1", backendPort)
    }
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
    // Set while a mark-all sweep can still be undone from the notice banner.
    property var undoMarkAll: null
    property bool refreshRunning: false
    property bool addFeedOpen: false
    property string addFeedFolder: ""
    property bool settingsOpen: false
    property bool confirmMarkAllOpen: false

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
    // Qt resolves one family name; a CSS-style fallback list silently falls back to sans.
    readonly property string chosenFamily: prefs.font_family || ""
    readonly property string bodyFamily: chosenFamily.length > 0
                                         ? chosenFamily
                                         : (serifPref ? "Noto Serif" : "Noto Sans")
    readonly property int readerPadding: prefs.reader_padding || 100

    // ------------------------------------------------------------------ wiring
    Component.onCompleted: {
        Api.setPort(backendPort)
        loadState()
        // A store install has no installer: the widget starts the backend it ships. The script
        // answers /api/health first, so this is a no-op when a daemon already runs.
        backendLauncher.start()
    }

    // The widget is the supervisor: when it goes away, so does the daemon it started.
    // bootstrap.sh refuses to touch a backend it did not start (e.g. the systemd unit), and the
    // daemon also reaps itself after KNEWS_IDLE_EXIT seconds without a request.
    Component.onDestruction: backendLauncher.stop()

    function setBackendConnection(mode, port, socketPath) {
        Plasmoid.configuration.connection = mode === "socket" ? 1 : 0
        if (port > 0)
            Plasmoid.configuration.port = port
        Plasmoid.configuration.socketPath = socketPath || ""
        statusMessage = i18n("Restarting the feed backend…")
        backendLauncher.restart()
    }

    function backendAction(action) {
        if (action === "stop") {
            backendLauncher.stop()
            backendUp = false
            statusMessage = i18n("Backend stopped. It starts again when this widget reloads.")
            return
        }
        statusMessage = i18n("Restarting the feed backend…")
        backendLauncher.restart()
    }

    BackendLauncher {
        id: backendLauncher
        port: root.configuredPort
        connectionMode: root.connectionMode
        socketPath: root.configuredSocket
        onEndpoint: (port, socket, transport) => {
            if (port > 0)
                root.activePort = port
        }
        onFinished: (state) => {
            if (state === "running") {
                statusMessage = i18n("Starting the feed backend…")
                backendRetry.restart()
            } else if (state === "already") {
                backendRetry.restart()
            } else if (state === "no-python") {
                statusMessage = i18n("Python 3 is required for the feed backend. "
                                     + "Install python3, then reopen this widget.")
            } else if (state === "missing") {
                statusMessage = i18n("This package has no bundled backend — "
                                     + "install the full release instead.")
            } else {
                statusMessage = i18n("Could not start the feed backend. "
                                     + "See ~/.cache/knews-curator/knewsd.log")
            }
        }
    }

    // The bootstrap waits for the daemon itself; this timer only re-syncs the UI with it.
    Timer {
        id: backendRetry
        interval: 2500
        repeat: true
        running: false
        onTriggered: {
            if (backendRetry.attempts++ >= 8)
                backendRetry.stop()
            root.loadState()
        }
        property int attempts: 0
        onRunningChanged: if (running) attempts = 0
    }

    onBackendPortChanged: {
        Api.setPort(backendPort)
        loadState()
    }

    Timer {
        id: noticeTimer
        interval: 9000
        onTriggered: { root.notice = ""; root.undoMarkAll = null }
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
            ? i18n("Backend offline — starting it, this takes a moment.")
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
            // `article` is a plain JS object: mutating it in place never re-evaluates the
            // bindings in ReaderView, so publish a fresh copy to repaint the star.
            if (article && article.id === id) {
                var next = {}
                for (var key in article)
                    next[key] = article[key]
                next.starred = starred ? 0 : 1
                article = next
            }
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

    // Snapshot of what the pending confirmation would touch, so the prompt can name it.
    readonly property string scopeLabel: selectedFeedId > 0
                                         ? feedTitle(selectedFeedId)
                                         : selectedFolder ? selectedFolder
                                         : (searchText.length > 0 ? i18n("the current search")
                                                                  : i18n("every feed"))
    readonly property int scopeUnread: (view === "unread" && searchText.length === 0)
                                       ? totalItems : (counts.unread || 0)

    function feedTitle(id) {
        for (var i = 0; i < feeds.length; ++i)
            if (feeds[i].id === id)
                return feeds[i].title || feeds[i].url
        return i18n("this feed")
    }

    function requestMarkAll() {
        if (scopeUnread <= 0) {
            showNotice(i18n("Nothing to mark read"))
            return
        }
        confirmMarkAllOpen = true
    }

    function markAllRead() {
        var body = selectedFeedId > 0 ? { "feed": selectedFeedId }
                 : selectedFolder ? { "folder": selectedFolder } : {}
        confirmMarkAllOpen = false
        Api.request("POST", "/api/mark-all", body, function (status, data) {
            if (status !== 200 || !data) {
                fail(status)
                return
            }
            loadItems(true)
            refreshCounts()
            if (data.changed > 0) {
                undoMarkAll = body
                showNotice(data.changed === 1 ? i18n("Marked 1 item read")
                                              : i18n("Marked %1 items read", data.changed))
            } else {
                undoMarkAll = null
                showNotice(i18n("Nothing left to mark read"))
            }
        })
    }

    function undoMarkAllRead() {
        if (!undoMarkAll)
            return
        Api.request("POST", "/api/mark-unread", undoMarkAll, function (status, data) {
            undoMarkAll = null
            if (status !== 200 || !data) {
                fail(status)
                return
            }
            loadItems(true)
            refreshCounts()
            showNotice(data.changed === 1 ? i18n("Restored 1 unread item")
                                          : i18n("Restored %1 unread items", data.changed))
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

    // Two preferences can belong to one control (family + serif), so allow a batch write.
    function setPrefs(values) {
        var merged = {}
        for (var k in prefs)
            merged[k] = prefs[k]
        for (var k2 in values)
            merged[k2] = values[k2]
        serverPrefs = merged
        Api.request("POST", "/api/prefs", { "prefs": values }, function (status, data) {
            if (status === 200 && data)
                serverPrefs = data.prefs
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

            // One pane at a time: the reader replaces the list at every widget size. A side-by-side
            // split broke down as soon as the widget was resized (both panes fought over the width
            // and the reader ended up a sliver at the edge), and the reader caps its own text width.
            ArticleList {
                id: list
                Layout.fillHeight: true
                Layout.fillWidth: !root.readerOpen
                Layout.minimumWidth: Kirigami.Units.gridUnit * 14
                visible: !root.readerOpen
                textScale: (root.prefs.list_scale || 100) / 100
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
                selectedFeedId: root.selectedFeedId
                selectedFolder: root.selectedFolder
                feeds: root.feeds
                folders: root.folders
                onItemActivated: (id) => root.openItem(id)
                onStarToggled: (id, starred) => root.toggleStar(id, starred)
                onViewRequested: (name) => { root.view = name; root.loadItems(true) }
                onSearchChanged: (text) => { root.searchText = text; searchTimer.restart() }
                onRefreshRequested: root.startRefresh()
                onMarkAllRequested: root.requestMarkAll()
                onSourceSelected: (kind, value) => {
                    if (kind === "view")
                        root.selectSmart(value)
                    else if (kind === "folder")
                        root.selectFolder(value)
                    else
                        root.selectFeed(Number(value))
                }
                onAddFeedRequested: { root.addFeedFolder = ""; root.addFeedOpen = true }
                onSettingsRequested: root.settingsOpen = true
                onLoadMoreRequested: root.loadMore()
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
                paddingPercent: root.readerPadding
                themeName: root.readerTheme
                prefs: root.prefs
                compactMode: root.compactUi
                feedTitle: root.article ? (root.article.feed_title || "") : ""
                feedIcon: root.article ? root.feedIcon(root.article.feed_id) : ""
                onClosed: root.readerOpen = false
                onStarToggled: (id, starred) => root.toggleStar(id, starred)
                onOpenExternal: (url) => Qt.openUrlExternally(url)
                onReextractRequested: root.reextractCurrent()
                onPrefsEdited: (values) => root.setPrefs(values)
                onFontScaleChanged: (delta) => root.setPref("font_scale",
                    Math.max(80, Math.min(170, root.fontScale + delta)))
            }
        }

        AddFeedSheet {
            anchors.fill: parent
            visible: root.addFeedOpen
            folders: root.folders
            presetFolder: root.addFeedFolder
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
            connectionMode: root.connectionMode
            backendPort: root.backendPort
            socketPath: root.configuredSocket
            backendEndpoint: root.backendEndpointText
            onClosed: root.settingsOpen = false
            onBackendSettingsChanged: (mode, port, path) => root.setBackendConnection(mode, port, path)
            onBackendActionRequested: (action) => root.backendAction(action)
            onPrefChanged: (key, value) => root.setPref(key, value)
            onPrefsPatched: (values) => root.setPrefs(values)
            onRefreshNowRequested: root.startRefresh()
            onImportOpml: (text) => root.importOpml(text)
            onDeleteFeedRequested: (id) => root.deleteFeed(id)
            onSubscriptionsChanged: root.loadState(false)
            onAddFeedRequested: (folder) => {
                root.addFeedFolder = folder
                root.settingsOpen = false
                root.addFeedOpen = true
            }
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

        // One explicit confirmation for the destructive sweep instead of a timing window.
        ConfirmSheet {
            anchors.fill: parent
            visible: root.confirmMarkAllOpen
            title: i18n("Mark everything read?")
            message: root.scopeUnread === 1
                     ? i18n("1 unread item in %1 becomes read.", root.scopeLabel)
                     : i18n("%1 unread items in %2 become read.", root.scopeUnread, root.scopeLabel)
            detail: i18n("The notice banner keeps an Undo button for a few seconds afterwards.")
            confirmLabel: i18n("Mark read")
            confirmIcon: "mail-mark-read"
            onConfirmed: root.markAllRead()
            onCancelled: root.confirmMarkAllOpen = false
        }

        Rectangle {
            id: noticeBar
            anchors.top: parent.top
            anchors.right: parent.right
            anchors.margins: Kirigami.Units.smallSpacing
            width: Math.min(parent.width - 2 * Kirigami.Units.smallSpacing,
                            noticeText.implicitWidth + undoButton.implicitWidth
                            + Kirigami.Units.gridUnit * 3)
            height: Math.max(noticeText.implicitHeight, undoButton.implicitHeight)
                    + Kirigami.Units.smallSpacing * 2
            radius: Kirigami.Units.smallSpacing
            color: Kirigami.Theme.backgroundColor
            border.width: 1
            border.color: Kirigami.Theme.textColor
            opacity: root.notice.length > 0 ? 0.97 : 0
            visible: opacity > 0

            Behavior on opacity { NumberAnimation { duration: 120 } }

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: Kirigami.Units.smallSpacing * 2
                anchors.rightMargin: Kirigami.Units.smallSpacing
                spacing: Kirigami.Units.smallSpacing

                Text {
                    id: noticeText
                    Layout.fillWidth: true
                    Layout.alignment: Qt.AlignVCenter
                    text: root.notice
                    color: Kirigami.Theme.textColor
                    wrapMode: Text.Wrap
                    maximumLineCount: 4
                    elide: Text.ElideRight
                    font.pixelSize: Math.round(Kirigami.Units.gridUnit * 0.75)
                }

                PlasmaComponents3.Button {
                    id: undoButton
                    Layout.alignment: Qt.AlignVCenter
                    visible: root.undoMarkAll !== null
                    text: i18n("Undo")
                    icon.name: "edit-undo"
                    // The banner is short-lived, so keep the undo tap cheap and single.
                    onClicked: root.undoMarkAllRead()
                }
            }
        }
    }
}
