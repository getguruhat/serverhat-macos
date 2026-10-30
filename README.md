# LocalWeb

**Your local web servers, one click away in the Mac menu bar. Free and open source.**

No account, no analytics, nothing leaves your Mac.

LocalWeb starts, stops, restarts and opens the little web servers you run while you
work (a Node script, `npm run dev`, `python3 -m http.server`, anything with a command
line), so you never have to keep a Terminal tab open for them. It also has a local API,
so Claude Code, Codex or your own scripts can add and control servers for you.

## What it does

- A globe in the menu bar, with a list of your servers. Each shows whether it's
  **running**, **stopped**, **crashed** or has its **port in use**, and has Start/Stop,
  Restart, Open in browser and View logs. **Start all** and **Stop all** are at the top.
- Notices when a server crashes (and shows its last line of output) and when its port is
  already taken by something else (and which process that is).
- Keeps a log per server, in the app and in `~/Library/Logs/LocalWeb/<id>.log`.
- Stores everything in one readable JSON file and picks up edits to it immediately.
- Imports servers from Claude Code's `.claude/launch.json`.
- Runs commands with the same `PATH` your login shell sets up (Homebrew, nvm, and so on),
  in their own process group, so Stop also ends whatever the server started.
- Quitting LocalWeb stops the servers it started.

## Download

### macOS (13+, Apple silicon)

Download `LocalWeb-<version>-Installer.dmg` from the [latest release](../../releases/latest),
open it, and drag `LocalWeb.app` onto Applications. The app isn't notarized yet, so
approve **Open Anyway** in System Settings › Privacy & Security the first time.

## The config file

`~/Library/Application Support/LocalWeb/servers.json`:

```json
{
  "servers" : [
    {
      "args" : ["ai-experts/server.mjs"],
      "command" : "node",
      "cwd" : "~/Desktop/Codex",
      "env" : {},
      "id" : "ai-experts",
      "name" : "AI Experts",
      "port" : 4319,
      "startAtLogin" : false,
      "url" : "http://127.0.0.1:4319"
    }
  ],
  "version" : 1
}
```

