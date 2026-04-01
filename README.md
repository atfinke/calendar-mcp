# calendar-mcp

Local MCP server that exposes Apple Calendar data through an `EventKit` helper app.

Built entirely by OpenAI GPT-5.4 via Codex.

## Install

```bash
git clone https://github.com/<your-account>/calendar-mcp.git
cd calendar-mcp
./bootstrap.sh
```

## Run

```bash
npm run start
```

## Permissions

Run `calendar_permissions` once with `prompt: true` and `access: "full"`.

The helper app is intended to be built with the project’s normal code signing so macOS can attribute Calendar access to a stable app identity.

If the prompt does not appear from inside Codex, launch the helper app directly once:

```bash
open CalendarMCPHelperApp/build/Build/Products/Release/CalendarMCPHelperApp.app
```

When opened directly, the app will request Calendar access and show a status alert. After that initial grant, the MCP tools can read and write events normally.

Delete safety is intentionally narrow: each `calendar_delete_event` call can remove only one resolved target. Recurring deletes support one occurrence or one entire series, but not `futureEvents` or any bulk-delete shape.

## MCP config

```json
{
  "mcpServers": {
    "calendar": {
      "command": "node",
      "args": ["/absolute/path/to/calendar-mcp/dist/index.js"],
      "env": {
        "CALENDAR_MCP_HELPER_APP_PATH": "/absolute/path/to/calendar-mcp/CalendarMCPHelperApp/build/Build/Products/Release/CalendarMCPHelperApp.app"
      }
    }
  }
}
```

## Verify

```bash
npm run verify
```
