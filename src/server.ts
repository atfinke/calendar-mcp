import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";

import { ensureHelperExists, jsonTextResult, runHelper } from "./helper.js";

const dateInputDescription =
  "Accepts YYYY-MM-DD (local calendar day), YYYY-MM-DDTHH:mm[:ss][.SSS] (local time), or ISO-8601 / RFC 3339 with timezone like 2026-04-02T09:30:00-05:00.";

const occurrenceDateInputDescription =
  "Accepts YYYY-MM-DD to match a recurring occurrence by local calendar day, or a timestamp to match an exact occurrence start time. Prefer the exact timestamp returned by a previous read when available.";

const eventLookupInputSchema = {
  eventIdentifier: z.string().optional(),
  calendarItemIdentifier: z.string().optional(),
  externalIdentifier: z.string().optional(),
  occurrenceDate: z.string().describe(occurrenceDateInputDescription).optional(),
};

const eventUpdateInputSchema = {
  ...eventLookupInputSchema,
  title: z.string().optional(),
  start: z.string().describe(dateInputDescription).optional(),
  end: z.string().describe(dateInputDescription).optional(),
  calendarId: z.string().optional(),
  location: z.string().optional(),
  clearLocation: z.boolean().optional(),
  notes: z.string().optional(),
  clearNotes: z.boolean().optional(),
  url: z.string().optional(),
  clearUrl: z.boolean().optional(),
  allDay: z.boolean().optional(),
  timeZone: z.string().optional(),
  clearTimeZone: z.boolean().optional(),
  scope: z.enum(["occurrence", "series"]).optional(),
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
      description:
        "List calendar events in a time window. start and end accept local dates, local times, or timezone-bearing ISO-8601 timestamps.",
      annotations: {
        readOnlyHint: true,
      },
      inputSchema: {
        start: z.string().describe(dateInputDescription),
        end: z.string().describe(dateInputDescription),
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
      description:
        "Create a calendar event in the default calendar or a specified calendar. start and end accept local dates, local times, or timezone-bearing ISO-8601 timestamps.",
      inputSchema: {
        title: z.string(),
        start: z.string().describe(dateInputDescription),
        end: z.string().describe(dateInputDescription),
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
        occurrenceDate: z.string().describe(occurrenceDateInputDescription).optional(),
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

  server.registerTool(
    "calendar_update_event",
    {
      title: "Update Event",
      description:
        "Update an existing calendar event in place. Omitted fields are left unchanged. Use clear flags to remove location, notes, url, or timeZone.",
      inputSchema: eventUpdateInputSchema,
    },
    async ({
      eventIdentifier,
      calendarItemIdentifier,
      externalIdentifier,
      occurrenceDate,
      title,
      start,
      end,
      calendarId,
      location,
      clearLocation,
      notes,
      clearNotes,
      url,
      clearUrl,
      allDay,
      timeZone,
      clearTimeZone,
      scope,
    }) => {
      if (!eventIdentifier && !calendarItemIdentifier && !externalIdentifier) {
        throw new Error(
          "Provide at least one of eventIdentifier, calendarItemIdentifier, or externalIdentifier.",
        );
      }

      if (
        title === undefined &&
        start === undefined &&
        end === undefined &&
        calendarId === undefined &&
        location === undefined &&
        !clearLocation &&
        notes === undefined &&
        !clearNotes &&
        url === undefined &&
        !clearUrl &&
        allDay === undefined &&
        timeZone === undefined &&
        !clearTimeZone
      ) {
        throw new Error("Provide at least one field to update.");
      }

      await ensureHelperExists();
      const result = await runHelper("update-event", {
        "event-identifier": eventIdentifier,
        "calendar-item-identifier": calendarItemIdentifier,
        "external-identifier": externalIdentifier,
        "occurrence-date": occurrenceDate,
        title,
        start,
        end,
        "calendar-id": calendarId,
        location,
        "clear-location": clearLocation,
        notes,
        "clear-notes": clearNotes,
        url,
        "clear-url": clearUrl,
        "all-day": allDay,
        "time-zone": timeZone,
        "clear-time-zone": clearTimeZone,
        scope: scope ?? "occurrence",
      });

      return jsonTextResult(result);
    },
  );

  return server;
}
