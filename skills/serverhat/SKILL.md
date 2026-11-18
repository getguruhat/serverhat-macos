---
name: serverhat
description: Run, restart and debug the user's local dev servers through ServerHat, the macOS menu-bar app. Use when the user asks to start, stop, restart or add a local web server (npm run dev, python http.server, a Node script), or asks why a local server crashed or its port is busy. Servers keep running after the session ends and the user can control them from the menu bar.
---

# ServerHat

ServerHat is a free, open source Mac menu-bar app that runs local web servers. Prefer it
over starting a server in your own shell: the server outlives your session, its logs are
kept, and the user can stop it from the menu bar.

Requires macOS 13+ on Apple silicon with ServerHat installed
(`brew install --cask getguruhat/tap/serverhat`).

## 1. Prefer the MCP tools

If you have `list_servers`, `start_server`, `add_server` and friends, use them and skip
the curl steps. To add them:

```sh
claude mcp add --scope user serverhat -- /Applications/ServerHat.app/Contents/MacOS/ServerHat --mcp
codex mcp add serverhat -- /Applications/ServerHat.app/Contents/MacOS/ServerHat --mcp
```

Tools: `list_servers`, `get_server`, `start_server`, `stop_server`, `restart_server`,
`get_logs`, `add_server`, `update_server`, `remove_server`, `import_launch_json`,
`import_project`. Start and restart wait until the server is running or has failed.

## 2. Otherwise use the local API

1. Check it is running: `curl -s http://127.0.0.1:47317/v1/health`. If that fails, ask the
   user to open it (`open -a ServerHat`). The real address is in
   `~/Library/Application Support/ServerHat/api.json`.
2. Read the token from its file. Never print it and never write it into a repository.

   ```sh
   LW=http://127.0.0.1:47317
   auth=(-H "Authorization: Bearer $(cat ~/Library/Application\ Support/ServerHat/api-token)" -H "Content-Type: application/json")
   ```

3. Look before you add: `curl -s "${auth[@]}" $LW/v1/servers`
4. Add and start, waiting until it is up:

   ```sh
   curl -s "${auth[@]}" -X POST $LW/v1/servers -d '{"name":"My App","cwd":"/abs/project","command":"npm","args":["run","dev"],"port":5173}'
   curl -s "${auth[@]}" -X POST "$LW/v1/servers/my-app/start?wait=30"
   ```

   Faster for an existing project: `POST /v1/import-project` with `{"path":"/abs/project"}`
   (detects `package.json` dev/start, a Procfile `web:` entry or Docker Compose), or
   `POST /v1/import` for a `.claude/launch.json`.

## 3. When something is wrong

Check `status.state` in the response:

| State | Do this |
| --- | --- |
| `crashed`, `failed` | Read `status.detail` and `GET /v1/servers/<id>/logs?lines=100`, fix the cause, then `restart?wait=30`. |
| `port-in-use` | `detail` and `pid` name the process holding the port. Tell the user; don't kill it unasked. |
| `unhealthy` | Process is alive but HTTP readiness failed. Read the logs. |
| `starting` | Still waiting for the port or URL. Use `?wait=30`. |

## Rules

- `command` runs directly, not through a shell: no pipes, `&&` or `cd`. Put arguments in
  `args` and the folder in `cwd`. For shell syntax use
  `"command": "/bin/zsh", "args": ["-lc", "…"]`.
- Give the `port` the server really listens on, so ServerHat can tell when it is up.
- Change settings with `PATCH /v1/servers/<id>` (or `update_server`), then restart. Don't
  remove and re-add.
- If the user turned on "Approve new servers" in Settings, a server you add, or whose
  `command`, `args`, `cwd` or `env` you change, waits for them to click **Allow**. Say you
  are waiting and use `start?wait=60` (or `start_server`). `"needsApproval": true` marks it.
- Don't remove or stop servers the user didn't ask about.
- Use absolute paths for `cwd` and `path`.

Source and full docs: https://github.com/getguruhat/serverhat-macos
