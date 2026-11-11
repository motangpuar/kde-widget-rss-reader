import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import org.kde.kirigami as Kirigami
import org.kde.plasma.components as PlasmaComponents3
import "Api.js" as Api

Item {
    id: sheet

    property var folders: []
    property string presetFolder: ""
    property var candidates: []
    property string selectedUrl: ""
    property string message: ""
    property bool busy: false
    property bool validated: false
    property bool validating: false
    property string validationText: ""
    property bool validationOk: false

    signal accepted(string url, string folder)
    signal cancelled()

    function reset() {
        candidates = []
        selectedUrl = ""
        message = ""
        busy = false
        validated = false
        validating = false
        validationText = ""
        validationOk = false
        urlField.text = ""
        folderField.text = presetFolder
    }

    // Strictly verify that the selected address is a usable feed *before* adding it,
    // so a follower never ends up with a dead or empty subscription.
    function validate() {
        if (!selectedUrl) {
            validationText = i18n("Pick a feed first.")
            validationOk = false
            validated = false
            return
        }
        validating = true
        validated = false
        validationText = i18n("Checking %1…", selectedUrl)
        validationOk = false
        Api.request("GET", "/api/validate?url=" + Api.encode(selectedUrl), null, function (status, data) {
            sheet.validating = false
            if (status !== 200 || !data) {
                sheet.validationText = i18n("Could not check that feed.")
                sheet.validationOk = false
                return
            }
            if (!data.ok) {
                sheet.validationText = i18n("Not usable: %1", data.error || i18n("unreachable"))
                sheet.validationOk = false
                return
            }
            sheet.validated = true
            sheet.validationOk = true
            sheet.validationText = data.empty
                    ? i18n("Valid feed, but it has no items yet: %1", data.title)
                    : i18n("%1 items available from %2", data.entries, data.title)
        })
    }

    onSelectedUrlChanged: {
        validated = false
        validationOk = false
        validationText = ""
        if (selectedUrl.length > 0)
            validate()
    }

    function discover() {
        var address = urlField.text.trim()
        if (!address) {
            message = i18n("Type a site or feed address first.")
            return
        }
        busy = true
        message = ""
        candidates = []
        selectedUrl = ""
        Api.request("GET", "/api/discover?url=" + Api.encode(address), null, function (status, data) {
            sheet.busy = false
            if (status !== 200 || !data) {
                sheet.message = i18n("Could not reach the backend.")
                return
            }
            sheet.candidates = data.candidates || []
            if (sheet.candidates.length > 0) {
                sheet.selectedUrl = sheet.candidates[0].url
                sheet.message = data.direct ? i18n("Feed address recognised.")
                                             : i18np("%1 feed found.", "%1 feeds found.",
                                                     sheet.candidates.length)
                if (sheet.candidates[0].existing)
                    sheet.message = i18n("Already in your feeds.")
            } else {
                sheet.message = data.message || i18n("No feed found at that address.")
            }
        })
    }

    function submit() {
        if (!selectedUrl || busy || !validated)
            return
        busy = true
        sheet.accepted(selectedUrl, folderField.text)
    }

    onVisibleChanged: {
        if (!visible) {
            reset()
        } else {
            folderField.text = presetFolder
            urlField.forceActiveFocus()
        }
    }

    Rectangle {
        anchors.fill: parent
        color: "black"
        opacity: 0.4
        MouseArea {
            anchors.fill: parent
            onClicked: sheet.cancelled()
        }
    }

    Rectangle {
        anchors.centerIn: parent
        width: Math.min(parent.width - Kirigami.Units.gridUnit * 2, Kirigami.Units.gridUnit * 30)
        implicitHeight: Math.min(parent.height - Kirigami.Units.gridUnit * 2,
                                 cardLayout.implicitHeight + Kirigami.Units.gridUnit * 2)
        radius: Kirigami.Units.smallSpacing
        color: Kirigami.Theme.backgroundColor
        border.width: 1
        border.color: Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g,
                              Kirigami.Theme.textColor.b, 0.15)

        ColumnLayout {
            id: cardLayout
            anchors.fill: parent
            anchors.margins: Kirigami.Units.gridUnit
            spacing: Kirigami.Units.smallSpacing

            Text {
                Layout.fillWidth: true
                text: i18n("Follow a site")
                color: Kirigami.Theme.textColor
                font.bold: true
                font.pixelSize: Math.round(Kirigami.Units.gridUnit * 1.1)
            }

            Text {
                Layout.fillWidth: true
                text: i18n("Type a website, feed, or channel address. News Curator searches the page for feeds you can follow.")
                color: Kirigami.Theme.disabledTextColor
                font.pixelSize: Math.round(Kirigami.Units.gridUnit * 0.72)
                wrapMode: Text.WordWrap
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing

                PlasmaComponents3.TextField {
                    id: urlField
                    Layout.fillWidth: true
                    placeholderText: "lwn.net, arstechnica.com, https://…/rss.xml"
                    focus: true
                    onAccepted: sheet.discover()
                }
                PlasmaComponents3.Button {
                    text: i18n("Find feeds")
                    icon.name: "search"
                    enabled: !sheet.busy && urlField.text.trim().length > 0
                    onClicked: sheet.discover()
                }
                PlasmaComponents3.BusyIndicator {
                    visible: sheet.busy
                    running: sheet.busy
                    implicitWidth: Kirigami.Units.gridUnit * 1.4
                    implicitHeight: Kirigami.Units.gridUnit * 1.4
                }
            }

            Text {
                Layout.fillWidth: true
                visible: sheet.message.length > 0
                text: sheet.message
                color: sheet.candidates.length > 0 ? Kirigami.Theme.disabledTextColor
                                                   : Kirigami.Theme.negativeTextColor
                font.pixelSize: Math.round(Kirigami.Units.gridUnit * 0.72)
                wrapMode: Text.WordWrap
            }

            Rectangle {
                Layout.fillWidth: true
                implicitHeight: results.implicitHeight
                visible: sheet.candidates.length > 0
                color: Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g,
                               Kirigami.Theme.textColor.b, 0.05)
                radius: Kirigami.Units.smallSpacing / 2
                border.width: 1
                border.color: Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g,
                                      Kirigami.Theme.textColor.b, 0.15)

                ColumnLayout {
                    id: results
                    width: parent.width
                    spacing: 0

                    Repeater {
                        model: sheet.candidates
                        delegate: Rectangle {
                            id: rowItem
                            Layout.fillWidth: true
                            implicitHeight: rowLayout.implicitHeight + Kirigami.Units.smallSpacing
                            color: sheet.selectedUrl === modelData.url
                                   ? Qt.rgba(Kirigami.Theme.highlightColor.r,
                                             Kirigami.Theme.highlightColor.g,
                                             Kirigami.Theme.highlightColor.b, 0.18)
                                   : "transparent"

                            RowLayout {
                                id: rowLayout
                                anchors.fill: parent
                                anchors.leftMargin: Kirigami.Units.smallSpacing
                                anchors.rightMargin: Kirigami.Units.smallSpacing
                                spacing: Kirigami.Units.smallSpacing

                                Image {
                                    source: modelData.icon || ""
                                    visible: source.toString().length > 0 && status === Image.Ready
                                    sourceSize.width: Kirigami.Units.iconSizes.small
                                    sourceSize.height: Kirigami.Units.iconSizes.small
                                    Layout.preferredWidth: Kirigami.Units.iconSizes.small
                                    Layout.preferredHeight: Kirigami.Units.iconSizes.small
                                    fillMode: Image.PreserveAspectFit
                                    smooth: true
                                }
                                Kirigami.Icon {
                                    visible: !modelData.icon
                                    source: modelData.existing ? "emblem-checked" : "application-rss+xml"
                                    implicitWidth: Kirigami.Units.iconSizes.small
                                    implicitHeight: Kirigami.Units.iconSizes.small
                                    color: Kirigami.Theme.textColor
                                }
                                ColumnLayout {
                                    Layout.fillWidth: true
                                    spacing: 0
                                    Text {
                                        Layout.fillWidth: true
                                        text: modelData.title || modelData.url
                                        color: Kirigami.Theme.textColor
                                        font.pixelSize: Math.round(Kirigami.Units.gridUnit * 0.78)
                                        elide: Text.ElideRight
                                    }
                                    Text {
                                        Layout.fillWidth: true
                                        text: modelData.existing
                                              ? i18n("Already followed: %1", modelData.url)
                                              : modelData.url
                                        color: Kirigami.Theme.disabledTextColor
                                        font.pixelSize: Math.round(Kirigami.Units.gridUnit * 0.66)
                                        elide: Text.ElideMiddle
                                    }
                                }
                            }

                            MouseArea {
                                anchors.fill: parent
                                onClicked: {
                                    sheet.selectedUrl = modelData.url
                                    if (modelData.existing)
                                        sheet.message = i18n("Already in your feeds.")
                                    else
                                        sheet.message = modelData.title || modelData.url
                                }
                            }
                        }
                    }
                }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing

                Kirigami.Icon {
                    source: sheet.validating ? "view-refresh"
                                             : (sheet.validationOk ? "dialog-ok-apply"
                                                                   : (sheet.validationText ? "dialog-error" : "help-hint"))
                    implicitWidth: Kirigami.Units.iconSizes.small
                    implicitHeight: Kirigami.Units.iconSizes.small
                    color: sheet.validationOk ? Kirigami.Theme.positiveTextColor
                                              : (sheet.validationText ? Kirigami.Theme.negativeTextColor
                                                                      : Kirigami.Theme.disabledTextColor)
                }
                Text {
                    Layout.fillWidth: true
                    text: sheet.validationText || i18n("Feeds are checked before they are added.")
                    color: sheet.validationOk ? Kirigami.Theme.positiveTextColor
                                              : (sheet.validationText ? Kirigami.Theme.negativeTextColor
                                                                      : Kirigami.Theme.disabledTextColor)
                    font.pixelSize: Math.round(Kirigami.Units.gridUnit * 0.72)
                    elide: Text.ElideRight
                }
                PlasmaComponents3.Button {
                    text: i18n("Validate")
                    icon.name: "dialog-ok-apply"
                    enabled: sheet.selectedUrl.length > 0 && !sheet.validating && !sheet.busy
                    onClicked: sheet.validate()
                }
            }

            PlasmaComponents3.TextField {
                id: folderField
                Layout.fillWidth: true
                placeholderText: i18n("Folder (optional), e.g. Tech")
                onAccepted: sheet.submit()
            }

            RowLayout {
                Layout.fillWidth: true
                Layout.topMargin: Kirigami.Units.smallSpacing
                spacing: Kirigami.Units.smallSpacing

                Item { Layout.fillWidth: true }

                PlasmaComponents3.Button {
                    text: i18n("Cancel")
                    onClicked: sheet.cancelled()
                }
                PlasmaComponents3.Button {
                    text: i18n("Follow")
                    icon.name: "list-add"
                    enabled: sheet.selectedUrl.length > 0 && !sheet.busy && sheet.validated
                    onClicked: sheet.submit()
                    PlasmaComponents3.ToolTip {
                        text: sheet.validated ? i18n("Add this feed")
                                              : i18n("Validate the feed before following it")
                    }
                }
            }
        }
    }
}
