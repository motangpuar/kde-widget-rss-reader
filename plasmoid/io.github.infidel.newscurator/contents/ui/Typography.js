.pragma library

// One source of truth for the reader's typography choices: values, labels and the icon that
// describes each entry. The reader's Text menu is built from these tables, so a menu can never
// offer a value the backend does not accept, and no row falls back to its group's icon.

// Every entry carries the icon that describes the choice itself, so a menu row never shows the
// icon of its group. All names are Breeze names that exist at 22 px (checked on Fedora 44).
var THEMES = [
    { value: "auto", label: "Follow Plasma", icon: "color-management" },
    { value: "light", label: "Light", icon: "brightness-high" },
    { value: "sepia", label: "Sepia", icon: "image-x-generic" },
    { value: "dark", label: "Dark", icon: "brightness-low" }
]

var SIZES = [80, 100, 115, 130, 145, 160]

var SPACING = [
    { value: 140, label: "Tight", icon: "distribute-vertical-center" },
    { value: 160, label: "Normal", icon: "distribute-vertical-equal" },
    { value: 180, label: "Relaxed", icon: "distribute-vertical-gaps" },
    { value: 200, label: "Airy", icon: "distribute-vertical-margin" }
]

var MARGINS = [
    { value: 60, label: "Narrow", icon: "distribute-horizontal-left" },
    { value: 100, label: "Comfortable", icon: "distribute-horizontal-center" },
    { value: 140, label: "Wide", icon: "distribute-horizontal-margin" },
    { value: 180, label: "Extra wide", icon: "distribute-horizontal-equal" }
]

// Sizes show a direction icon: entries below the current value shrink the text, entries above
// grow it.
function sizeIcon(value, current) {
    return value < current ? "format-font-size-less" : "format-font-size-more"
}

// Ordered by preference; anything not installed is dropped before the list is shown.
var FONT_CANDIDATES = [
    "Atkinson Hyperlegible", "Noto Serif", "Noto Sans", "Source Serif 4", "Liberation Serif",
    "Liberation Sans", "DejaVu Serif", "DejaVu Sans", "Latin Modern Roman", "Cantarell",
    "Adwaita Sans", "Adwaita Mono", "Georgia", "Times New Roman", "Verdana"
]

function indexOfValue(entries, value) {
    for (var i = 0; i < entries.length; ++i)
        if (entries[i].value === value)
            return i
    return 0
}

function indexOfSize(value) {
    var at = SIZES.indexOf(value)
    return at < 0 ? 0 : at
}

// The first two entries keep the widget's own sans/serif default working without hardcoding a
// family that may not be installed.
function fontChoices(installed) {
    var out = [{ label: "System sans", family: "", serif: 0 },
               { label: "System serif", family: "", serif: 1 }]
    for (var i = 0; i < FONT_CANDIDATES.length; ++i) {
        var name = FONT_CANDIDATES[i]
        if (installed.indexOf(name) >= 0)
            out.push({ label: name, family: name, serif: 0 })
    }
    return out
}

function fontIndex(choices, family, serif) {
    family = family || ""
    var wantSerif = (Number(serif) | 0) === 1
    for (var i = 0; i < choices.length; ++i) {
        if (choices[i].family !== family)
            continue
        // A named family is never "system serif"; "" carries the flag instead.
        if (family.length > 0 ? choices[i].serif === 0 : choices[i].serif === (wantSerif ? 1 : 0))
            return i
    }
    return 0
}

// Same rule as fontIndex, expressed for a single entry so menu delegates need no index.
function isFontSelected(choice, family, serif) {
    family = family || ""
    if (choice.family !== family)
        return false
    if (family.length > 0)
        return true
    return choice.serif === ((Number(serif) | 0) === 1 ? 1 : 0)
}

function patchForFont(choice) {
    return { "font_family": choice.family, "serif": choice.serif }
}
