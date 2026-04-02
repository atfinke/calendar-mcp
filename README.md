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

`calendar_update_event` updates an event in place instead of forcing a delete-and-recreate flow. Omitted fields stay unchanged. To clear nullable fields, pass one of `clearLocation`, `clearNotes`, `clearUrl`, or `clearTimeZone`.

## Date Inputs

All tool date inputs accept these wire formats:

- `2026-04-02` for a local calendar day
- `2026-04-02T09:30` or `2026-04-02T09:30:00` for a local wall-clock time
- `2026-04-02T09:30:00-05:00` or `2026-04-02T14:30:00Z` for an exact instant

Local date-only and local date-time inputs are interpreted in the helper app's current macOS time zone. Returned event payloads always use ISO-8601 timestamps with timezone offsets.

`calendar_list_events` treats `start` and `end` as the exact time window after parsing those inputs.

`occurrenceDate` for recurring-event lookups also accepts `YYYY-MM-DD`. In that case the helper matches the occurrence by local calendar day. When you already have an `occurrenceDate` timestamp from a previous tool response, prefer passing that exact timestamp back.

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
