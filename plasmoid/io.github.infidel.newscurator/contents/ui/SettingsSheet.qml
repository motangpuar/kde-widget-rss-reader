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
    signal refreshNowRequested()
    signal importOpml(string text)
    signal feedsAdded(int added, int failed)
    signal deleteFeedRequested(int id)

    property string opmlStatus: ""
    property string exportStatus: ""

    // Bulk address validation: check every pasted line before adding anything.
    property var checkResults: []
    property bool checking: false
    property bool adding: false

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

    function exportToFile(url) {
        var path = url.toString().replace(/^file:\/\//, "")
        exportStatus = i18n("Writing %1…", path)
        Api.request("POST", "/api/opml/save", { "path": path }, function (status, data) {
            if (status === 200 && data) {
                sheet.exportStatus = i18n("Saved %1 feeds to %2", data.feeds, data.path)
                if (data.fallback)
                    sheet.exportStatus += " " + i18n("(that folder is not writable, so the "
                                                     + "export went to the app data folder)")
            } else
                sheet.exportStatus = (data && data.error) ? data.error
                                                          : i18n("Could not write that file.")
        })
    }

    function loadOpmlFile(url) {
        var path = url.toString()
        opmlStatus = i18n("Reading %1…", path.replace(/^file:\/\//, ""))
        var xhr = new XMLHttpRequest()
        xhr.onreadystatechange = function () {
            if (xhr.readyState !== XMLHttpRequest.DONE)
                return
            if (xhr.status !== 0 && xhr.status !== 200) {
                sheet.opmlStatus = i18n("Could not read that file.")
                return
            }
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
                            text: i18n("Local backend")
                            color: Kirigami.Theme.textColor
                            font.pixelSize: Math.round(Kirigami.Units.gridUnit * 0.78)
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
                            text: i18n("Save OPML file…")
                            icon.name: "document-save-as"
                            onClicked: {
                                if (sheet.exportDir.length > 0)
                                    exportDialog.currentFolder = "file://" + sheet.exportDir
                                exportDialog.open()
                            }
                        }
                        PlasmaComponents3.Button {
                            text: i18n("Import OPML file…")
                            icon.name: "document-import"
                            onClicked: opmlDialog.open()
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

                    Rectangle {
                        Layout.fillWidth: true
                        implicitHeight: 1
                        Layout.topMargin: Kirigami.Units.smallSpacing
                        color: Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g,
                                       Kirigami.Theme.textColor.b, 0.12)
                    }

                    Text {
                        Layout.fillWidth: true
                        text: i18n("Add several feeds")
                        color: Kirigami.Theme.textColor
                        font.bold: true
                        font.pixelSize: Math.round(Kirigami.Units.gridUnit * 0.85)
                        Layout.topMargin: Kirigami.Units.smallSpacing
                    }

                    Text {
                        Layout.fillWidth: true
                        text: i18n("Paste one address per line. Nothing is followed until you check it and confirm.")
                        color: Kirigami.Theme.disabledTextColor
                        font.pixelSize: Math.round(Kirigami.Units.gridUnit * 0.7)
                        wrapMode: Text.WordWrap
                    }

                    PlasmaComponents3.TextArea {
                        id: urlsArea
                        Layout.fillWidth: true
                        Layout.minimumHeight: Kirigami.Units.gridUnit * 4
                        placeholderText: "lwn.net/headlines/rss\nhttps://arstechnica.com/feed/\nexample.substack.com"
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
                                     && sheet.checkResults.filter(function (r) { return r.ok && !r.existing }).length > 0
                            onClicked: sheet.followChecked()
                        }
                    }
                }
            }
        }
    }
}
