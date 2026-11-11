.pragma library

// One source of truth for the reader's typography choices. Both the settings sheet and the
// reader's own menu build their dropdowns from these tables, so the two surfaces can never
// drift apart or offer a value the backend does not accept.

var THEMES = [
    { value: "auto", label: "Follow Plasma" },
    { value: "light", label: "Light" },
    { value: "sepia", label: "Sepia" },
    { value: "dark", label: "Dark" }
]

var SIZES = [80, 100, 115, 130, 145, 160]

var SPACING = [
    { value: 140, label: "Tight" },
    { value: 160, label: "Normal" },
    { value: 180, label: "Relaxed" },
    { value: 200, label: "Airy" }
]

var MARGINS = [
    { value: 60, label: "Narrow" },
    { value: 100, label: "Comfortable" },
    { value: 140, label: "Wide" },
    { value: 180, label: "Extra wide" }
]

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
