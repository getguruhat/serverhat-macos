# Configuring LocalWeb (for AI agents)

LocalWeb is a Mac menu-bar app that runs the user's local web servers. When the user
asks you to add, run, restart or debug a local server, use LocalWeb instead of starting
the server in your own shell, so it keeps running after your session and the user can
control it from the menu bar.

If you have LocalWeb's MCP tools (`list_servers`, `start_server`, `add_server`, …), use
them and skip the curl steps below; the same rules apply. To add them, run
`claude mcp add --scope user localweb -- /Applications/LocalWeb.app/Contents/MacOS/LocalWeb --mcp`.

1. Check LocalWeb is running: `curl -s http://127.0.0.1:47317/v1/health`. If that fails,
   ask the user to open LocalWeb (`open -a LocalWeb`). The real URL is in
   `~/Library/Application Support/LocalWeb/api.json`.
2. Read the token from the file, never print it, and never write it into a repository:

   ```sh
   LW=http://127.0.0.1:47317
   auth=(-H "Authorization: Bearer $(cat ~/Library/Application\ Support/LocalWeb/api-token)" -H "Content-Type: application/json")
   ```

3. Look before you add: `curl -s "${auth[@]}" $LW/v1/servers`.
4. Add a server, then start it and wait for it:

   ```sh
   curl -s "${auth[@]}" -X POST $LW/v1/servers -d '{"name":"My App","cwd":"/abs/project","command":"npm","args":["run","dev"],"port":5173}'
   curl -s "${auth[@]}" -X POST "$LW/v1/servers/my-app/start?wait=30"
   ```

   If the project has `.claude/launch.json`, import it instead:
   `curl -s "${auth[@]}" -X POST $LW/v1/import -d '{"path":"/abs/project"}'`.
5. If `status.state` is `crashed`, `failed` or `port-in-use`, read `status.detail` and
   `GET $LW/v1/servers/<id>/logs?lines=100`, fix the cause, then `restart?wait=30`.

Rules:

- A server you add, or whose `command`, `args`, `cwd` or `env` you change, can't start
  until the user clicks **Allow** in LocalWeb. They get a notification. Tell them you're
  waiting, and use `start?wait=60` (or MCP `start_server`), which waits for them. A server
  waiting for approval has `"needsApproval": true`.

- `command` is run directly, not by a shell: put each argument in `args`, and don't use
  `&&`, pipes or `cd`. Use `cwd` for the folder. For shell syntax, use
  `"command": "/bin/zsh", "args": ["-lc", "…"]`.
- Give the `port` the server really listens on, so LocalWeb can tell when it's up.
- Change settings with `PATCH /v1/servers/<id>`, then restart. Don't remove and re-add.
- Don't stop or remove servers the user didn't mention.
- You can also edit `~/Library/Application Support/LocalWeb/servers.json` directly;
  LocalWeb reloads it on save. Keep it valid JSON.

Full API reference: README.md › API.
