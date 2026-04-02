import AppKit
import EventKit
import Foundation

struct JSONError: Codable {
    let error: String
}

struct PermissionsPayload: Codable {
    let status: String
    let canRead: Bool
    let canWrite: Bool
}

struct SourcePayload: Codable {
    let identifier: String
    let title: String
    let type: String
}

struct CalendarPayload: Codable {
    let identifier: String
    let title: String
    let colorHex: String?
    let allowsContentModifications: Bool
    let source: SourcePayload
}

struct CalendarSummaryPayload: Codable {
    let identifier: String
    let title: String
}

struct EventPayload: Codable {
    let eventIdentifier: String?
    let calendarItemIdentifier: String
    let calendarItemExternalIdentifier: String?
    let title: String
    let notes: String?
    let location: String?
    let url: String?
    let startDate: String
    let endDate: String
    let occurrenceDate: String?
    let timeZone: String?
    let allDay: Bool
    let isDetached: Bool
    let hasRecurrenceRules: Bool
    let availability: String
    let status: String
    let calendar: CalendarSummaryPayload
}

struct ParsedDateInput {
    enum Precision {
        case exactTime
        case localDay
    }

    let date: Date
    let precision: Precision
}

enum HelperError: Error {
    case message(String)
}

@main
@MainActor
struct CalendarMCPHelperAppMain {
    static let supportedCommands: Set<String> = [
        "permissions",
        "list-calendars",
        "list-events",
        "get-event",
        "create-event",
        "update-event",
        "delete-event"
    ]

    static func main() async {
        let rawArguments = sanitizedArguments()
        let fallbackResponsePath = responsePathFromRawArguments(rawArguments)

        do {
            initializeAppKit()
            if shouldRunInteractiveBootstrap(rawArguments) {
                let exitCode = await runInteractiveBootstrap()
                NSApp.terminate(nil)
                exit(exitCode)
            }

            let invocation = try parseInvocation(rawArguments)
            let data = try await run(command: invocation.command, options: invocation.options)
            try writeResponse(data, responsePath: invocation.responsePath)
            NSApp.terminate(nil)
            exit(0)
        } catch {
            let payload = JSONError(error: errorMessage(error))
            let data = try? encodeJSON(payload)

            if let data {
                try? writeResponse(data, responsePath: fallbackResponsePath)
            } else {
                FileHandle.standardError.write(Data("{\"error\":\"Unable to encode JSON output\"}\n".utf8))
            }

            NSApp.terminate(nil)
            exit(1)
        }
    }

    static func shouldRunInteractiveBootstrap(_ rawArguments: [String]) -> Bool {
        guard let firstArgument = rawArguments.first else {
            return true
        }

        return !supportedCommands.contains(firstArgument)
    }

    static func sanitizedArguments() -> [String] {
        let rawArguments = Array(CommandLine.arguments.dropFirst())
        var sanitized: [String] = []
        var index = 0

        while index < rawArguments.count {
            let token = rawArguments[index]

            if token.hasPrefix("-psn_") {
                index += 1
                continue
            }

            if token == "-ApplePersistenceIgnoreState" {
                index += min(2, rawArguments.count - index)
                continue
            }

            sanitized.append(token)
            index += 1
        }

        return sanitized
    }

    static func responsePathFromRawArguments(_ rawArguments: [String]) -> String? {
        var index = 0

        while index < rawArguments.count {
            if rawArguments[index] == "--response-path" {
                let nextIndex = index + 1
                if nextIndex < rawArguments.count, !rawArguments[nextIndex].hasPrefix("--") {
                    return rawArguments[nextIndex]
                }
            }

            index += 1
        }

        return nil
    }

    static func parseInvocation(_ rawArguments: [String]) throws -> (command: String, options: [String: String], responsePath: String?) {
        guard let command = rawArguments.first else {
            throw HelperError.message("Missing command. Use one of: permissions, list-calendars, list-events, get-event, create-event, update-event, delete-event")
        }

        var options = try parseOptions(Array(rawArguments.dropFirst()))
        let responsePath = options.removeValue(forKey: "response-path")
        return (command, options, responsePath)
    }

    static func writeResponse(_ data: Data, responsePath: String?) throws {
        guard let responsePath, !responsePath.isEmpty else {
            guard let text = String(data: data, encoding: .utf8) else {
                throw HelperError.message("Unable to encode JSON output")
            }

            print(text)
            return
        }

        let responseURL = URL(fileURLWithPath: responsePath)
        try FileManager.default.createDirectory(
            at: responseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: responseURL, options: .atomic)
    }