| Field | Required | Meaning |
| --- | --- | --- |
| `id` | no | Short unique name used by the API and for the log file. Made from `name` if left out. |
| `name` | yes | What the menu shows. |
| `cwd` | no | Folder the command runs in. `~` works. Defaults to your home folder. |
| `command` | yes | A program on your shell's `PATH` (`node`, `npm`, `python3`) or a path to one. It is run directly, not through a shell, so no pipes or `&&`. |
| `args` | no | Arguments, one string each. |
| `port` | no | The port the server listens on. LocalWeb uses it to tell "starting" from "running" and to detect a port that's already in use. |
| `url` | no | What Open in browser opens. Defaults to `http://127.0.0.1:<port>`. |
| `env` | no | Extra environment variables, `{"NAME": "value"}`. |
| `startAtLogin` | no | Start this server whenever LocalWeb starts. Turn on **Open LocalWeb at login** (in the server's Edit window) to have that happen at login. |

Save the file and LocalWeb reloads it within a second. If the JSON is broken, the menu
says where, and the last good settings stay in use. A server that's running keeps its old
settings until you restart it. Removing a server from the file stops it.

## Import from `.claude/launch.json`

Choose the import button (the tray with an arrow) and pick a project folder or its
`.claude/launch.json`. Each configuration
(`{name, runtimeExecutable, runtimeArgs, port, url}`) becomes a server that runs from the
project folder. Configurations that are already in LocalWeb are skipped.

## API

LocalWeb listens on `http://127.0.0.1:47317` (only on this Mac). Change the port with
`defaults write com.guruhat.localweb apiPort -int 47400` and restart LocalWeb.

`~/Library/Application Support/LocalWeb/api.json` says where the API is and where its
token is:

```json
{ "url": "http://127.0.0.1:47317", "tokenFile": "~/Library/Application Support/LocalWeb/api-token", "configFile": "…/servers.json" }
```

### Security

- Every request except `GET /v1/health` needs `Authorization: Bearer <token>`. The token
  is created on first launch in `api-token`, readable only by you (mode 600, in a folder
  with mode 700). Delete the file and restart LocalWeb to get a new one.
- The `Host` header must be `127.0.0.1:<port>` or `localhost:<port>`, which blocks DNS
  rebinding.
- Requests that carry an `Origin` header, or a `Sec-Fetch-Site` other than `none`, are
  refused, and CORS preflights are refused, so web pages can't use the API.
- Request bodies must be JSON with `Content-Type: application/json`, at most 1 MB.

Anyone holding the token can run commands as you, which is what the API is for. Keep it
out of repositories and logs.

### Setup for the examples

```sh
LW=http://127.0.0.1:47317
TOKEN=$(cat ~/Library/Application\ Support/LocalWeb/api-token)
auth=(-H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json")
```

### Endpoints

| Method and path | Does |
| --- | --- |
| `GET /v1/health` | `{"ok": true}` without a token; shows LocalWeb is running. |
| `GET /v1/servers` | All servers with their status. |
| `POST /v1/servers` | Add a server. Body: the fields above. Returns it with `201`, or `409` if the id is taken. |
| `GET /v1/servers/{id}` | One server with its status. |
| `PATCH /v1/servers/{id}` | Change some fields. `null` clears `port` or `url`. |
| `PUT /v1/servers/{id}` | Replace all fields. |
| `DELETE /v1/servers/{id}` | Stop and remove a server. |
| `POST /v1/servers/{id}/start` | Start it. `409` if its port is already in use. |
| `POST /v1/servers/{id}/stop` | Stop it (SIGTERM to its process group, SIGKILL after 5 s). |
| `POST /v1/servers/{id}/restart` | Stop it, then start it again. |
| `GET /v1/servers/{id}/logs?lines=200` | The last lines of its output (up to 5000), plus the log file path. |
| `POST /v1/start-all`, `POST /v1/stop-all` | Start or stop every server. |
| `POST /v1/import` | Body `{"path": "<project folder or launch.json>"}`. Returns `{"added": [...]}`. |
| `POST /v1/reload` | Re-read `servers.json` now. |

Add `?wait=<seconds>` (up to 60) to start, stop and restart to get the answer once the
server is running, stopped or has failed, instead of right away.

Each server in a response has its settings plus:

```json
"status": { "state": "running", "pid": 8101, "startedAt": "2026-10-30T23:06:47Z" },
"log": "/Users/you/Library/Logs/LocalWeb/ai-experts.log",
"openURL": "http://127.0.0.1:4319"
```

`state` is one of `stopped`, `starting` (launched, port not open yet), `running`,
`stopping`, `crashed` (exited with an error; see `detail` and `exitCode`), `port-in-use`
(something else holds the port; `detail` and `pid` name it) or `failed` (couldn't be
launched, for example command not found). Errors come back as `{"error": "…"}` with a
4xx status.

### Examples

```sh
# Add a server and start it, waiting until it's listening
curl -s "${auth[@]}" -X POST $LW/v1/servers -d '{
  "name": "Docs preview", "cwd": "~/code/docs", "command": "npm",
  "args": ["run", "dev"], "port": 5173, "env": {"BROWSER": "none"}
}'
curl -s "${auth[@]}" -X POST "$LW/v1/servers/docs-preview/start?wait=30"

# What's running?
curl -s "${auth[@]}" $LW/v1/servers

# Why did it crash?
curl -s "${auth[@]}" "$LW/v1/servers/docs-preview/logs?lines=50"

# Change the port, then restart
curl -s "${auth[@]}" -X PATCH $LW/v1/servers/docs-preview -d '{"port": 5174}'
curl -s "${auth[@]}" -X POST "$LW/v1/servers/docs-preview/restart?wait=30"

# Import a project's .claude/launch.json
curl -s "${auth[@]}" -X POST $LW/v1/import -d '{"path": "~/code/docs"}'
```

## Build from source

Requires macOS 13 or later and Swift 5.9 or later (Xcode or the Command Line Tools).

```sh
./build-app.sh            # builds LocalWeb.app and LocalWeb-Installer.dmg
./build-app.sh --no-dmg   # just the app
open LocalWeb.app
```

`swift make-icon.swift` redraws `icon.png` and `AppIcon.icns`.

The code is in `Sources/LocalWeb/`:

- `Config.swift`: the servers.json format, the file watcher, and the launch.json importer.
- `ServerManager.swift`: starting and stopping processes, logs, crash and port detection.
- `APIServer.swift`: the local HTTP API.
- `main.swift`: the menu, the log, edit and About windows.

## Support

LocalWeb is free. If it saves you time, you can
[support GuruHat with a donation](https://www.paypal.com/donate/?hosted_button_id=FHGYWD46722JS).

## License

MIT. See [LICENSE](LICENSE).
