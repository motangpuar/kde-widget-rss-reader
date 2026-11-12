import QtQuick
import org.kde.plasma.plasma5support as P5Support

// Attaches the widget to its backend: the widget is the supervisor, the daemon is a worker.
//
// contents/backend/bootstrap.sh does the work (install the zipapp, start/stop/restart it) and
// prints tokens we react to: BOOTSTRAP_STARTED/ALREADY, BOOTSTRAP_ENDPOINT <json>, BOOTSTRAP_STOPPED,
// BOOTSTRAP_FAILED, BOOTSTRAP_NO_PYTHON. Running it on every widget load is intentional and cheap:
// it asks /api/health first and only starts a process when nobody answers.
//
// The endpoint line matters in socket mode: QML cannot open unix sockets, so the daemon also
// keeps a loopback listener and publishes that port. The widget always talks HTTP over loopback;
// the configured transport is what other clients and tools use.
Item {
    id: launcher

    property int port: 8770
    // "port" (fixed loopback port) or "socket" (unix socket + published loopback port)
    property string connectionMode: "port"
    property string socketPath: ""

    // idle | starting | running | already | stopped | no-python | failed | missing
    property string state: "idle"
    property string detail: ""
    // Channel the widget itself must use, learned from the daemon.
    property int activePort: 0
    property string activeSocket: ""
    property string activeTransport: ""

    signal finished(string state)
    signal endpoint(int port, string socket, string transport)

    readonly property bool busy: exec.connectedSources.length > 0
    property var queue: []

    readonly property string scriptPath: {
        var url = Qt.resolvedUrl("../backend/bootstrap.sh").toString()
        if (url.indexOf("file://") === 0)
            url = url.substring(7)
        return decodeURIComponent(url)
    }

    function quote(text) {
        return "'" + String(text).replace(/'/g, "'\\''") + "'"
    }

    function endpointArgs() {
        if (connectionMode === "socket")
            return socketPath.length > 0 ? " --socket " + quote(socketPath) : " --socket ''"
        return " --port " + port
    }

    function start() { enqueue(endpointArgs()) }
    function restart() { enqueue(endpointArgs() + " --restart") }
    // Called when the widget is removed or the user asks for it. bootstrap.sh refuses to touch a
    // daemon it did not start (e.g. the systemd unit), so this is always safe to call.
    function stop() { enqueue(" --stop") }

    function enqueue(extra) {
        var command = "sh " + quote(scriptPath) + extra
        if (busy) {
            queue.push(command)
            return
        }
        run(command)
    }

    function run(command) {
        state = "starting"
        detail = ""
        exec.connectSource(command)
    }

    function parseEndpoint(out) {
        var marker = "BOOTSTRAP_ENDPOINT "
        var at = out.indexOf(marker)
        if (at < 0)
            return
        var line = out.substring(at + marker.length).split("\n")[0].trim()
        try {
            var data = JSON.parse(line)
            activePort = data.port > 0 ? data.port : 0
            activeSocket = data.socket || ""
            activeTransport = data.transport || ""
            endpoint(activePort, activeSocket, activeTransport)
        } catch (err) {
            console.warn("newscurator bootstrap: unparsable endpoint", line)
        }
    }

    function handle(stdout, exitCode, stderr) {
        var out = String(stdout || "")
        var err = String(stderr || "")
        parseEndpoint(out)
        if (out.indexOf("BOOTSTRAP_STOPPED") >= 0) {
            state = "stopped"
        } else if (out.indexOf("BOOTSTRAP_ALREADY") >= 0) {
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
        if (queue.length > 0) {
            var next = queue.shift()
            run(next)
        }
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
