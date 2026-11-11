import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import org.kde.kirigami as Kirigami
import org.kde.plasma.components as PlasmaComponents3
import "Api.js" as Api
import "Typography.js" as Typography

Item {
    id: reader

    property var article: null
    property int lastItemId: 0
    property color readBg: Kirigami.Theme.backgroundColor
    property color readFg: Kirigami.Theme.textColor
    property color readLink: Kirigami.Theme.linkColor
    property string bodyFamily: "Noto Sans"
    property int bodyFontSize: 14
    property int lineHeightPercent: 160
    property int paddingPercent: 100
    property string themeName: "auto"
    property bool compactMode: false
    property string feedTitle: ""
    property string feedIcon: ""
    // Reader typography is edited from the toolbar menu and written to the same prefs as the
    // settings sheet, so neither surface can drift.
    property var prefs: ({})
    readonly property var fonts: Typography.fontChoices(Qt.fontFamilies())

    signal closed()
    signal starToggled(int id, bool starred)
    signal openExternal(string url)
    signal reextractRequested()
    signal fontScaleChanged(int delta)
    signal prefsEdited(var values)

    readonly property real maxTextWidth: Math.min(Math.max(width - Kirigami.Units.gridUnit * 3, 200),
                                                  Kirigami.Units.gridUnit * 34)
    // The padding setting scales the side margin, so wider padding reads as a narrower column
    // and narrow padding lets the text use more of the width.
    readonly property real basePadding: Math.max(Kirigami.Units.smallSpacing, (width - maxTextWidth) / 2)
    readonly property real sidePadding: Math.min(width / 2 - Kirigami.Units.gridUnit,
                                                 Math.max(Kirigami.Units.smallSpacing * 2,
                                                          basePadding * paddingPercent / 100))
    readonly property real columnWidth: Math.max(Kirigami.Units.gridUnit * 10, width - sidePadding * 2)
    readonly property real progress: {
        if (!flick.contentHeight || flick.contentHeight <= flick.height)
            return 1
        return Math.max(0, Math.min(1, flick.contentY / (flick.contentHeight - flick.height)))
    }

    function blockFor(loader) {
        var data = loader ? loader.blockData : undefined
        return data === undefined || data === null ? ({}) : data
    }

    function componentFor(kind) {
        switch (kind) {
        case "paragraph": return paragraphComponent
        case "heading": return headingComponent
        case "image": return imageComponent
        case "list": return listComponent
        case "quote": return quoteComponent
        case "code": return codeComponent
        case "divider": return dividerComponent
        default: return null
        }
    }

    Rectangle {
        anchors.fill: parent
        color: reader.readBg
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // ------------------------------------------------------------ toolbar
        RowLayout {
            Layout.fillWidth: true
            Layout.margins: Kirigami.Units.smallSpacing
            spacing: Kirigami.Units.smallSpacing / 2

            PlasmaComponents3.ToolButton {
                icon.name: "go-previous"
                display: AbstractButton.IconOnly
                onClicked: reader.closed()
                PlasmaComponents3.ToolTip { text: i18n("Back to list") }
            }

            // The header names the source and shows its favicon, so the reader says where the
            // article came from without a trip back to the list.
            RowLayout {
                Layout.fillWidth: true
                spacing: Math.round(Kirigami.Units.smallSpacing * 0.6)

                Kirigami.Icon {
                    source: reader.feedIcon.length > 0 ? reader.feedIcon : "application-rss+xml"
                    implicitWidth: Math.round(Kirigami.Units.gridUnit * 0.8)
                    implicitHeight: implicitWidth
                    Layout.alignment: Qt.AlignVCenter
                }

                Text {
                    Layout.fillWidth: true
                    text: reader.feedTitle
                    color: Qt.rgba(reader.readFg.r, reader.readFg.g, reader.readFg.b, 0.75)
                    font.pixelSize: Math.round(Kirigami.Units.gridUnit * 0.72)
                    elide: Text.ElideRight
                }
            }

            PlasmaComponents3.ToolButton {
                icon.name: reader.article && reader.article.starred === 1 ? "rating" : "rating-unrated"
                display: AbstractButton.IconOnly
                enabled: !!reader.article
                onClicked: reader.starToggled(reader.article.id, reader.article.starred === 1)
                PlasmaComponents3.ToolTip { text: i18n("Toggle star") }
            }
            PlasmaComponents3.ToolButton {
                icon.name: "view-refresh"
                display: AbstractButton.IconOnly
                enabled: !!reader.article
                onClicked: reader.reextractRequested()
                PlasmaComponents3.ToolTip { text: i18n("Re-extract full article") }
            }
            PlasmaComponents3.ToolButton {
                visible: !reader.compactMode
                icon.name: "zoom-out"
                display: AbstractButton.IconOnly
                onClicked: reader.fontScaleChanged(-10)
                PlasmaComponents3.ToolTip { text: i18n("Smaller text") }
            }
            PlasmaComponents3.ToolButton {
                visible: !reader.compactMode
                icon.name: "zoom-in"
                display: AbstractButton.IconOnly
                onClicked: reader.fontScaleChanged(10)
                PlasmaComponents3.ToolTip { text: i18n("Larger text") }
            }
            // Kept last: it is the least used control but the only way to reach the other four.
            PlasmaComponents3.ToolButton {
                id: lookButton
                objectName: "look-button"
                icon.name: "preferences-desktop-font"
                text: i18n("Text")
                display: reader.compactMode ? AbstractButton.IconOnly
                                            : AbstractButton.TextBesideIcon
                onClicked: lookMenu.popup(lookButton, 0, lookButton.height)
                PlasmaComponents3.ToolTip { text: i18n("Text appearance") }

                PlasmaComponents3.Menu {
                    id: lookMenu

                    // Each group is a submenu: a Menu nested in a Menu shows its title and icon
                    // on the parent row, so the group labels carry icons too.
                    PlasmaComponents3.Menu {
                        title: i18n("Reading theme (%1)", reader.themeName)
                        icon.name: "preferences-desktop-theme"
                        Repeater {
                            model: Typography.THEMES
                            delegate: PlasmaComponents3.MenuItem {
                                required property var modelData

                                text: i18n(modelData.label)
                                icon.name: (reader.prefs.reader_theme || "auto")
                                           === modelData.value
                                           ? "checkmark" : "preferences-desktop-theme"
                                onTriggered: reader.prefsEdited(
                                                 { "reader_theme": modelData.value })
                            }
                        }
                    }

                    PlasmaComponents3.Menu {
                        title: i18n("Font")
                        icon.name: "preferences-desktop-font"
                        Repeater {
                            model: reader.fonts
                            delegate: PlasmaComponents3.MenuItem {
                                required property var modelData

                                text: modelData.family.length > 0
                                      ? modelData.family : i18n(modelData.label)
                                icon.name: Typography.isFontSelected(
                                                   modelData,
                                                   reader.prefs.font_family || "",
                                                   reader.prefs.serif || 0)
                                           ? "checkmark" : "preferences-desktop-font"
                                onTriggered: reader.prefsEdited(
                                                 Typography.patchForFont(modelData))
                            }
                        }
                    }

                    PlasmaComponents3.Menu {
                        title: i18n("Size (%1%)", reader.prefs.font_scale || 100)
                        icon.name: "zoom-in"
                        Repeater {
                            model: Typography.SIZES
                            delegate: PlasmaComponents3.MenuItem {
                                required property var modelData

                                text: modelData + "%"
                                icon.name: (reader.prefs.font_scale || 100) === modelData
                                           ? "checkmark" : "zoom-in"
                                onTriggered: reader.prefsEdited({ "font_scale": modelData })
                            }
                        }
                    }

                    PlasmaComponents3.Menu {
                        title: i18n("Line spacing")
                        icon.name: "view-sort-ascending"
                        Repeater {
                            model: Typography.SPACING
                            delegate: PlasmaComponents3.MenuItem {
                                required property var modelData

                                text: i18n(modelData.label)
                                icon.name: (reader.prefs.line_height || 160)
                                           === modelData.value
                                           ? "checkmark" : "view-sort-ascending"
                                onTriggered: reader.prefsEdited(
                                                 { "line_height": modelData.value })
                            }
                        }
                    }

                    PlasmaComponents3.Menu {
                        title: i18n("Margins")
                        icon.name: "zoom-fit-best"
                        Repeater {
                            model: Typography.MARGINS
                            delegate: PlasmaComponents3.MenuItem {
                                required property var modelData

                                text: i18n(modelData.label)
                                icon.name: (reader.prefs.reader_padding || 100)
                                           === modelData.value
                                           ? "checkmark" : "zoom-fit-best"
                                onTriggered: reader.prefsEdited(
                                                 { "reader_padding": modelData.value })
                            }
                        }
                    }
                }
            }

            PlasmaComponents3.ToolButton {
                icon.name: "internet-services"
                display: AbstractButton.IconOnly
                enabled: !!reader.article && !!reader.article.url
                onClicked: reader.openExternal(reader.article.url)
                PlasmaComponents3.ToolTip { text: i18n("Open in browser") }
            }
        }

        Rectangle {
            Layout.fillWidth: true
            implicitHeight: 2
            color: Qt.rgba(reader.readFg.r, reader.readFg.g, reader.readFg.b, 0.12)
            Rectangle {
                height: parent.height
                width: parent.width * reader.progress
                color: Kirigami.Theme.highlightColor
            }
        }

        Flickable {
            id: flick
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            contentWidth: width
            contentHeight: contentColumn.implicitHeight + Kirigami.Units.gridUnit * 4
            boundsBehavior: Flickable.StopAtBounds
            flickableDirection: Flickable.VerticalFlick
            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

            ColumnLayout {
                id: contentColumn
                x: reader.sidePadding
                y: Kirigami.Units.gridUnit * 1.5
                width: reader.columnWidth
                spacing: Math.round(reader.bodyFontSize * 0.95 * reader.lineHeightPercent / 160)

                Text {
                    Layout.fillWidth: true
                    text: reader.article ? reader.article.title : ""
                    color: reader.readFg
                    font.family: reader.bodyFamily
                    font.pixelSize: Math.round(reader.bodyFontSize * 1.85)
                    font.weight: Font.Bold
                    wrapMode: Text.WordWrap
                }

                Text {
                    Layout.fillWidth: true
                    visible: text.length > 0
                    text: {
                        if (!reader.article)
                            return ""
                        var parts = []
                        if (reader.article.author)
                            parts.push(reader.article.author)
                        if (reader.article.published)
                            parts.push(Api.longDate(reader.article.published))
                        if (reader.article.word_count)
                            parts.push(Api.readingTime(reader.article.word_count))
                        return parts.join(" · ")
                    }
                    color: Qt.rgba(reader.readFg.r, reader.readFg.g, reader.readFg.b, 0.65)
                    font.family: reader.bodyFamily
                    font.pixelSize: Math.round(reader.bodyFontSize * 0.78)
                    wrapMode: Text.WordWrap
                }

                Rectangle {
                    Layout.fillWidth: true
                    Layout.topMargin: Kirigami.Units.smallSpacing
                    Layout.bottomMargin: Kirigami.Units.smallSpacing
                    implicitHeight: 1
                    color: Qt.rgba(reader.readFg.r, reader.readFg.g, reader.readFg.b, 0.15)
                }

                Repeater {
                    model: reader.article && reader.article.blocks ? reader.article.blocks : []
                    delegate: Loader {
                        property var blockData: modelData
                        Layout.fillWidth: true
                        sourceComponent: reader.componentFor(modelData.type)
                    }
                }

                Text {
                    Layout.fillWidth: true
                    Layout.topMargin: Kirigami.Units.gridUnit
                    visible: text.length > 0
                    text: reader.article && reader.article.extract_state === "failed"
                          ? i18n("Full text could not be extracted — open in browser to read the original.")
                          : reader.article && reader.article.extract_state === "partial"
                            ? i18n("Partial extraction. Open in browser for the complete article.")
                            : ""
                    color: Qt.rgba(reader.readFg.r, reader.readFg.g, reader.readFg.b, 0.6)
                    font.family: reader.bodyFamily
                    font.pixelSize: Math.round(reader.bodyFontSize * 0.8)
                    wrapMode: Text.WordWrap
                }

                Item { implicitHeight: Kirigami.Units.gridUnit }
            }
        }
    }

    PlasmaComponents3.BusyIndicator {
        anchors.centerIn: parent
        visible: reader.lastItemId > 0 && !reader.article
        running: visible
    }

    // ------------------------------------------------------------- block types
    component BlockParagraph: Text {
        readonly property var block: reader.blockFor(parent)
        width: parent ? parent.width : 0
        textFormat: Text.StyledText
        text: Api.runsToStyledText(block.runs, reader.readLink)
        color: reader.readFg
        font.family: reader.bodyFamily
        font.pixelSize: reader.bodyFontSize
        lineHeight: reader.lineHeightPercent / 100
        lineHeightMode: Text.ProportionalHeight
        wrapMode: Text.Wrap
        onLinkActivated: (link) => reader.openExternal(link)
    }

    component BlockHeading: Text {
        readonly property var block: reader.blockFor(parent)
        width: parent ? parent.width : 0
        text: block.text || ""
        textFormat: Text.PlainText
        color: reader.readFg
        font.family: reader.bodyFamily
        font.bold: true
        font.pixelSize: Math.round(reader.bodyFontSize * (block.level <= 2 ? 1.45 : 1.2))
        wrapMode: Text.Wrap
        topPadding: reader.bodyFontSize * 0.4
    }

    component BlockImage: Column {
        readonly property var block: reader.blockFor(parent)
        width: parent ? parent.width : 0
        spacing: Kirigami.Units.smallSpacing / 2

        Rectangle {
            width: parent.width
            implicitHeight: imageItem.status === Image.Ready && imageItem.implicitWidth > 0
                            ? Math.min(parent.width * imageItem.implicitHeight / imageItem.implicitWidth,
                                       Kirigami.Units.gridUnit * 30)
                            : Math.round(parent.width * 0.45)
            color: Qt.rgba(reader.readFg.r, reader.readFg.g, reader.readFg.b, 0.07)
            radius: Kirigami.Units.smallSpacing / 2
            clip: true

            Image {
                id: imageItem
                anchors.fill: parent
                anchors.margins: 1
                source: block.src || ""
                asynchronous: true
                cache: true
                fillMode: Image.PreserveAspectFit
            }
        }

        Text {
            width: parent.width
            visible: (block.caption || block.alt || "").length > 0
            text: block.caption || block.alt || ""
            color: Qt.rgba(reader.readFg.r, reader.readFg.g, reader.readFg.b, 0.55)
            font.family: reader.bodyFamily
            font.pixelSize: Math.round(reader.bodyFontSize * 0.75)
            font.italic: true
            wrapMode: Text.Wrap
            horizontalAlignment: Text.AlignHCenter
        }
    }

    component BlockList: ColumnLayout {
        readonly property var block: reader.blockFor(parent)
        spacing: Math.round(reader.bodyFontSize * 0.35)

        Repeater {
            model: block.items || []
            delegate: RowLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing

                Text {
                    Layout.alignment: Qt.AlignTop
                    text: block.ordered ? (index + 1) + "." : "•"
                    color: reader.readFg
                    font.family: reader.bodyFamily
                    font.pixelSize: reader.bodyFontSize
                    font.bold: block.ordered
                }

                Text {
                    Layout.fillWidth: true
                    textFormat: Text.StyledText
                    text: Api.runsToStyledText(modelData, reader.readLink)
                    color: reader.readFg
                    font.family: reader.bodyFamily
                    font.pixelSize: reader.bodyFontSize
                    lineHeight: reader.lineHeightPercent / 100
                    lineHeightMode: Text.ProportionalHeight
                    wrapMode: Text.Wrap
                    onLinkActivated: (link) => reader.openExternal(link)
                }
            }
        }
    }

    component BlockQuote: RowLayout {
        readonly property var block: reader.blockFor(parent)
        spacing: Kirigami.Units.gridUnit * 0.6

        Rectangle {
            Layout.fillHeight: true
            implicitWidth: 3
            color: Kirigami.Theme.highlightColor
            opacity: 0.6
        }

        Text {
            Layout.fillWidth: true
            textFormat: Text.StyledText
            text: Api.runsToStyledText(block.runs, reader.readLink)
            color: Qt.rgba(reader.readFg.r, reader.readFg.g, reader.readFg.b, 0.85)
            font.family: reader.bodyFamily
            font.italic: true
            font.pixelSize: Math.round(reader.bodyFontSize * 1.05)
            lineHeight: reader.lineHeightPercent / 100
            lineHeightMode: Text.ProportionalHeight
            wrapMode: Text.Wrap
            onLinkActivated: (link) => reader.openExternal(link)
        }
    }

    component BlockCode: Rectangle {
        readonly property var block: reader.blockFor(parent)
        width: parent ? parent.width : 0
        implicitHeight: codeText.contentHeight + Kirigami.Units.smallSpacing * 2
        color: Qt.rgba(reader.readFg.r, reader.readFg.g, reader.readFg.b, 0.07)
        radius: Kirigami.Units.smallSpacing / 2

        TextEdit {
            id: codeText
            x: Kirigami.Units.smallSpacing
            y: Kirigami.Units.smallSpacing
            width: parent.width - Kirigami.Units.smallSpacing * 2
            height: Math.max(contentHeight, 1)
            text: block.text || ""
            readOnly: true
            selectByMouse: true
            wrapMode: TextEdit.Wrap
            color: reader.readFg
            font.family: "monospace"
            font.pixelSize: Math.round(reader.bodyFontSize * 0.85)
            selectionColor: Kirigami.Theme.highlightColor
        }
    }

    component BlockDivider: Item {
        readonly property var block: reader.blockFor(parent)
        width: parent ? parent.width : 0
        implicitHeight: Math.round(reader.bodyFontSize * 1.6)
        Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width * 0.35
            height: 1
            color: Qt.rgba(reader.readFg.r, reader.readFg.g, reader.readFg.b, 0.2)
        }
    }

    Component { id: paragraphComponent; BlockParagraph {} }
    Component { id: headingComponent; BlockHeading {} }
    Component { id: imageComponent; BlockImage {} }
    Component { id: listComponent; BlockList {} }
    Component { id: quoteComponent; BlockQuote {} }
    Component { id: codeComponent; BlockCode {} }
    Component { id: dividerComponent; BlockDivider {} }
}
