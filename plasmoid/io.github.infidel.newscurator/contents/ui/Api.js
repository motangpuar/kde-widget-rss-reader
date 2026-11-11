.pragma library

var base = "http://127.0.0.1:8770"
var clientHeader = "plasma"

function setPort(port) {
    base = "http://127.0.0.1:" + (port || 8770)
}

function request(method, path, body, callback) {
    var xhr = new XMLHttpRequest()
    xhr.onreadystatechange = function () {
        if (xhr.readyState !== XMLHttpRequest.DONE)
            return
        var data = null
        try {
            data = JSON.parse(xhr.responseText)
        } catch (e) {
            data = null
        }
        callback(xhr.status, data, xhr.responseText)
    }
    xhr.open(method, base + path, true)
    xhr.setRequestHeader("X-Knews-Client", clientHeader)
    if (body !== null && body !== undefined)
        xhr.setRequestHeader("Content-Type", "application/json")
    xhr.timeout = 60000
    try {
        xhr.send(body === null || body === undefined ? null : JSON.stringify(body))
    } catch (e) {
        callback(0, null, String(e))
    }
}

function encode(value) {
    return encodeURIComponent(value === null || value === undefined ? "" : value)
}

function relativeTime(epoch) {
    if (!epoch || epoch <= 0)
        return ""
    var delta = Math.floor(Date.now() / 1000 - epoch)
    if (delta < 60)
        return "now"
    if (delta < 3600)
        return Math.floor(delta / 60) + "m"
    if (delta < 86400)
        return Math.floor(delta / 3600) + "h"
    if (delta < 604800)
        return Math.floor(delta / 86400) + "d"
    var d = new Date(epoch * 1000)
    var months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    var label = months[d.getMonth()] + " " + d.getDate()
    if (d.getFullYear() !== new Date().getFullYear())
        label += " " + d.getFullYear()
    return label
}

function longDate(epoch) {
    if (!epoch || epoch <= 0)
        return ""
    var d = new Date(epoch * 1000)
    var months = ["January", "February", "March", "April", "May", "June", "July",
                  "August", "September", "October", "November", "December"]
    var hh = d.getHours()
    var ampm = hh >= 12 ? "PM" : "AM"
    hh = hh % 12
    if (hh === 0)
        hh = 12
    var mm = d.getMinutes() < 10 ? "0" + d.getMinutes() : d.getMinutes()
    return months[d.getMonth()] + " " + d.getDate() + ", " + d.getFullYear() + " · " + hh + ":" + mm + " " + ampm
}

function readingTime(words) {
    if (!words || words <= 0)
        return ""
    return Math.max(1, Math.round(words / 220)) + " min read"
}

function escapeText(value) {
    return String(value === null || value === undefined ? "" : value)
        .replace(/&/g, "&amp;")
        .replace(/</g, "&lt;")
        .replace(/>/g, "&gt;")
}

// Convert structured runs into Qt StyledText markup (bold, italic, links, code).
function runsToStyledText(runs, linkColor) {
    if (!runs || !runs.length)
        return ""
    var out = []
    for (var i = 0; i < runs.length; ++i) {
        var run = runs[i]
        if (!run || !run.text)
            continue
        var text = escapeText(run.text)
        if (!text)
            continue
        text = text.replace(/\n/g, "<br/>")
        if (run.mono)
            text = "<span style=\"font-family:monospace\">" + text + "</span>"
        if (run.b)
            text = "<b>" + text + "</b>"
        if (run.i)
            text = "<i>" + text + "</i>"
        if (run.href)
            text = "<a href=\"" + escapeText(run.href) + "\" style=\"color:" + linkColor + ";text-decoration:none\">" + text + "</a>"
        out.push(text)
    }
    return out.join("")
}

function plainText(runs) {
    if (!runs || !runs.length)
        return ""
    var parts = []
    for (var i = 0; i < runs.length; ++i)
        parts.push(runs[i].text || "")
    return parts.join("").replace(/\s+/g, " ").trim()
}