    static func run(command: String, options: [String: String]) async throws -> Data {
        let store = EKEventStore()

        switch command {
        case "permissions":
            let prompt = boolOption(options, key: "prompt", defaultValue: false)
            let access = stringOption(options, key: "access", defaultValue: "full")
            let payload = try await permissionsPayload(store: store, prompt: prompt, access: access)
            return try encodeJSON(payload)

        case "list-calendars":
            try ensureReadAccess()
            return try encodeJSON(listCalendars(store: store))

        case "list-events":
            try ensureReadAccess()
            let start = try dateOption(options, key: "start")
            let end = try dateOption(options, key: "end")
            let calendarIDs = try stringArrayOption(options, key: "calendar-ids")
            let payload = try listEvents(
                store: store,
                start: start,
                end: end,
                calendarIDs: calendarIDs
            )
            return try encodeJSON(payload)

        case "get-event":
            try ensureReadAccess()
            let eventIdentifier = options["event-identifier"]
            let calendarItemIdentifier = options["calendar-item-identifier"]
            let externalIdentifier = options["external-identifier"]
            let occurrenceDate = try optionalOccurrenceDateOption(options, key: "occurrence-date")
            let payload = try getEvent(
                store: store,
                eventIdentifier: eventIdentifier,
                calendarItemIdentifier: calendarItemIdentifier,
                externalIdentifier: externalIdentifier,
                occurrenceDate: occurrenceDate
            )
            return try encodeJSON(payload)

        case "create-event":
            try ensureWriteAccess()
            let title = stringOption(options, key: "title", defaultValue: "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else {
                throw HelperError.message("Missing title for new event.")
            }

            let start = try dateOption(options, key: "start")
            let end = try dateOption(options, key: "end")
            let calendarID = options["calendar-id"]
            let location = options["location"]
            let notes = options["notes"]
            let url = try optionalURLOption(options, key: "url")
            let allDay = boolOption(options, key: "all-day", defaultValue: false)
            let timeZoneIdentifier = options["time-zone"]
            let payload = try createEvent(
                store: store,
                title: title,
                start: start,
                end: end,
                calendarID: calendarID,
                location: location,
                notes: notes,
                url: url,
                allDay: allDay,
                timeZoneIdentifier: timeZoneIdentifier
            )
            return try encodeJSON(payload)

        case "update-event":
            try ensureWriteAccess()
            let eventIdentifier = options["event-identifier"]
            let calendarItemIdentifier = options["calendar-item-identifier"]
            let externalIdentifier = options["external-identifier"]
            let occurrenceDate = try optionalOccurrenceDateOption(options, key: "occurrence-date")
            let title = options["title"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            let start = try optionalDateOption(options, key: "start")
            let end = try optionalDateOption(options, key: "end")
            let calendarID = options["calendar-id"]
            let location = options["location"]
            let clearLocation = try optionalBoolOption(options, key: "clear-location") ?? false
            let notes = options["notes"]
            let clearNotes = try optionalBoolOption(options, key: "clear-notes") ?? false
            let url = try optionalURLOption(options, key: "url")
            let clearURL = try optionalBoolOption(options, key: "clear-url") ?? false
            let allDay = try optionalBoolOption(options, key: "all-day")
            let timeZoneIdentifier = options["time-zone"]
            let clearTimeZone = try optionalBoolOption(options, key: "clear-time-zone") ?? false
            let scope = stringOption(options, key: "scope", defaultValue: "occurrence")
            let payload = try updateEvent(
                store: store,
                eventIdentifier: eventIdentifier,
                calendarItemIdentifier: calendarItemIdentifier,
                externalIdentifier: externalIdentifier,
                occurrenceDate: occurrenceDate,
                title: title,
                start: start,
                end: end,
                calendarID: calendarID,
                location: location,
                clearLocation: clearLocation,
                notes: notes,
                clearNotes: clearNotes,
                url: url,
                clearURL: clearURL,
                allDay: allDay,
                timeZoneIdentifier: timeZoneIdentifier,
                clearTimeZone: clearTimeZone,
                scope: scope
            )
            return try encodeJSON(payload)

        case "delete-event":
            try ensureWriteAccess()
            let eventIdentifier = options["event-identifier"]
            let calendarItemIdentifier = options["calendar-item-identifier"]
            let occurrenceDate = try optionalOccurrenceDateOption(options, key: "occurrence-date")
            let scope = stringOption(options, key: "scope", defaultValue: "occurrence")
            let payload = try deleteEvent(
                store: store,
                eventIdentifier: eventIdentifier,
                calendarItemIdentifier: calendarItemIdentifier,
                occurrenceDate: occurrenceDate,
                scope: scope
            )
            return try encodeJSON(payload)

        default:
            throw HelperError.message("Unknown command: \(command)")
        }
    }

    static func initializeAppKit() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
    }

