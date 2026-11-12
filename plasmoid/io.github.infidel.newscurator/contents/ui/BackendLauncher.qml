import QtQuick
import org.kde.plasma.plasma5support as P5Support

// Starts the bundled backend when the widget is added from a package (store install), so a
// single .plasmoid is a complete installation: no installer script, no systemd unit, no checkout.
//
// contents/backend/bootstrap.sh does the work (copy the zipapp, write the autostart entry, spawn
// it) and prints exactly one BOOTSTRAP_* token we can react to. Running it on every widget load
// is intentional and cheap: it answers /api/health first and exits when a backend already runs.
Item {
    id: launcher

    property int port: 8770
    // idle | starting | running | already | no-python | failed | missing
    property string state: "idle"
    property string detail: ""

    signal finished(string state)

    readonly property string scriptPath: {
        var url = Qt.resolvedUrl("../backend/bootstrap.sh").toString()
        if (url.indexOf("file://") === 0)
            url = url.substring(7)
        return decodeURIComponent(url)
    }

    readonly property string command: "sh '" + scriptPath.replace(/'/g, "'\\''") + "' --port " + port

    function start() {
        if (exec.connectedSources.length > 0)
            return
        state = "starting"
        detail = ""
        exec.connectSource(command)
    }

    function handle(stdout, exitCode, stderr) {
        var out = String(stdout || "")
        var err = String(stderr || "")
        if (out.indexOf("BOOTSTRAP_ALREADY") >= 0) {
            state = "already"
        } else if (out.indexOf("BOOTSTRAP_STARTED") >= 0) {
            state = "running"
        } else if (out.indexOf("BOOTSTRAP_NO_PYTHON") >= 0) {
            state = "no-python"
        } else if (exitCode === 3 || out.indexOf("missing at") >= 0) {
            state = "missing"
        } else if (exitCode === 0) {
            state = "already"
        } else {
            state = "failed"
        }
        detail = (err.length > 0 ? err : out).trim()
        console.info("newscurator bootstrap:", state, "|", detail)
        finished(state)
    }

    P5Support.DataSource {
        id: exec
        engine: "executable"
        connectedSources: []

        onNewData: (sourceName, data) => {
            var stdout = data["stdout"] || ""
            var stderr = data["stderr"] || ""
            var code = data["exit code"]
            exec.disconnectSource(sourceName)
            launcher.handle(stdout, code, stderr)
        }
    }
}
