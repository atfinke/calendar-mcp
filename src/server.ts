import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";

import { ensureHelperExists, jsonTextResult, runHelper } from "./helper.js";

const eventLookupInputSchema = {
  eventIdentifier: z.string().optional(),
  calendarItemIdentifier: z.string().optional(),
  externalIdentifier: z.string().optional(),
  occurrenceDate: z.string().optional(),
};

export function createServer(): McpServer {
  const server = new McpServer({
    name: "calendar-mcp",
    version: "0.1.0",
  });

  server.registerTool(
    "calendar_permissions",
    {
      title: "Calendar Permissions",
      description: "Check and optionally prompt for Apple Calendar access used by the helper app.",
      inputSchema: {
        prompt: z.boolean().optional(),
        access: z.enum(["full", "writeOnly"]).optional(),
      },
    },
    async ({ prompt, access }) => {
      await ensureHelperExists();
      const result = await runHelper("permissions", {
        prompt: prompt ?? false,
        access: access ?? "full",
      });

      return jsonTextResult(result);
    },
  );

  server.registerTool(
    "calendar_list_calendars",
    {
      title: "List Calendars",
      description: "List event calendars available to the helper app.",
      annotations: {
        readOnlyHint: true,
      },
      inputSchema: {},
    },
    async () => {
      await ensureHelperExists();
      const result = await runHelper("list-calendars");
      return jsonTextResult(result);
    },
  );

  server.registerTool(
    "calendar_list_events",
    {
      title: "List Events",
      description: "List calendar events in a time window, optionally filtered to specific calendar identifiers.",
      annotations: {
        readOnlyHint: true,
      },
      inputSchema: {
        start: z.string(),
        end: z.string(),
        calendarIds: z.array(z.string()).optional(),
      },
    },
    async ({ start, end, calendarIds }) => {
      await ensureHelperExists();
      const result = await runHelper("list-events", {
        start,
        end,
        "calendar-ids": calendarIds,
      });

      return jsonTextResult(result);
    },
  );

  server.registerTool(
    "calendar_get_event",
    {
      title: "Get Event",
      description:
        "Fetch a single event by identifier. Pass occurrenceDate when targeting one instance of a recurring series.",
      annotations: {
        readOnlyHint: true,
      },
      inputSchema: eventLookupInputSchema,
    },
    async ({ eventIdentifier, calendarItemIdentifier, externalIdentifier, occurrenceDate }) => {
      if (!eventIdentifier && !calendarItemIdentifier && !externalIdentifier) {
        throw new Error(
          "Provide at least one of eventIdentifier, calendarItemIdentifier, or externalIdentifier.",
        );
      }

      await ensureHelperExists();
      const result = await runHelper("get-event", {
        "event-identifier": eventIdentifier,
        "calendar-item-identifier": calendarItemIdentifier,
        "external-identifier": externalIdentifier,
        "occurrence-date": occurrenceDate,
      });

      return jsonTextResult(result);
    },
  );

  server.registerTool(
    "calendar_create_event",
    {
      title: "Create Event",
      description: "Create a calendar event in the default calendar or a specified calendar.",
      inputSchema: {
        title: z.string(),
        start: z.string(),
        end: z.string(),
        calendarId: z.string().optional(),
        location: z.string().optional(),
        notes: z.string().optional(),
        url: z.string().optional(),
        allDay: z.boolean().optional(),
        timeZone: z.string().optional(),
      },
    },
    async ({ title, start, end, calendarId, location, notes, url, allDay, timeZone }) => {
      await ensureHelperExists();
      const result = await runHelper("create-event", {
        title,
        start,
        end,
        "calendar-id": calendarId,
        location,
        notes,
        url,
        "all-day": allDay ?? false,
        "time-zone": timeZone,
      });

      return jsonTextResult(result);
    },
  );

  server.registerTool(
    "calendar_delete_event",
    {
      title: "Delete Event",
      description:
        "Delete exactly one calendar target by identifier. For recurring events, choose whether to remove one occurrence or the entire series.",
      inputSchema: {
        eventIdentifier: z.string().optional(),
        calendarItemIdentifier: z.string().optional(),
        occurrenceDate: z.string().optional(),
        scope: z.enum(["occurrence", "series"]).optional(),
      },
    },
    async ({ eventIdentifier, calendarItemIdentifier, occurrenceDate, scope }) => {
      if (!eventIdentifier && !calendarItemIdentifier) {
        throw new Error("Provide eventIdentifier or calendarItemIdentifier.");
      }

      await ensureHelperExists();
      const result = await runHelper("delete-event", {
        "event-identifier": eventIdentifier,
        "calendar-item-identifier": calendarItemIdentifier,
        "occurrence-date": occurrenceDate,
        scope: scope ?? "occurrence",
      });

      return jsonTextResult(result);
    },
  );

  return server;
}