    static func encodeJSON<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(value)
    }

    static func errorMessage(_ error: Error) -> String {
        if let helperError = error as? HelperError {
            switch helperError {
            case .message(let message):
                return message
            }
        }

        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }

        return String(describing: error)
    }

    static func parseOptions(_ args: [String]) throws -> [String: String] {
        var options: [String: String] = [:]
        var index = 0

        while index < args.count {
            let token = args[index]
            guard token.hasPrefix("--") else {
                throw HelperError.message("Unexpected token: \(token)")
            }

            let key = String(token.dropFirst(2))
            let nextIndex = index + 1

            if nextIndex < args.count, !args[nextIndex].hasPrefix("--") {
                options[key] = args[nextIndex]
                index += 2
            } else {
                options[key] = "true"
                index += 1
            }
        }

        return options
    }

    static func stringOption(_ options: [String: String], key: String, defaultValue: String) -> String {
        options[key] ?? defaultValue
    }

    static func boolOption(_ options: [String: String], key: String, defaultValue: Bool) -> Bool {
        guard let value = options[key] else {
            return defaultValue
        }

        switch value.lowercased() {
        case "1", "true", "yes", "y":
            return true
        case "0", "false", "no", "n":
            return false
        default:
            return defaultValue
        }
    }

    static func optionalBoolOption(_ options: [String: String], key: String) throws -> Bool? {
        guard let value = options[key] else {
            return nil
        }

        switch value.lowercased() {
        case "1", "true", "yes", "y":
            return true
        case "0", "false", "no", "n":
            return false
        default:
            throw HelperError.message("Invalid boolean value '\(value)' for --\(key)")
        }
    }

    static func dateOption(_ options: [String: String], key: String) throws -> Date {
        guard let raw = options[key] else {
            throw HelperError.message("Missing date for --\(key). \(acceptedDateFormatsMessage(for: key))")
        }

        guard let parsed = parseDateInput(raw) else {
            throw HelperError.message("Invalid date for --\(key). \(acceptedDateFormatsMessage(for: key))")
        }

        return parsed.date
    }

    static func optionalDateOption(_ options: [String: String], key: String) throws -> Date? {
        guard let raw = options[key] else {
            return nil
        }

        guard let parsed = parseDateInput(raw) else {
            throw HelperError.message("Invalid date for --\(key). \(acceptedDateFormatsMessage(for: key))")
        }

        return parsed.date
    }

    static func optionalOccurrenceDateOption(_ options: [String: String], key: String) throws -> ParsedDateInput? {
        guard let raw = options[key] else {
            return nil
        }

        guard let parsed = parseDateInput(raw) else {
            throw HelperError.message("Invalid date for --\(key). \(acceptedDateFormatsMessage(for: key))")
        }

        return parsed
    }

    static func stringArrayOption(_ options: [String: String], key: String) throws -> [String]? {
        guard let raw = options[key] else {
            return nil
        }

        let data = Data(raw.utf8)
        do {
            return try JSONDecoder().decode([String].self, from: data)
        } catch {
            throw HelperError.message("Invalid JSON array for --\(key)")
        }
    }

    static func optionalURLOption(_ options: [String: String], key: String) throws -> URL? {
        guard let raw = options[key] else {
            return nil
        }

        guard let url = URL(string: raw) else {
            throw HelperError.message("Invalid URL for --\(key)")
        }

        return url
    }

    static func parseDateInput(_ raw: String) -> ParsedDateInput? {
        if let parsed = fractionalISO8601Formatter.date(from: raw) {
            return ParsedDateInput(date: parsed, precision: .exactTime)
        }

        if let parsed = iso8601Formatter.date(from: raw) {
            return ParsedDateInput(date: parsed, precision: .exactTime)
        }

        if let parsed = localFractionalDateTimeFormatter.date(from: raw) {
            return ParsedDateInput(date: parsed, precision: .exactTime)
        }

        if let parsed = localSecondDateTimeFormatter.date(from: raw) {
            return ParsedDateInput(date: parsed, precision: .exactTime)
        }

        if let parsed = localMinuteDateTimeFormatter.date(from: raw) {
            return ParsedDateInput(date: parsed, precision: .exactTime)
        }

        if let parsed = localDateFormatter.date(from: raw) {
            return ParsedDateInput(date: parsed, precision: .localDay)
        }

        return nil
    }

    static func acceptedDateFormatsMessage(for key: String) -> String {
        let base = """
        Accepted formats: YYYY-MM-DD (local calendar day), YYYY-MM-DDTHH:mm, YYYY-MM-DDTHH:mm:ss, YYYY-MM-DDTHH:mm:ss.SSS, or an ISO-8601 timestamp with timezone like 2026-04-02T09:30:00-05:00.
        """

        if key == "occurrence-date" {
            return "\(base) For --occurrence-date, YYYY-MM-DD matches by local calendar day."
        }

        return base
    }

    static func permissionsPayload(store: EKEventStore, prompt: Bool, access: String) async throws -> PermissionsPayload {
        let currentStatus = EKEventStore.authorizationStatus(for: .event)

        if prompt, currentStatus == .notDetermined {
            prepareForPermissionPrompt()
            return try await requestAccessAndRefreshPermissions(store: store, access: access)
        }

        return permissionsPayload(for: currentStatus)
    }

    static func runInteractiveBootstrap() async -> Int32 {
        let store = EKEventStore()
        prepareForInteractiveLaunch()

        do {
            var payload = permissionsPayload(for: EKEventStore.authorizationStatus(for: .event))

            if payload.status == "notDetermined" {
                payload = try await requestAccessAndRefreshPermissions(store: store, access: "full")
            }

            presentBootstrapAlert(for: payload)
            return payload.canRead ? 0 : 1
        } catch {
            presentAlert(
                title: "Calendar Access Failed",
                message: """
                The helper app could not request Calendar access.

                \(errorMessage(error))
                """
            )
            return 1
        }
    }

    static func prepareForInteractiveLaunch() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func prepareForPermissionPrompt() {
        prepareForInteractiveLaunch()
    }

    static func presentBootstrapAlert(for payload: PermissionsPayload) {
        switch payload.status {
        case "fullAccess":
            presentAlert(
                title: "Calendar Access Ready",
                message: """
                CalendarMCPHelperApp has full Calendar access.

                Return to Codex and I can read next week's events, add a test event, verify it, and remove it.
                """
            )
        case "writeOnly":
            presentAlert(
                title: "Write-Only Access Granted",
                message: """
                The helper app only has write-only Calendar access.

                Reads will still fail. Open System Settings > Privacy & Security > Calendars and upgrade CalendarMCPHelperApp to full access, then relaunch this app.
                """
            )
        case "denied":
            presentAlert(
                title: "Calendar Access Denied",
                message: """
                Calendar access was denied for CalendarMCPHelperApp.

                Open System Settings > Privacy & Security > Calendars, enable CalendarMCPHelperApp, then relaunch this app.
                """
            )
        case "restricted":
            presentAlert(
                title: "Calendar Access Restricted",
                message: "Calendar access is restricted on this Mac for CalendarMCPHelperApp."
            )
        default:
            presentAlert(
                title: "Calendar Access Still Pending",
                message: """
                Calendar access is still not determined.

                If macOS did not show a permission prompt, relaunch CalendarMCPHelperApp directly from Finder and try again.
                """
            )
        }
    }

    static func presentAlert(title: String, message: String) {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    static func requestFullAccess(store: EKEventStore) async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            store.requestFullAccessToEvents { granted, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                continuation.resume(returning: granted)
            }
        }
    }

    static func requestWriteOnlyAccess(store: EKEventStore) async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            store.requestWriteOnlyAccessToEvents { granted, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                continuation.resume(returning: granted)
            }
        }
    }

    static func requestAccessAndRefreshPermissions(store: EKEventStore, access: String) async throws -> PermissionsPayload {
        do {
            switch access {
            case "full":
                _ = try await requestFullAccess(store: store)
            case "writeOnly":
                _ = try await requestWriteOnlyAccess(store: store)
            default:
                throw HelperError.message("Invalid access value '\(access)'. Use 'full' or 'writeOnly'.")
            }
        } catch {
            let updatedPayload = permissionsPayload(for: EKEventStore.authorizationStatus(for: .event))
            if updatedPayload.status != "notDetermined" {
                return updatedPayload
            }

            throw error
        }

        return permissionsPayload(for: EKEventStore.authorizationStatus(for: .event))
    }

    static func permissionsPayload(for status: EKAuthorizationStatus) -> PermissionsPayload {
        switch status {
        case .fullAccess, .authorized:
            return PermissionsPayload(status: "fullAccess", canRead: true, canWrite: true)
        case .writeOnly:
            return PermissionsPayload(status: "writeOnly", canRead: false, canWrite: true)
        case .notDetermined:
            return PermissionsPayload(status: "notDetermined", canRead: false, canWrite: false)
        case .restricted:
            return PermissionsPayload(status: "restricted", canRead: false, canWrite: false)
        case .denied:
            return PermissionsPayload(status: "denied", canRead: false, canWrite: false)
        @unknown default:
            return PermissionsPayload(status: "unknown", canRead: false, canWrite: false)
        }
    }

    static func ensureReadAccess() throws {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess, .authorized:
            return
        case .notDetermined:
            throw HelperError.message("Calendar access is not determined. Run calendar_permissions with prompt=true and access='full'.")
        case .writeOnly:
            throw HelperError.message("Calendar helper app only has write-only access. Re-run calendar_permissions with access='full'.")
        case .restricted:
            throw HelperError.message("Calendar access is restricted for this helper app.")
        case .denied:
            throw HelperError.message("Calendar access was denied for this helper app.")
        @unknown default:
            throw HelperError.message("Calendar access is unavailable for this helper app.")
        }
    }

    static func ensureWriteAccess() throws {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess, .authorized, .writeOnly:
            return
        case .notDetermined:
            throw HelperError.message("Calendar access is not determined. Run calendar_permissions with prompt=true and access='full' or 'writeOnly'.")
        case .restricted:
            throw HelperError.message("Calendar access is restricted for this helper app.")
        case .denied:
            throw HelperError.message("Calendar access was denied for this helper app.")
        @unknown default:
            throw HelperError.message("Calendar access is unavailable for this helper app.")
        }
    }

    static func listCalendars(store: EKEventStore) -> [CalendarPayload] {
        store.calendars(for: .event)
            .sorted { lhs, rhs in
                if lhs.source.title == rhs.source.title {
                    return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
                }

                return lhs.source.title.localizedCaseInsensitiveCompare(rhs.source.title) == .orderedAscending
            }
            .map(toCalendarPayload)
    }

    static func listEvents(
        store: EKEventStore,
        start: Date,
        end: Date,
        calendarIDs: [String]?
    ) throws -> [EventPayload] {
        guard end > start else {
            throw HelperError.message("The end date must be after the start date.")
        }

        let maxRange: TimeInterval = 4 * 366 * 24 * 60 * 60
        guard end.timeIntervalSince(start) <= maxRange else {
            throw HelperError.message("EventKit only supports queries up to four years wide. Shorten the requested range.")
        }

        let calendars = try resolveCalendars(store: store, identifiers: calendarIDs)
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: calendars)
        return store.events(matching: predicate)
            .sorted { lhs, rhs in
                if lhs.startDate == rhs.startDate {
                    return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
                }

                return lhs.startDate < rhs.startDate
            }
            .map(toEventPayload)
    }

    static func resolveCalendars(store: EKEventStore, identifiers: [String]?) throws -> [EKCalendar]? {
        guard let identifiers, !identifiers.isEmpty else {
            return nil
        }

        let calendars = identifiers.compactMap(store.calendar(withIdentifier:))
        guard calendars.count == identifiers.count else {
            let found = Set(calendars.map(\.calendarIdentifier))
            let missing = identifiers.filter { !found.contains($0) }
            throw HelperError.message("Unknown calendar identifier(s): \(missing.joined(separator: ", "))")
        }

        return calendars
    }

    static func getEvent(
        store: EKEventStore,
        eventIdentifier: String?,
        calendarItemIdentifier: String?,
        externalIdentifier: String?,
        occurrenceDate: ParsedDateInput?
    ) throws -> EventPayload {
        guard eventIdentifier != nil || calendarItemIdentifier != nil || externalIdentifier != nil else {
            throw HelperError.message("Provide eventIdentifier, calendarItemIdentifier, or externalIdentifier.")
        }

        if let occurrenceDate {
            guard let event = findEventOccurrence(
                store: store,
                eventIdentifier: eventIdentifier,
                calendarItemIdentifier: calendarItemIdentifier,
                externalIdentifier: externalIdentifier,
                occurrenceDate: occurrenceDate
            ) else {
                throw HelperError.message("No recurring event occurrence matched the requested identifiers and occurrenceDate.")
            }

            return toEventPayload(event: event)
        }

        return toEventPayload(
            event: try resolveEvent(
                store: store,
                eventIdentifier: eventIdentifier,
                calendarItemIdentifier: calendarItemIdentifier,
                externalIdentifier: externalIdentifier
            )
        )
    }

    static func createEvent(
        store: EKEventStore,
        title: String,
        start: Date,
        end: Date,
        calendarID: String?,
        location: String?,
        notes: String?,
        url: URL?,
        allDay: Bool,
        timeZoneIdentifier: String?
    ) throws -> EventPayload {
        guard end > start else {
            throw HelperError.message("The end date must be after the start date.")
        }

        let calendar: EKCalendar
        if let calendarID {
            guard let resolvedCalendar = store.calendar(withIdentifier: calendarID) else {
                throw HelperError.message("Unknown calendar identifier: \(calendarID)")
            }
            calendar = resolvedCalendar
        } else if let defaultCalendar = store.defaultCalendarForNewEvents {
            calendar = defaultCalendar
        } else {
            throw HelperError.message("No default calendar is available for new events.")
        }

        guard calendar.allowsContentModifications else {
            throw HelperError.message("Calendar '\(calendar.title)' does not allow modifications.")
        }

        let event = EKEvent(eventStore: store)
        event.calendar = calendar
        event.title = title
        event.startDate = start
        event.endDate = end
        event.location = location
        event.notes = notes
        event.url = url
        event.isAllDay = allDay

        if let timeZoneIdentifier {
            guard let timeZone = TimeZone(identifier: timeZoneIdentifier) else {
                throw HelperError.message("Unknown time zone identifier: \(timeZoneIdentifier)")
            }
            event.timeZone = timeZone
        }

        try store.save(event, span: .thisEvent, commit: true)

        return toEventPayload(event: event)
    }

    static func updateEvent(
        store: EKEventStore,
        eventIdentifier: String?,
        calendarItemIdentifier: String?,
        externalIdentifier: String?,
        occurrenceDate: ParsedDateInput?,
        title: String?,
        start: Date?,
        end: Date?,
        calendarID: String?,
        location: String?,
        clearLocation: Bool,
        notes: String?,
        clearNotes: Bool,
        url: URL?,
        clearURL: Bool,
        allDay: Bool?,
        timeZoneIdentifier: String?,
        clearTimeZone: Bool,
        scope: String
    ) throws -> EventPayload {
        guard eventIdentifier != nil || calendarItemIdentifier != nil || externalIdentifier != nil else {
            throw HelperError.message("Provide eventIdentifier, calendarItemIdentifier, or externalIdentifier.")
        }

        let hasAnyUpdate =
            title != nil ||
            start != nil ||
            end != nil ||
            calendarID != nil ||
            location != nil ||
            clearLocation ||
            notes != nil ||
            clearNotes ||
            url != nil ||
            clearURL ||
            allDay != nil ||
            timeZoneIdentifier != nil ||
            clearTimeZone
        guard hasAnyUpdate else {
            throw HelperError.message("Provide at least one field to update.")
        }

        if clearLocation, location != nil {
            throw HelperError.message("Provide either location or clearLocation, not both.")
        }

        if clearNotes, notes != nil {
            throw HelperError.message("Provide either notes or clearNotes, not both.")
        }

        if clearURL, url != nil {
            throw HelperError.message("Provide either url or clearUrl, not both.")
        }

        if clearTimeZone, timeZoneIdentifier != nil {
            throw HelperError.message("Provide either timeZone or clearTimeZone, not both.")
        }

        let event = try resolveUpdateTarget(
            store: store,
            eventIdentifier: eventIdentifier,
            calendarItemIdentifier: calendarItemIdentifier,
            externalIdentifier: externalIdentifier,
            occurrenceDate: occurrenceDate
        )

        guard event.calendar.allowsContentModifications else {
            throw HelperError.message("Calendar '\(event.calendar.title)' does not allow modifications.")
        }

        let ekSpan = try resolveRecurringSpan(
            event: event,
            occurrenceDate: occurrenceDate,
            scope: scope,
            operation: "update"
        )

        if let title {
            guard !title.isEmpty else {
                throw HelperError.message("Updated title cannot be empty.")
            }
            event.title = title
        }

        if let start {
            event.startDate = start
        }

        if let end {
            event.endDate = end
        }

        if let calendarID {
            guard let resolvedCalendar = store.calendar(withIdentifier: calendarID) else {
                throw HelperError.message("Unknown calendar identifier: \(calendarID)")
            }

            guard resolvedCalendar.allowsContentModifications else {
                throw HelperError.message("Calendar '\(resolvedCalendar.title)' does not allow modifications.")
            }

            event.calendar = resolvedCalendar
        }

        if clearLocation {
            event.location = nil
        } else if let location {
            event.location = location
        }

        if clearNotes {
            event.notes = nil
        } else if let notes {
            event.notes = notes
        }

        if clearURL {
            event.url = nil
        } else if let url {
            event.url = url
        }

        if let allDay {
            event.isAllDay = allDay
        }

        if clearTimeZone {
            event.timeZone = nil
        } else if let timeZoneIdentifier {
            guard let timeZone = TimeZone(identifier: timeZoneIdentifier) else {
                throw HelperError.message("Unknown time zone identifier: \(timeZoneIdentifier)")
            }
            event.timeZone = timeZone
        }

        guard event.endDate > event.startDate else {
            throw HelperError.message("The end date must be after the start date.")
        }

        try store.save(event, span: ekSpan, commit: true)

        return toEventPayload(event: event)
    }

    static func deleteEvent(
        store: EKEventStore,
        eventIdentifier: String?,
        calendarItemIdentifier: String?,
        occurrenceDate: ParsedDateInput?,
        scope: String
    ) throws -> [String: String] {
        guard eventIdentifier != nil || calendarItemIdentifier != nil else {
            throw HelperError.message("Provide eventIdentifier or calendarItemIdentifier.")
        }

        let event = try resolveDeleteTarget(
            store: store,
            eventIdentifier: eventIdentifier,
            calendarItemIdentifier: calendarItemIdentifier,
            occurrenceDate: occurrenceDate
        )

        let ekSpan = try resolveRecurringSpan(
            event: event,
            occurrenceDate: occurrenceDate,
            scope: scope,
            operation: "deletion"
        )

        let deletedEventIdentifier = event.eventIdentifier
        let deletedCalendarItemIdentifier = event.calendarItemIdentifier
        try store.remove(event, span: ekSpan, commit: true)

        return [
            "deletedEventIdentifier": deletedEventIdentifier ?? "",
            "deletedCalendarItemIdentifier": deletedCalendarItemIdentifier,
            "scope": scope
        ]
    }

    static func resolveDeleteTarget(
        store: EKEventStore,
        eventIdentifier: String?,
        calendarItemIdentifier: String?,
        occurrenceDate: ParsedDateInput?
    ) throws -> EKEvent {
        if let occurrenceDate {
            guard let event = findEventOccurrence(
                store: store,
                eventIdentifier: eventIdentifier,
                calendarItemIdentifier: calendarItemIdentifier,
                externalIdentifier: nil,
                occurrenceDate: occurrenceDate
            ) else {
                throw HelperError.message("No recurring event occurrence matched the requested identifiers and occurrenceDate.")
            }

            return event
        }

        return try resolveEvent(
            store: store,
            eventIdentifier: eventIdentifier,
            calendarItemIdentifier: calendarItemIdentifier,
            externalIdentifier: nil
        )
    }

    static func resolveUpdateTarget(
        store: EKEventStore,
        eventIdentifier: String?,
        calendarItemIdentifier: String?,
        externalIdentifier: String?,
        occurrenceDate: ParsedDateInput?
    ) throws -> EKEvent {
        if let occurrenceDate {
            guard let event = findEventOccurrence(
                store: store,
                eventIdentifier: eventIdentifier,
                calendarItemIdentifier: calendarItemIdentifier,
                externalIdentifier: externalIdentifier,
                occurrenceDate: occurrenceDate
            ) else {
                throw HelperError.message("No recurring event occurrence matched the requested identifiers and occurrenceDate.")
            }

            return event
        }

        return try resolveEvent(
            store: store,
            eventIdentifier: eventIdentifier,
            calendarItemIdentifier: calendarItemIdentifier,
            externalIdentifier: externalIdentifier
        )
    }

    static func resolveEvent(
        store: EKEventStore,
        eventIdentifier: String?,
        calendarItemIdentifier: String?,
        externalIdentifier: String?
    ) throws -> EKEvent {
        guard eventIdentifier != nil || calendarItemIdentifier != nil || externalIdentifier != nil else {
            throw HelperError.message("Provide eventIdentifier, calendarItemIdentifier, or externalIdentifier.")
        }

        let resolvedByEventIdentifier = eventIdentifier.flatMap(store.event(withIdentifier:))
        let resolvedByCalendarItemIdentifier = calendarItemIdentifier.flatMap {
            store.calendarItem(withIdentifier: $0) as? EKEvent
        }

        var resolvedByExternalIdentifier: EKEvent?
        if let externalIdentifier {
            let matchingEvents = store.calendarItems(withExternalIdentifier: externalIdentifier)
                .compactMap { $0 as? EKEvent }

            if matchingEvents.count > 1 {
                throw HelperError.message("externalIdentifier resolved to multiple events. Provide eventIdentifier or calendarItemIdentifier instead.")
            }

            resolvedByExternalIdentifier = matchingEvents.first
        }

        if eventIdentifier != nil, resolvedByEventIdentifier == nil {
            throw HelperError.message("Event not found for eventIdentifier.")
        }

        if calendarItemIdentifier != nil, resolvedByCalendarItemIdentifier == nil {
            throw HelperError.message("Event not found for calendarItemIdentifier.")
        }

        if externalIdentifier != nil, resolvedByExternalIdentifier == nil {
            throw HelperError.message("Event not found for externalIdentifier.")
        }

        let resolvedEvents = [
            resolvedByEventIdentifier,
            resolvedByCalendarItemIdentifier,
            resolvedByExternalIdentifier
        ].compactMap { $0 }

        guard let firstResolvedEvent = resolvedEvents.first else {
            throw HelperError.message("Event not found.")
        }

        for resolvedEvent in resolvedEvents.dropFirst() {
            if resolvedEvent.calendarItemIdentifier != firstResolvedEvent.calendarItemIdentifier {
                throw HelperError.message("Provided identifiers resolved to different events.")
            }
        }

        return firstResolvedEvent
    }

    static func resolveRecurringSpan(
        event: EKEvent,
        occurrenceDate: ParsedDateInput?,
        scope: String,
        operation: String
    ) throws -> EKSpan {
        switch scope {
        case "occurrence":
            return .thisEvent
        case "series":
            guard occurrenceDate == nil else {
                throw HelperError.message("Series \(operation) must target the recurring series itself. Omit occurrenceDate.")
            }

            guard event.hasRecurrenceRules else {
                throw HelperError.message("Series \(operation) is only supported for recurring events.")
            }

            guard !event.isDetached else {
                throw HelperError.message("Series \(operation) is not supported for detached recurring instances. Identify the recurring series instead.")
            }

            return .futureEvents
        default:
            throw HelperError.message("Invalid scope '\(scope)'. Use 'occurrence' or 'series'.")
        }
    }

    static func findEventOccurrence(
        store: EKEventStore,
        eventIdentifier: String?,
        calendarItemIdentifier: String?,
        externalIdentifier: String?,
        occurrenceDate: ParsedDateInput
    ) -> EKEvent? {
        let searchStart: Date
        let searchEnd: Date
        switch occurrenceDate.precision {
        case .exactTime:
            searchStart = occurrenceDate.date.addingTimeInterval(-2 * 24 * 60 * 60)
            searchEnd = occurrenceDate.date.addingTimeInterval(2 * 24 * 60 * 60)
        case .localDay:
            searchStart = localCalendar.startOfDay(for: occurrenceDate.date)
            searchEnd = localCalendar.date(byAdding: .day, value: 1, to: searchStart) ?? searchStart.addingTimeInterval(24 * 60 * 60)
        }
        let predicate = store.predicateForEvents(withStart: searchStart, end: searchEnd, calendars: nil)

        return store.events(matching: predicate)
            .sorted { lhs, rhs in lhs.startDate < rhs.startDate }
            .first { event in
                matchesIdentifiers(
                    event: event,
                    eventIdentifier: eventIdentifier,
                    calendarItemIdentifier: calendarItemIdentifier,
                    externalIdentifier: externalIdentifier
                ) && occurrenceMatches(event.occurrenceDate ?? event.startDate, query: occurrenceDate)
            }
    }

    static func matchesIdentifiers(
        event: EKEvent,
        eventIdentifier: String?,
        calendarItemIdentifier: String?,
        externalIdentifier: String?
    ) -> Bool {
        if let eventIdentifier, event.eventIdentifier != eventIdentifier {
            return false
        }

        if let calendarItemIdentifier, event.calendarItemIdentifier != calendarItemIdentifier {
            return false
        }

        if let externalIdentifier, event.calendarItemExternalIdentifier != externalIdentifier {
            return false
        }

        return true
    }

    static func occurrenceMatches(_ eventDate: Date, query: ParsedDateInput) -> Bool {
        switch query.precision {
        case .exactTime:
            return abs(eventDate.timeIntervalSince(query.date)) < 1
        case .localDay:
            return localCalendar.isDate(eventDate, inSameDayAs: query.date)
        }
    }

    static func toCalendarPayload(calendar: EKCalendar) -> CalendarPayload {
        CalendarPayload(
            identifier: calendar.calendarIdentifier,
            title: calendar.title,
            colorHex: hexColor(from: calendar.color),
            allowsContentModifications: calendar.allowsContentModifications,
            source: SourcePayload(
                identifier: calendar.source.sourceIdentifier,
                title: calendar.source.title,
                type: sourceTypeString(calendar.source.sourceType)
            )
        )
    }

    static func toEventPayload(event: EKEvent) -> EventPayload {
        EventPayload(
            eventIdentifier: event.eventIdentifier,
            calendarItemIdentifier: event.calendarItemIdentifier,
            calendarItemExternalIdentifier: event.calendarItemExternalIdentifier,
            title: event.title,
            notes: event.notes,
            location: event.location,
            url: event.url?.absoluteString,
            startDate: iso8601Formatter.string(from: event.startDate),
            endDate: iso8601Formatter.string(from: event.endDate),
            occurrenceDate: event.occurrenceDate.map(iso8601Formatter.string(from:)),
            timeZone: event.timeZone?.identifier,
            allDay: event.isAllDay,
            isDetached: event.isDetached,
            hasRecurrenceRules: event.hasRecurrenceRules,
            availability: availabilityString(event.availability),
            status: statusString(event.status),
            calendar: CalendarSummaryPayload(
                identifier: event.calendar.calendarIdentifier,
                title: event.calendar.title
            )
        )
    }

    static func hexColor(from color: NSColor) -> String? {
        guard let converted = color.usingColorSpace(.sRGB) else {
            return nil
        }

        let red = Int((converted.redComponent * 255).rounded())
        let green = Int((converted.greenComponent * 255).rounded())
        let blue = Int((converted.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", red, green, blue)
    }

    static func sourceTypeString(_ sourceType: EKSourceType) -> String {
        switch sourceType {
        case .local:
            return "local"
        case .exchange:
            return "exchange"
        case .calDAV:
            return "calDAV"
        case .mobileMe:
            return "mobileMe"
        case .subscribed:
            return "subscribed"
        case .birthdays:
            return "birthdays"
        @unknown default:
            return "unknown"
        }
    }

    static func availabilityString(_ availability: EKEventAvailability) -> String {
        switch availability {
        case .notSupported:
            return "notSupported"
        case .busy:
            return "busy"
        case .free:
            return "free"
        case .tentative:
            return "tentative"
        case .unavailable:
            return "unavailable"
        @unknown default:
            return "unknown"
        }
    }

    static func statusString(_ status: EKEventStatus) -> String {
        switch status {
        case .none:
            return "none"
        case .confirmed:
            return "confirmed"
        case .tentative:
            return "tentative"
        case .canceled:
            return "canceled"
        @unknown default:
            return "unknown"
        }
    }

    static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withColonSeparatorInTimeZone]
        return formatter
    }()

    static let fractionalISO8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds, .withColonSeparatorInTimeZone]
        return formatter
    }()

    static let localCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = .autoupdatingCurrent
        return calendar
    }()

    static let localDateFormatter = makeLocalDateFormatter("yyyy-MM-dd")
    static let localMinuteDateTimeFormatter = makeLocalDateFormatter("yyyy-MM-dd'T'HH:mm")
    static let localSecondDateTimeFormatter = makeLocalDateFormatter("yyyy-MM-dd'T'HH:mm:ss")
    static let localFractionalDateTimeFormatter = makeLocalDateFormatter("yyyy-MM-dd'T'HH:mm:ss.SSS")

    static func makeLocalDateFormatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = localCalendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = format
        formatter.isLenient = false
        return formatter
    }
}
