import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import QtQuick.Dialogs
import org.kde.kirigami as Kirigami
import org.kde.plasma.components as PlasmaComponents3
import "Api.js" as Api

Item {
    id: sheet

    property var prefs: ({})
    property var feeds: []
    property bool backendUp: false
    property string exportDir: ""

    signal closed()
    signal prefChanged(string key, var value)
    signal prefsPatched(var values)
    signal refreshNowRequested()
    signal importOpml(string text)
    signal feedsAdded(int added, int failed)
    signal subscriptionsChanged()
    signal addFeedRequested(string folder)
    signal deleteFeedRequested(int id)

    property string opmlStatus: ""
    property string exportStatus: ""
    property string feedStatus: ""
    property bool feedStatusIsError: false

    // Bulk address validation: check every pasted line before adding anything.
    property var checkResults: []
    property bool checking: false
    property bool adding: false

    // Inline feed editor: 0 = no row is being edited.
    property int editingId: 0

    readonly property int gutter: Kirigami.Units.gridUnit

    // ---------------------------------------------------------------- helpers
    function pref(key, fallback) {
        var value = prefs ? prefs[key] : undefined
        return value === undefined || value === null ? fallback : value
    }

    // Index of the entry whose `key` matches value, so a ComboBox can show the stored pref.
    function indexOf(entries, key, value) {
        for (var i = 0; i < entries.length; ++i)
            if (entries[i][key] === value)
                return i
        return 0
    }

    // Curated families that are actually installed, so the list never offers a dead font.
    function fontChoices() {
        var wanted = ["Noto Serif", "Noto Sans", "Liberation Serif", "Liberation Sans",
                      "Adwaita Sans", "Cantarell", "DejaVu Serif", "DejaVu Sans",
                      "Source Serif 4", "Latin Modern Roman", "Georgia"]
        var installed = Qt.fontFamilies()
        var out = [{ "label": i18n("System sans"), "family": "", "serif": 0 },
                   { "label": i18n("System serif"), "family": "", "serif": 1 }]
        for (var i = 0; i < wanted.length; ++i)
            if (installed.indexOf(wanted[i]) >= 0)
                out.push({ "label": wanted[i], "family": wanted[i], "serif": 0 })
        return out
    }

    function fontIndex() {
        var choices = fontChoices()
        var family = pref("font_family", "")
        var serif = (pref("serif", 0) | 0) === 1
        for (var i = 0; i < choices.length; ++i)
            if (choices[i].family === family && choices[i].serif === (family.length > 0 ? 0 : serif))
                return i
        return 0
    }

    function favicon(feed) {
        return (feed && feed.icon) ? feed.icon : ""
    }

    function feedLabel(feed) {
        return (feed && (feed.title || feed.url)) || ""
    }

    // Feeds grouped by folder, with the ungrouped bucket last so real folders read first.
    function buildGroups() {
        var order = []
        var buckets = ({})
        for (var i = 0; i < (feeds ? feeds.length : 0); ++i) {
            var feed = feeds[i]
            var key = feed.folder || ""
            if (!buckets[key]) {
                buckets[key] = []
                order.push(key)
            }
            buckets[key].push(feed)
        }
        order.sort(function (a, b) {
            if (a === "")
                return 1
            if (b === "")
                return -1
            return a.localeCompare(b)
        })
        var groups = []
        for (var k = 0; k < order.length; ++k) {
            var name = order[k]
            groups.push({
                "name": name,
                "label": name.length > 0 ? name : i18n("No folder"),
                "items": buckets[name],
                "count": buckets[name].length
            })
        }
        return groups
    }

    property var feedGroups: buildGroups()

    onVisibleChanged: if (!visible) { editingId = 0; feedStatus = "" }

    function addressLines() {
        var raw = urlsArea.text.split(/[\s,]+/)
        var out = []
        for (var i = 0; i < raw.length; ++i) {
            var text = raw[i].trim()
            if (text.length > 0 && out.indexOf(text) < 0)
                out.push(text)
        }
        return out.slice(0, 50)
    }

    function checkAddresses() {
        var lines = addressLines()
        if (lines.length === 0) {
            exportStatus = i18n("Paste one feed address per line first.")
            return
        }
        checking = true
        checkResults = []
        exportStatus = i18n("Checking %1 addresses…", lines.length)
        Api.request("POST", "/api/validate", { "urls": lines }, function (status, data) {
            sheet.checking = false
            if (status !== 200 || !data) {
                sheet.exportStatus = i18n("Could not check those addresses.")
                return
            }
            sheet.checkResults = data.results || []
            var good = sheet.checkResults.filter(function (r) { return r.ok }).length
            var dupes = sheet.checkResults.filter(function (r) { return r.existing }).length
            sheet.exportStatus = i18n("%1 of %2 addresses are usable feeds", good,
                                      sheet.checkResults.length)
                                  + (dupes > 0 ? i18n(" (%1 already followed)", dupes) : "")
        })
    }

    function followChecked() {
        var urls = checkResults.filter(function (r) { return r.ok && !r.existing })
                                  .map(function (r) { return r.url })
        if (urls.length === 0) {
            exportStatus = i18n("Nothing to add: check the addresses first.")
            return
        }
        adding = true
        exportStatus = i18n("Following %1 feeds…", urls.length)
        Api.request("POST", "/api/feeds/bulk",
                    { "urls": urls, "folder": listFolder.text.trim() },
                    function (status, data) {
            sheet.adding = false
            if (status !== 200 || !data) {
                sheet.exportStatus = i18n("Could not add those feeds.")
                return
            }
            var failed = (data.results || []).filter(function (r) { return !r.ok }).length
            sheet.exportStatus = failed === 0
                    ? (data.added === 1 ? i18n("Added 1 feed.") : i18n("Added %1 feeds.", data.added))
                    : i18n("Added %1, %2 failed.", data.added, failed)
            urlsArea.text = ""
            sheet.checkResults = []
            sheet.feedsAdded(data.added, failed)
        })
    }

    function saveFeed(id, title, url, folder) {
        feedStatus = i18n("Saving…")
        feedStatusIsError = false
        Api.request("POST", "/api/feeds/update",
                    { "id": id, "title": title, "url": url, "folder": folder },
                    function (status, data) {
            if (status !== 200 || !data || data.error) {
                sheet.feedStatus = (data && data.error) ? data.error
                                                        : i18n("Could not save that feed.")
                sheet.feedStatusIsError = true
                return
            }
            sheet.editingId = 0
            sheet.feedStatus = i18n("Saved %1", (data.feed && (data.feed.title || data.feed.url)) || "")
            sheet.feedStatusIsError = false
            sheet.subscriptionsChanged()
        })
    }

    function setEnabled(feed, enabled) {
        feedStatus = i18n("Saving…")
        feedStatusIsError = false
        Api.request("POST", "/api/feeds/update", { "id": feed.id, "enabled": enabled ? 1 : 0 },
                    function (status, data) {
            if (status !== 200 || !data || data.error) {
                sheet.feedStatus = (data && data.error) ? data.error
                                                        : i18n("Could not update that feed.")
                sheet.feedStatusIsError = true
                return
            }
            sheet.feedStatus = enabled ? i18n("Resumed %1", feed.title || feed.url)
                                       : i18n("Paused %1", feed.title || feed.url)
            sheet.feedStatusIsError = false
            sheet.subscriptionsChanged()
        })
    }

    function exportToFile(url) {
        var path = url.toString().replace(/^file:\/\//, "")
        exportStatus = i18n("Writing %1…", path)
        Api.request("POST", "/api/opml/save", { "path": path }, function (status, data) {
            if (status === 200 && data) {
                sheet.exportStatus = i18n("Saved %1 feeds to %2", data.feeds, data.path)
                if (data.fallback)
                    sheet.exportStatus += " " + i18n("(that folder is not writable, so the "
                                                     + "export went to the app data folder)")
            } else {
                sheet.exportStatus = (data && data.error) ? data.error
                                                          : i18n("Could not write that file.")
            }
        })
    }

    function loadOpmlFile(url) {
        var path = url.toString()
        var xhr = new XMLHttpRequest()
        xhr.onreadystatechange = function () {
            if (xhr.readyState !== XMLHttpRequest.DONE)
                return
            var text = xhr.responseText || ""
            if (text.indexOf("<opml") < 0) {
                sheet.opmlStatus = i18n("That file is not an OPML export.")
                return
            }
            sheet.opmlStatus = i18n("Importing %1…", path.replace(/^file:\/\//, ""))
            sheet.importOpml(text)
        }
        xhr.open("GET", path)
        xhr.send()
    }

    FileDialog {
        id: opmlDialog
        title: i18n("Import OPML")
        fileMode: FileDialog.OpenFile
        nameFilters: [i18n("OPML exports (*.opml *.xml)"), i18n("All files (*)")]
        onAccepted: sheet.loadOpmlFile(selectedFile)
    }

    FileDialog {
        id: exportDialog
        title: i18n("Save OPML export")
        fileMode: FileDialog.SaveFile
        defaultSuffix: "opml"
        acceptLabel: i18n("Save")
        nameFilters: [i18n("OPML exports (*.opml)")]
        onAccepted: sheet.exportToFile(selectedFile)
    }

    // ------------------------------------------------------------ section shell
    // One rounded card per topic so the start and the end of every section is visible.
    component Section: Rectangle {
        id: section
        property string title: ""
        property string summary: ""
        default property alias body: sectionColumn.data

        Layout.fillWidth: true
        implicitHeight: sectionColumn.implicitHeight + Kirigami.Units.gridUnit * 1.2
        radius: Kirigami.Units.smallSpacing + 2
        color: Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g,
                       Kirigami.Theme.textColor.b, 0.05)
        border.width: 1
        border.color: Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g,
                              Kirigami.Theme.textColor.b, 0.12)

        ColumnLayout {
            id: sectionColumn
            anchors.fill: parent
            anchors.margins: Kirigami.Units.gridUnit * 0.65
            spacing: Kirigami.Units.smallSpacing

            RowLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing
                Text {
                    text: section.title
                    color: Kirigami.Theme.textColor
                    font.bold: true
                    font.pixelSize: Math.round(Kirigami.Units.gridUnit * 0.86)
                }
                Text {
                    visible: section.summary.length > 0
                    text: section.summary
                    color: Kirigami.Theme.disabledTextColor
                    font.pixelSize: Math.round(Kirigami.Units.gridUnit * 0.7)
                    elide: Text.ElideRight
                    Layout.fillWidth: true
                }
                Item {
                    visible: section.summary.length === 0
                    Layout.fillWidth: true
                }
            }

            Rectangle {
                Layout.fillWidth: true
                implicitHeight: 1
                color: Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g,
                               Kirigami.Theme.textColor.b, 0.1)
            }
        }
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
        id: card
        anchors.centerIn: parent
        // Cap the card, then keep it inside the widget with equal margins on every edge.
        width: Math.min(parent.width - sheet.gutter * 2, sheet.gutter * 34)
        height: Math.min(parent.height - sheet.gutter * 2, sheet.gutter * 42)
        radius: Kirigami.Units.smallSpacing + 2
        color: Kirigami.Theme.backgroundColor
        border.width: 1
        border.color: Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g,
                              Kirigami.Theme.textColor.b, 0.15)
        clip: true

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: sheet.gutter * 0.75
            spacing: Kirigami.Units.smallSpacing

            RowLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing
                Text {
                    Layout.fillWidth: true
                    text: i18n("Settings")
                    color: Kirigami.Theme.textColor
                    font.bold: true
                    font.pixelSize: Math.round(Kirigami.Units.gridUnit * 1.05)
                    elide: Text.ElideRight
                }
                PlasmaComponents3.Button {
                    text: i18n("Close")
                    icon.name: "window-close"
                    onClicked: sheet.closed()
                }
            }

            PlasmaComponents3.ScrollView {
                id: scroll
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                ScrollBar.vertical.policy: ScrollBar.AsNeeded
                ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
                contentWidth: availableWidth

                ColumnLayout {
                    width: scroll.availableWidth
                    spacing: Kirigami.Units.smallSpacing * 2

                    // ------------------------------------------------------ content
                    Section {
                        title: i18n("Content")
                        summary: i18n("how articles are rendered")

                        GridLayout {
                            Layout.fillWidth: true
                            columns: 2
                            columnSpacing: Kirigami.Units.gridUnit
                            rowSpacing: Kirigami.Units.smallSpacing

                            Text {
                                text: i18n("Theme")
                                color: Kirigami.Theme.textColor
                                font.pixelSize: Math.round(Kirigami.Units.gridUnit * 0.74)
                            }
                            PlasmaComponents3.ComboBox {
                                Layout.fillWidth: true
                                model: [{ "value": "auto", "label": i18n("Follow Plasma") },
                                        { "value": "light", "label": i18n("Light") },
                                        { "value": "sepia", "label": i18n("Sepia") },
                                        { "value": "dark", "label": i18n("Dark") }]
                                textRole: "label"
                                currentIndex: sheet.indexOf(model, "value",
                                                            sheet.pref("reader_theme", "auto"))
                                onActivated: (index) => sheet.prefChanged("reader_theme",
                                                                          model[index].value)
                            }

                            Text {
                                text: i18n("Font")
                                color: Kirigami.Theme.textColor
                                font.pixelSize: Math.round(Kirigami.Units.gridUnit * 0.74)
                            }
                            PlasmaComponents3.ComboBox {
                                Layout.fillWidth: true
                                model: sheet.fontChoices()
                                textRole: "label"
                                currentIndex: sheet.fontIndex()
                                onActivated: (index) => {
                                    var choice = model[index]
                                    // Family and the sans/serif flag travel together.
                                    sheet.prefsPatched({ "font_family": choice.family,
                                                         "serif": choice.serif })
                                }
                            }

                            Text {
                                text: i18n("Size")
                                color: Kirigami.Theme.textColor
                                font.pixelSize: Math.round(Kirigami.Units.gridUnit * 0.74)
                            }
                            PlasmaComponents3.ComboBox {
                                Layout.fillWidth: true
                                model: [80, 100, 115, 130, 145, 160]
                                currentIndex: Math.max(0, model.indexOf(sheet.pref("font_scale", 100)))
                                onActivated: (index) => sheet.prefChanged("font_scale", model[index])
                                displayText: sheet.pref("font_scale", 100) + "%"
                            }

                            Text {
                                text: i18n("Line spacing")
                                color: Kirigami.Theme.textColor
                                font.pixelSize: Math.round(Kirigami.Units.gridUnit * 0.74)
                            }
                            PlasmaComponents3.ComboBox {
                                Layout.fillWidth: true
                                model: [{ "value": 140, "label": i18n("Tight") },
                                        { "value": 160, "label": i18n("Normal") },
                                        { "value": 180, "label": i18n("Relaxed") },
                                        { "value": 200, "label": i18n("Airy") }]
                                textRole: "label"
                                currentIndex: sheet.indexOf(model, "value",
                                                            sheet.pref("line_height", 160))
                                onActivated: (index) => sheet.prefChanged("line_height",
                                                                          model[index].value)
                            }

                            Text {
                                text: i18n("Margins")
                                color: Kirigami.Theme.textColor
                                font.pixelSize: Math.round(Kirigami.Units.gridUnit * 0.74)
                            }
                            PlasmaComponents3.ComboBox {
                                Layout.fillWidth: true
                                model: [{ "value": 60, "label": i18n("Narrow") },
                                        { "value": 100, "label": i18n("Comfortable") },
                                        { "value": 140, "label": i18n("Wide") },
                                        { "value": 180, "label": i18n("Extra wide") }]
                                textRole: "label"
                                currentIndex: sheet.indexOf(model, "value",
                                                            sheet.pref("reader_padding", 100))
                                onActivated: (index) => sheet.prefChanged("reader_padding",
                                                                          model[index].value)
                            }
                        }

                        Rectangle {
                            Layout.fillWidth: true
                            Layout.topMargin: Kirigami.Units.smallSpacing / 2
                            implicitHeight: 1
                            color: Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g,
                                           Kirigami.Theme.textColor.b, 0.1)
                        }

                        PlasmaComponents3.CheckBox {
                            text: i18n("Mark read when opened")
                            checked: sheet.pref("auto_mark_read", 1) === 1
                            // toggled (not clicked) so the handler only fires on a real change
                            // and the checked binding is restored afterwards.
                            onToggled: sheet.prefChanged("auto_mark_read", checked ? 1 : 0)
                        }
                        PlasmaComponents3.CheckBox {
                            text: i18n("Open articles in the system browser instead")
                            checked: sheet.pref("open_external", 0) === 1
                            onToggled: sheet.prefChanged("open_external", checked ? 1 : 0)
                        }
                    }

                    // -------------------------------------------------------- feeds
                    Section {
                        title: i18n("Feeds")
                        summary: i18n("%1 subscriptions", sheet.feeds.length)

                        Repeater {
                            model: sheet.feedGroups
                            delegate: ColumnLayout {
                                id: group
                                required property var modelData
                                Layout.fillWidth: true
                                spacing: Kirigami.Units.smallSpacing / 2

                                RowLayout {
                                    Layout.fillWidth: true
                                    Layout.topMargin: Kirigami.Units.smallSpacing / 2
                                    spacing: Kirigami.Units.smallSpacing
                                    Kirigami.Icon {
                                        source: "folder"
                                        implicitWidth: Kirigami.Units.iconSizes.small
                                        implicitHeight: Kirigami.Units.iconSizes.small
                                        opacity: 0.7
                                    }
                                    Text {
                                        text: group.modelData.label
                                        color: Kirigami.Theme.textColor
                                        font.bold: true
                                        font.pixelSize: Math.round(Kirigami.Units.gridUnit * 0.74)
                                    }
                                    Text {
                                        text: group.modelData.count
                                        color: Kirigami.Theme.disabledTextColor
                                        font.pixelSize: Math.round(Kirigami.Units.gridUnit * 0.7)
                                    }
                                    Item { Layout.fillWidth: true }
                                    PlasmaComponents3.ToolButton {
                                        icon.name: "list-add"
                                        display: AbstractButton.IconOnly
                                        enabled: sheet.backendUp
                                        onClicked: sheet.addFeedRequested(group.modelData.name)
                                        PlasmaComponents3.ToolTip {
                                            text: group.modelData.name.length > 0
                                                  ? i18n("Add a feed to %1", group.modelData.name)
                                                  : i18n("Add a feed without a folder")
                                        }
                                    }
                                }

                                Repeater {
                                    model: group.modelData.items
                                    delegate: ColumnLayout {
                                        id: feedCard
                                        required property var modelData
                                        Layout.fillWidth: true
                                        spacing: Kirigami.Units.smallSpacing / 2

                                        readonly property bool editing: sheet.editingId === modelData.id
                                        readonly property bool hasIcon: sheet.favicon(modelData).length > 0
                                        property bool confirmDelete: false

                                        RowLayout {
                                            Layout.fillWidth: true
                                            spacing: Kirigami.Units.smallSpacing

                                            Image {
                                                id: feedIcon
                                                source: sheet.favicon(feedCard.modelData)
                                                visible: status === Image.Ready
                                                sourceSize.width: Kirigami.Units.iconSizes.small
                                                sourceSize.height: Kirigami.Units.iconSizes.small
                                                Layout.alignment: Qt.AlignVCenter
                                            }
                                            Kirigami.Icon {
                                                visible: !(feedCard.hasIcon
                                                           && feedIcon.status === Image.Ready)
                                                source: "application-rss+xml"
                                                implicitWidth: Kirigami.Units.iconSizes.small
                                                implicitHeight: Kirigami.Units.iconSizes.small
                                                opacity: 0.8
                                            }

                                            ColumnLayout {
                                                Layout.fillWidth: true
                                                spacing: 0
                                                Text {
                                                    Layout.fillWidth: true
                                                    text: sheet.feedLabel(feedCard.modelData)
                                                    color: feedCard.modelData.last_error
                                                           ? Kirigami.Theme.negativeTextColor
                                                           : (feedCard.modelData.enabled
                                                              ? Kirigami.Theme.textColor
                                                              : Kirigami.Theme.disabledTextColor)
                                                    font.pixelSize: Math.round(Kirigami.Units.gridUnit * 0.74)
                                                    font.strikeout: !feedCard.modelData.enabled
                                                    elide: Text.ElideRight
                                                }
                                                Text {
                                                    Layout.fillWidth: true
                                                    text: feedCard.modelData.url
                                                    color: Kirigami.Theme.disabledTextColor
                                                    font.pixelSize: Math.round(Kirigami.Units.gridUnit * 0.66)
                                                    elide: Text.ElideMiddle
                                                }
                                                Text {
                                                    Layout.fillWidth: true
                                                    visible: !!feedCard.modelData.last_error
                                                    text: feedCard.modelData.last_error || ""
                                                    color: Kirigami.Theme.negativeTextColor
                                                    font.pixelSize: Math.round(Kirigami.Units.gridUnit * 0.64)
                                                    elide: Text.ElideRight
                                                }
                                            }

                                            PlasmaComponents3.ToolButton {
                                                icon.name: feedCard.editing ? "dialog-cancel" : "document-edit"
                                                display: AbstractButton.IconOnly
                                                onClicked: sheet.editingId = feedCard.editing
                                                                    ? 0 : feedCard.modelData.id
                                                PlasmaComponents3.ToolTip {
                                                    text: feedCard.editing ? i18n("Cancel editing")
                                                                           : i18n("Edit title, address, folder")
                                                }
                                            }
                                            PlasmaComponents3.ToolButton {
                                                icon.name: feedCard.modelData.enabled
                                                           ? "media-playback-pause" : "media-playback-start"
                                                display: AbstractButton.IconOnly
                                                onClicked: sheet.setEnabled(feedCard.modelData,
                                                                            !feedCard.modelData.enabled)
                                                PlasmaComponents3.ToolTip {
                                                    text: feedCard.modelData.enabled
                                                          ? i18n("Pause this feed")
                                                          : i18n("Resume this feed")
                                                }
                                            }
                                            PlasmaComponents3.ToolButton {
                                                icon.name: feedCard.confirmDelete ? "dialog-ok-apply"
                                                                                  : "edit-delete"
                                                display: AbstractButton.IconOnly
                                                onClicked: {
                                                    if (!feedCard.confirmDelete) {
                                                        feedCard.confirmDelete = true
                                                        deleteTimer.restart()
                                                        return
                                                    }
                                                    deleteTimer.stop()
                                                    feedCard.confirmDelete = false
                                                    sheet.deleteFeedRequested(feedCard.modelData.id)
                                                }
                                                PlasmaComponents3.ToolTip {
                                                    text: feedCard.confirmDelete
                                                          ? i18n("Click again to delete this feed")
                                                          : i18n("Delete this feed")
                                                }
                                                Timer {
                                                    id: deleteTimer
                                                    interval: 4000
                                                    onTriggered: feedCard.confirmDelete = false
                                                }
                                            }
                                        }

                                        GridLayout {
                                            Layout.fillWidth: true
                                            Layout.leftMargin: Kirigami.Units.gridUnit * 1.4
                                            visible: feedCard.editing
                                            columns: 3
                                            columnSpacing: Kirigami.Units.smallSpacing
                                            rowSpacing: Kirigami.Units.smallSpacing / 2

                                            PlasmaComponents3.TextField {
                                                id: editTitle
                                                Layout.fillWidth: true
                                                Layout.columnSpan: 2
                                                placeholderText: i18n("Title")
                                                text: feedCard.modelData.title || ""
                                            }
                                            PlasmaComponents3.TextField {
                                                id: editFolder
                                                Layout.fillWidth: true
                                                placeholderText: i18n("Folder")
                                                text: feedCard.modelData.folder || ""
                                            }
                                            PlasmaComponents3.TextField {
                                                id: editUrl
                                                Layout.fillWidth: true
                                                Layout.columnSpan: 3
                                                placeholderText: i18n("Feed address")
                                                text: feedCard.modelData.url || ""
                                            }
                                            RowLayout {
                                                Layout.columnSpan: 3
                                                Layout.fillWidth: true
                                                spacing: Kirigami.Units.smallSpacing
                                                Text {
                                                    Layout.fillWidth: true
                                                    text: i18n("Changing the address re-checks it before saving.")
                                                    color: Kirigami.Theme.disabledTextColor
                                                    font.pixelSize: Math.round(Kirigami.Units.gridUnit * 0.66)
                                                    wrapMode: Text.WordWrap
                                                }
                                                PlasmaComponents3.Button {
                                                    text: i18n("Save")
                                                    icon.name: "document-save"
                                                    onClicked: sheet.saveFeed(feedCard.modelData.id,
                                                                              editTitle.text.trim(),
                                                                              editUrl.text.trim(),
                                                                              editFolder.text.trim())
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        Text {
                            Layout.fillWidth: true
                            visible: sheet.feedStatus.length > 0
                            text: sheet.feedStatus
                            color: sheet.feedStatusIsError ? Kirigami.Theme.negativeTextColor
                                                           : Kirigami.Theme.disabledTextColor
                            font.pixelSize: Math.round(Kirigami.Units.gridUnit * 0.7)
                            wrapMode: Text.WordWrap
                        }
                    }

                    // ---------------------------------------------------- add feeds
                    Section {
                        title: i18n("Add feeds")
                        summary: i18n("check addresses before following")

                        PlasmaComponents3.TextArea {
                            id: urlsArea
                            Layout.fillWidth: true
                            Layout.minimumHeight: Kirigami.Units.gridUnit * 3.5
                            placeholderText: "lwn.net/headlines/rss\nhttps://arstechnica.com/feed/\nexample.substack.com"
                            wrapMode: TextEdit.Wrap
                            background: Rectangle {
                                color: Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g,
                                               Kirigami.Theme.textColor.b, 0.06)
                                border.width: 1
                                border.color: Qt.rgba(Kirigami.Theme.textColor.r,
                                                      Kirigami.Theme.textColor.g,
                                                      Kirigami.Theme.textColor.b, 0.2)
                                radius: Kirigami.Units.smallSpacing / 2
                            }
                        }

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: Kirigami.Units.smallSpacing
                            PlasmaComponents3.TextField {
                                id: listFolder
                                Layout.fillWidth: true
                                placeholderText: i18n("Folder for the new feeds (optional)")
                            }
                            PlasmaComponents3.Button {
                                text: i18n("Check addresses")
                                icon.name: "dialog-ok-apply"
                                enabled: !sheet.checking && !sheet.adding && urlsArea.text.length > 0
                                onClicked: sheet.checkAddresses()
                            }
                            PlasmaComponents3.BusyIndicator {
                                visible: sheet.checking || sheet.adding
                                running: sheet.checking || sheet.adding
                                implicitWidth: Kirigami.Units.gridUnit * 1.4
                                implicitHeight: Kirigami.Units.gridUnit * 1.4
                            }
                        }

                        Text {
                            Layout.fillWidth: true
                            visible: sheet.exportStatus.length > 0
                            text: sheet.exportStatus
                            color: Kirigami.Theme.disabledTextColor
                            font.pixelSize: Math.round(Kirigami.Units.gridUnit * 0.7)
                            wrapMode: Text.WordWrap
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 0
                            visible: sheet.checkResults.length > 0

                            Repeater {
                                model: sheet.checkResults
                                delegate: RowLayout {
                                    required property var modelData
                                    Layout.fillWidth: true
                                    spacing: Kirigami.Units.smallSpacing

                                    Kirigami.Icon {
                                        source: modelData.ok ? "dialog-ok-apply" : "dialog-error"
                                        color: modelData.ok ? Kirigami.Theme.positiveTextColor
                                                            : Kirigami.Theme.negativeTextColor
                                        implicitWidth: Kirigami.Units.iconSizes.small
                                        implicitHeight: Kirigami.Units.iconSizes.small
                                    }
                                    Text {
                                        Layout.fillWidth: true
                                        text: modelData.ok
                                              ? (modelData.title || modelData.url)
                                                + " · " + i18n("%1 items", modelData.entries)
                                                + (modelData.existing ? " · " + i18n("already followed") : "")
                                              : modelData.url + " · " + (modelData.error || i18n("failed"))
                                        color: modelData.ok ? Kirigami.Theme.textColor
                                                            : Kirigami.Theme.negativeTextColor
                                        font.pixelSize: Math.round(Kirigami.Units.gridUnit * 0.7)
                                        elide: Text.ElideRight
                                    }
                                }
                            }

                            PlasmaComponents3.Button {
                                Layout.topMargin: Kirigami.Units.smallSpacing
                                text: i18n("Follow checked feeds")
                                icon.name: "list-add"
                                enabled: !sheet.adding
                                         && sheet.checkResults.filter(function (r) {
                                                return r.ok && !r.existing
                                            }).length > 0
                                onClicked: sheet.followChecked()
                            }
                        }

                        Rectangle {
                            Layout.fillWidth: true
                            implicitHeight: 1
                            Layout.topMargin: Kirigami.Units.smallSpacing
                            color: Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g,
                                           Kirigami.Theme.textColor.b, 0.1)
                        }

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: Kirigami.Units.smallSpacing
                            PlasmaComponents3.Button {
                                text: i18n("From OPML file…")
                                icon.name: "document-import"
                                onClicked: opmlDialog.open()
                            }
                            PlasmaComponents3.Button {
                                text: i18n("Save OPML file…")
                                icon.name: "document-save-as"
                                onClicked: {
                                    if (sheet.exportDir.length > 0)
                                        exportDialog.currentFolder = "file://" + sheet.exportDir
                                    exportDialog.open()
                                }
                            }
                            Item { Layout.fillWidth: true }
                        }

                        Text {
                            Layout.fillWidth: true
                            visible: sheet.opmlStatus.length > 0
                            text: sheet.opmlStatus
                            color: Kirigami.Theme.disabledTextColor
                            font.pixelSize: Math.round(Kirigami.Units.gridUnit * 0.7)
                            wrapMode: Text.WordWrap
                        }
                    }

                    // ------------------------------------------------------ backend
                    Section {
                        title: i18n("Backend")
                        summary: i18n("local service on this machine")

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: Kirigami.Units.smallSpacing
                            Rectangle {
                                implicitWidth: Kirigami.Units.smallSpacing * 1.6
                                implicitHeight: implicitWidth
                                radius: implicitWidth / 2
                                color: sheet.backendUp ? Kirigami.Theme.positiveTextColor
                                                       : Kirigami.Theme.negativeTextColor
                            }
                            Text {
                                Layout.fillWidth: true
                                text: sheet.backendUp ? i18n("Connected")
                                                      : i18n("Offline — start the knewsd service")
                                color: sheet.backendUp ? Kirigami.Theme.textColor
                                                       : Kirigami.Theme.negativeTextColor
                                font.pixelSize: Math.round(Kirigami.Units.gridUnit * 0.74)
                                elide: Text.ElideRight
                            }
                            PlasmaComponents3.Button {
                                text: i18n("Refresh now")
                                icon.name: "view-refresh"
                                enabled: sheet.backendUp
                                onClicked: sheet.refreshNowRequested()
                            }
                        }

                        Text {
                            Layout.fillWidth: true
                            text: i18n("Feeds refresh in the background every %1 minutes; "
                                       + "this list lives on this machine only.",
                                       Math.round(sheet.pref("refresh_minutes", 30)))
                            color: Kirigami.Theme.disabledTextColor
                            font.pixelSize: Math.round(Kirigami.Units.gridUnit * 0.68)
                            wrapMode: Text.WordWrap
                        }
                    }
                }
            }
        }
    }
}
