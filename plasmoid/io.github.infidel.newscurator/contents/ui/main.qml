import QtQuick
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.plasma.plasmoid
import org.kde.plasma.components as PlasmaComponents3
import org.kde.plasma.plasma5support as P5Support
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
    // 0 until the launcher reports the published port: in socket mode there is no port to guess,
    // so the widget must not fire requests at the default one and paint an offline banner first.
    property int activePort: connectionMode === "socket" ? 0 : configuredPort
    // Port the widget itself talks to; 0 = no channel yet (socket mode before the endpoint line).
    readonly property int channelPort: activePort > 0
                                       ? activePort
                                       : (connectionMode === "socket" ? 0 : configuredPort)
    // Configured port, for the Settings field and the endpoint text.
    readonly property int backendPort: activePort > 0 ? activePort : configuredPort
    readonly property string backendEndpointText: {
        if (connectionMode === "socket") {
            var path = configuredSocket.length > 0 ? configuredSocket
                                                   : "$XDG_RUNTIME_DIR/knews-curator/knewsd.sock"
            return channelPort > 0
                ? i18n("unix socket %1 — widget channel 127.0.0.1:%2", path, channelPort)
                : i18n("unix socket %1", path)
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
    // The query the rows on screen belong to, and the one a request is out for. A list refresh
    // for the same view must not blank the pane (that is the startup blink); only a real
    // navigation to a different view clears it.
    property string shownQuery: ""
    property string inflightQuery: ""
    property int itemRequestId: 0
    property bool stateLoading: false
    property string view: "unread"
    property int selectedFeedId: 0
    property string selectedFolder: ""
    property string searchText: ""
    property var article: null
    property int currentItemId: 0
    property bool readerOpen: false
    property bool backendUp: false
    // The widget is the supervisor, not a one-shot launcher: when a load fails it re-arms itself
    // with exponential backoff until the daemon answers again. "Stop backend" is sticky until the
    // user starts it again, so the supervisor never fights an explicit decision.
    property bool backendStoppedByUser: false
    // Was the backend ever healthy in this widget instance? Distinguishes "still starting" from
    // "died under a running widget", which is what the status strip reports.
    property bool backendEverUp: false
    // Newer release, if the (opt-in, 24 h throttled) update check found one.
    property string updateVersion: ""
    property string updateUrl: ""
    property bool updateNotified: false
    property bool iconsRunning: false
    property int iconsDone: 0
    property int iconsTotal: 0
    // Release details dialog. Notes are fetched on demand: the strip must not wait for the API.
    property bool updateDialogOpen: false
    property string updateNotes: ""
    property string updatePublished: ""
    property bool updateNotesLoading: false
    property string updateNotesError: ""
    property int supervisorAttempts: 0
    readonly property int supervisorInterval: Math.min(60000,
                                                      5000 * Math.pow(2, Math.min(supervisorAttempts, 4)))
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
        if (channelPort > 0) {
            Api.setPort(channelPort)
            loadState()
        }
        // A store install has no installer: the widget starts the backend it ships. The script
        // answers /api/health first, so this is a no-op when a daemon already runs.
        backendLauncher.start()
        restoreUpdate()
        updateTimer.start()
    }

    // The widget is the supervisor: when it goes away, so does the daemon it started.
    // bootstrap.sh refuses to touch a backend it did not start (e.g. the systemd unit), and the
    // daemon also reaps itself after KNEWS_IDLE_EXIT seconds without a request.
    Component.onDestruction: backendLauncher.stop()

    // ------------------------------------------------------------- update check
    // Opt-in, one request per 24 h, and it must never surface an error: offline, rate limited or
    // parsing garbage all mean "say nothing". The widget never installs anything; the update
    // button opens the release page.
    readonly property string installedVersion: {
        var meta = Plasmoid.metaData
        return (meta && meta.version) ? String(meta.version) : ""
    }

    function versionParts(text) {
        var parts = String(text).replace(/^v/, "").split(/[.+-]/)
        var out = []
        for (var i = 0; i < 3; i++)
            out.push(parseInt(parts[i] || "0", 10) || 0)
        return out
    }

    function versionNewer(candidate, current) {
        var a = versionParts(candidate)
        var b = versionParts(current)
        for (var i = 0; i < 3; i++) {
            if (a[i] > b[i])
                return true
            if (a[i] < b[i])
                return false
        }
        return false
    }

    function releaseUrl(version) {
        return "https://github.com/motangpuar/kde-widget-rss-reader/releases/tag/v" + version
    }

    // The check result is persisted: a found update must not disappear when plasmashell restarts,
    // and the 24 h throttle means the next check may be a day away.
    function restoreUpdate() {
        var known = Plasmoid.configuration.availableVersion || ""
        if (known.length === 0 || known === Plasmoid.configuration.skippedVersion
                || !versionNewer(known, installedVersion))
            return
        updateVersion = known
        updateUrl = releaseUrl(known)
        console.info("newscurator update: showing", known, "installed", installedVersion)
    }

    function setUpdateState(version) {
        updateVersion = version
        Plasmoid.configuration.availableVersion = version
        updateUrl = version.length > 0 ? releaseUrl(version) : ""
    }

    function checkForUpdate(force) {
        if (!Plasmoid.configuration.updateCheck || installedVersion.length === 0)
            return
        var now = Math.floor(Date.now() / 1000)
        if (!force && now - (Plasmoid.configuration.updateCheckedAt || 0) < 86400)
            return
        var xhr = new XMLHttpRequest()
        // No custom headers: the widget does not need them and they would only add preflight noise.
        xhr.open("GET", "https://api.github.com/repos/motangpuar/kde-widget-rss-reader/releases/latest")
        xhr.onreadystatechange = function () {
            if (xhr.readyState !== XMLHttpRequest.DONE)
                return
            if (xhr.status !== 200)
                return
            var data = null
            try {
                data = JSON.parse(xhr.responseText)
            } catch (err) {
                return
            }
            var latest = String(data.tag_name || "").replace(/^v/, "")
            if (latest.length === 0)
                return
            // One greppable line: "ran but nothing appeared" is otherwise invisible in the journal.
            console.info("newscurator update check: latest", latest, "installed", installedVersion)
            Plasmoid.configuration.updateCheckedAt = now
            if (latest === Plasmoid.configuration.skippedVersion
                    || !versionNewer(latest, installedVersion)) {
                setUpdateState("")
                return
            }
            setUpdateState(latest)
            updateUrl = String(data.html_url || releaseUrl(latest))
            announceUpdate()
        }
        xhr.send()
    }

    // One desktop notification per widget load, and only when notify-send exists: the store has no
    // notification API for applets, and a missing helper must not turn into an error message.
    function announceUpdate() {
        if (updateNotified || updateVersion.length === 0)
            return
        updateNotified = true
        var title = shellQuote(i18n("News Curator %1 is available", updateVersion))
        var body = shellQuote(i18n("Open Settings in the widget to update, or press Update in the list."))
        var script = "command -v notify-send >/dev/null 2>&1 || exit 0; "
            + "exec notify-send -a \"News Curator\" -i newscurator -- " + title + " " + body
        notifyDataSource.connectSource("sh -c " + shellQuote(script))
    }

    function shellQuote(text) {
        return "'" + String(text).replace(/'/g, "'\\''") + "'"
    }

    function skipUpdate() {
        if (updateVersion.length > 0)
            Plasmoid.configuration.skippedVersion = updateVersion
        setUpdateState("")
    }

    function showUpdate() {
        if (updateVersion.length === 0)
            return
        updateDialogOpen = true
        if (updateNotes.length > 0 || updateNotesLoading)
            return
        fetchReleaseNotes(updateVersion)
    }

    function fetchReleaseNotes(version) {
        updateNotesLoading = true
        updateNotesError = ""
        var xhr = new XMLHttpRequest()
        xhr.open("GET", "https://api.github.com/repos/motangpuar/kde-widget-rss-reader/releases/tags/v"
                        + version)
        xhr.onreadystatechange = function () {
            if (xhr.readyState !== XMLHttpRequest.DONE)
                return
            updateNotesLoading = false
            if (xhr.status !== 200) {
                updateNotesError = i18n("Could not load the release notes.")
                return
            }
            var data = null
            try {
                data = JSON.parse(xhr.responseText)
            } catch (err) {
                updateNotesError = i18n("Could not load the release notes.")
                return
            }
            updateNotes = String(data.body || "")
            updatePublished = String(data.published_at || "")
            if (data.html_url)
                updateUrl = String(data.html_url)
        }
        xhr.send()
    }

    // Qt.openUrlExternally can report false in a bare plasmoid session; xdg-open is the fallback.
    function openUpdate() {
        var target = updateUrl.length > 0 ? updateUrl : releaseUrl(updateVersion)
        if (target.length === 0)
            return
        if (Qt.openUrlExternally(target))
            return
        notifyDataSource.connectSource("xdg-open " + shellQuote(target))
    }

    // ------------------------------------------------------------ icons
    function refreshIcons() {
        if (!backendUp)
            return
        Api.request("POST", "/api/icons/refresh", {}, function (status, data) {
            if (status !== 200) {
                showNotice(i18n("Could not start the icon refresh"))
                return
            }
            iconsRunning = true
            showNotice(i18n("Redownloading source icons…"))
            iconsPollTimer.restart()
        })
    }

    function setBackendConnection(mode, port, socketPath) {
        backendStoppedByUser = false
        supervisorAttempts = 0
        Plasmoid.configuration.connection = mode === "socket" ? 1 : 0
        if (port > 0)
            Plasmoid.configuration.port = port
        Plasmoid.configuration.socketPath = socketPath || ""
        statusMessage = i18n("Restarting the feed backend…")
        backendLauncher.restart()
    }

    function backendAction(action) {
        if (action === "stop") {
            backendStoppedByUser = true
            backendLauncher.stop()
            backendUp = false
            statusMessage = i18n("Backend stopped. It starts again when this widget reloads.")
            return
        }
        backendStoppedByUser = false
        supervisorAttempts = 0
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
            // bootstrap.sh prints its endpoint line only after /api/health answered, so the first
            // sync can run now; the retry timer stays as a fallback and stops on the first success.
            if (state === "running") {
                statusMessage = i18n("Starting the feed backend…")
                backendRetry.restart()
                root.loadState()
            } else if (state === "already") {
                backendRetry.restart()
                root.loadState()
            } else if (state === "no-python") {
                root.backendStoppedByUser = true
                statusMessage = i18n("Python 3 is required for the feed backend. "
                                     + "Install python3, then reopen this widget.")
            } else if (state === "missing") {
                root.backendStoppedByUser = true
                statusMessage = i18n("This package has no bundled backend — "
                                     + "install the full release instead.")
            } else {
                statusMessage = i18n("Could not start the feed backend. "
                                     + "See ~/.cache/knews-curator/knewsd.log")
            }
        }
    }

    // Silent death (OOM kill, session teardown, a crash) used to leave the widget offline until
    // the next plasmashell load: the retry poll below is only armed after a successful spawn.
    // This timer is the supervisor. bootstrap.sh answers /api/health first, so calling start()
    // again is a cheap no-op when a daemon is already up.
    Timer {
        id: backendSupervisor
        interval: root.supervisorInterval
        repeat: true
        running: !root.backendUp && !root.backendStoppedByUser
        onTriggered: {
            if (backendLauncher.busy)
                return
            root.supervisorAttempts = Math.min(root.supervisorAttempts + 1, 8)
            root.statusMessage = root.supervisorAttempts > 1
                ? i18n("Backend offline — retrying (attempt %1).", root.supervisorAttempts)
                : i18n("Backend offline — restarting it.")
            backendLauncher.start()
        }
    }

    // Polls /api/state while the icon repair runs, then reloads so the new favicons are used.
    Timer {
        id: iconsPollTimer
        interval: 1500
        repeat: true
        onTriggered: {
            Api.request("GET", "/api/state", null, function (status, data) {
                if (status !== 200 || !data) {
                    iconsPollTimer.stop()
                    iconsRunning = false
                    return
                }
                var icons = data.icons || {}
                root.iconsDone = icons.done || 0
                root.iconsTotal = icons.total || 0
                iconsRunning = !!icons.running
                if (!iconsRunning) {
                    iconsPollTimer.stop()
                    root.loadState()
                    showNotice(i18n("Source icons refreshed"))
                }
            })
        }
    }

    // First check ~20 s after load (never in the middle of the startup repaint), then the
    // throttle inside checkForUpdate() decides.
    Timer {
        id: updateTimer
        interval: 20000
        onTriggered: root.checkForUpdate(false)
    }

    P5Support.DataSource {
        id: notifyDataSource
        engine: "executable"
        connectedSources: []
        onNewData: (sourceName, data) => {
            notifyDataSource.disconnectSource(sourceName)
        }
    }

    // Detection, not recovery: the 60 s sync is too slow to notice an OOM kill, and the supervisor
    // below only arms once backendUp is false. One local health call every 15 s costs nothing and
    // keeps worst-case recovery under 20 s (detect <= 15 s + first backoff 5 s).
    Timer {
        id: backendHealth
        interval: 15000
        repeat: true
        running: root.backendUp
        onTriggered: {
            Api.request("GET", "/api/health", null, function (status, data) {
                if (status !== 200 || !data || !data.ok)
                    root.fail(status)
            })
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

    onChannelPortChanged: {
        Api.setPort(channelPort)
        // The endpoint line usually lands right after a successful sync; re-reading the state then
        // only repaints the same rows. Reload only when the previous port was wrong/offline.
        if (!root.backendUp && root.channelPort > 0)
            root.loadState()
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
        if (stateLoading)
            return
        stateLoading = true
        Api.request("GET", "/api/state", null, function (status, data) {
            stateLoading = false
            if (status === 200 && data) {
                backendUp = true
                backendEverUp = true
                statusMessage = ""
                supervisorAttempts = 0
                backendRetry.stop()
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

    function itemQuery() {
        var query = "view=" + Api.encode(view)
        if (selectedFeedId > 0)
            query += "&feed=" + selectedFeedId
        else if (selectedFolder)
            query += "&folder=" + Api.encode(selectedFolder)
        if (searchText)
            query += "&q=" + Api.encode(searchText)
        return query
    }

    function loadItems(reset) {
        var query = itemQuery()
        if (reset !== false) {
            // Duplicate triggers are the normal case at startup (initial load, endpoint report,
            // retry poll, 60 s sync); collapse them into one request.
            if (loadingItems && inflightQuery === query)
                return
            if (query !== shownQuery) {
                // Real navigation: the old rows belong to another feed or search term.
                items = []
                totalItems = 0
            }
        } else {
            if (loadingItems || items.length >= totalItems || query !== shownQuery)
                return
        }
        loadingItems = true
        inflightQuery = query
        // Switching views while a request is out must not let the older answer land: only the
        // newest request owns loadingItems, totalItems and the rows.
        var requestId = ++root.itemRequestId
        var path = "/api/items?limit=60&" + query
        if (reset === false)
            path += "&offset=" + items.length
        Api.request("GET", path, null, function (status, data) {
            if (requestId !== root.itemRequestId)
                return
            loadingItems = false
            inflightQuery = ""
            if (status !== 200 || !data) {
                fail(status)
                return
            }
            backendUp = true
            totalItems = data.total || 0
            if (reset === false && query === shownQuery)
                items = items.concat(data.items || [])
            else {
                items = data.items || []
                shownQuery = query
            }
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
                backendEverUp: root.backendEverUp
                backendStopped: root.backendStoppedByUser
                updateVersion: root.updateVersion
                statusMessage: root.statusMessage
                selectionTitle: root.selectedTitle()
                thumbBase: root.channelPort > 0
                           ? "http://127.0.0.1:" + root.channelPort + "/api/thumb?id=" : ""
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
                onRestartRequested: root.backendAction("restart")
                onUpdateRequested: root.showUpdate()
                onUpdateSkipRequested: root.skipUpdate()
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

        UpdateDialog {
            anchors.fill: parent
            visible: root.updateDialogOpen
            installedVersion: root.installedVersion
            version: root.updateVersion
            notes: root.updateNotes
            publishedAt: root.updatePublished
            url: root.updateUrl
            loading: root.updateNotesLoading
            errorText: root.updateNotesError
            onOpenRequested: root.openUpdate()
            onSkipRequested: {
                root.skipUpdate()
                root.updateDialogOpen = false
            }
            onDismissed: root.updateDialogOpen = false
        }

        SettingsSheet {
            anchors.fill: parent
            visible: root.settingsOpen
            prefs: root.prefs
            feeds: root.feeds
            backendUp: root.backendUp
            exportDir: root.exportDir
            connectionMode: root.connectionMode
            backendPort: root.configuredPort
            socketPath: root.configuredSocket
            backendEndpoint: root.backendEndpointText
            updateCheckEnabled: Plasmoid.configuration.updateCheck
            installedVersion: root.installedVersion
            updateVersion: root.updateVersion
            skippedVersion: Plasmoid.configuration.skippedVersion || ""
            onUpdateCheckToggled: (enabled) => {
                Plasmoid.configuration.updateCheck = enabled
                if (enabled)
                    root.checkForUpdate(true)
                else
                    root.updateVersion = ""
            }
            onUpdateCheckRequested: root.checkForUpdate(true)
            onUpdateDetailsRequested: root.showUpdate()
            iconsRunning: root.iconsRunning
            iconsDone: root.iconsDone
            iconsTotal: root.iconsTotal
            onIconsRefreshRequested: root.refreshIcons()
            onUpdateSkipCleared: {
                Plasmoid.configuration.skippedVersion = ""
                root.checkForUpdate(true)
            }
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
