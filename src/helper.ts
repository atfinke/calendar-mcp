import { execFile } from "node:child_process";
import { constants as fsConstants } from "node:fs";
import { access, mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);
const thisFile = fileURLToPath(import.meta.url);
const thisDir = path.dirname(thisFile);
const HELPER_TIMEOUT_MS = 30_000;
const HELPER_POLL_INTERVAL_MS = 100;
const HELPER_MAX_BUFFER_BYTES = 10 * 1024 * 1024;

const DEFAULT_HELPER_APP_PATH = path.resolve(
  thisDir,
  "../CalendarMCPHelperApp/build/Build/Products/Release/CalendarMCPHelperApp.app",
);

const helperAppPath = process.env.CALENDAR_MCP_HELPER_APP_PATH ?? DEFAULT_HELPER_APP_PATH;
const helperExecutablePath = path.join(
  helperAppPath,
  "Contents",
  "MacOS",
  "CalendarMCPHelperApp",
);

type HelperOptionValue = boolean | number | string | string[] | undefined;
type HelperOptions = Record<string, HelperOptionValue>;

function describeUnknownError(error: unknown): string {
  if (error instanceof Error && error.message) {
    return error.message;
  }

  return String(error);
}

function toCliOptions(raw: HelperOptions): string[] {
  const args: string[] = [];

  for (const [key, value] of Object.entries(raw)) {
    if (value === undefined) {
      continue;
    }

    const serializedValue = Array.isArray(value) ? JSON.stringify(value) : String(value);
    args.push(`--${key}`, serializedValue);
  }

  return args;
}

function parseHelperErrorPayload(payload: unknown): string | null {
  if (!payload || typeof payload !== "object") {
    return null;
  }

  const maybeError = (payload as { error?: unknown }).error;
  if (typeof maybeError === "string" && maybeError.trim()) {
    return maybeError.trim();
  }

  return null;
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function waitForHelperResponse<T>(responsePath: string, command: string): Promise<T> {
  const deadline = Date.now() + HELPER_TIMEOUT_MS;
  let lastError: unknown;

  while (Date.now() < deadline) {
    try {
      const raw = await readFile(responsePath, "utf8");
      if (!raw.trim()) {
        await sleep(HELPER_POLL_INTERVAL_MS);
        continue;
      }

      const payload = JSON.parse(raw) as unknown;
      const helperError = parseHelperErrorPayload(payload);
      if (helperError) {
        throw new Error(`Helper command '${command}' failed: ${helperError}`);
      }

      return payload as T;
    } catch (error) {
      if (
        error &&
        typeof error === "object" &&
        "code" in error &&
        (error as { code?: string }).code === "ENOENT"
      ) {
        // The helper app has not written the response yet.
      } else if (error instanceof Error && error.message.startsWith("Helper command '")) {
        throw error;
      } else {
        lastError = error;
      }
    }

    await sleep(HELPER_POLL_INTERVAL_MS);
  }

  const suffix = lastError ? `: ${describeUnknownError(lastError)}` : "";
  throw new Error(
    `Helper command '${command}' timed out waiting for app response at ${responsePath}${suffix}`,
  );
}

export async function ensureHelperExists(): Promise<void> {
  try {
    await access(helperExecutablePath, fsConstants.R_OK | fsConstants.X_OK);
  } catch {
    throw new Error(
      `Missing helper app executable at ${helperExecutablePath}. Build it first with 'npm run build:helper-app'.`,
    );
  }
}

export async function runHelper<T>(command: string, options: HelperOptions = {}): Promise<T> {
  const tempDir = await mkdtemp(path.join(tmpdir(), "calendar-mcp-helper-app-"));
  const responsePath = path.join(tempDir, "response.json");
  const args = [
    "-n",
    "-a",
    helperAppPath,
    "--args",
    command,
    ...toCliOptions(options),
    "--response-path",
    responsePath,
  ];

  try {
    await execFileAsync("open", args, {
      maxBuffer: HELPER_MAX_BUFFER_BYTES,
      timeout: HELPER_TIMEOUT_MS,
    });

    return await waitForHelperResponse<T>(responsePath, command);
  } catch (error) {
    const errorMessage =
      error && typeof error === "object" && "message" in error
        ? String((error as { message?: unknown }).message ?? "")
        : typeof error === "string"
          ? error
          : "";

    if (errorMessage.startsWith(`Helper command '${command}'`)) {
      throw new Error(errorMessage);
    }

    if (error && typeof error === "object" && "stderr" in error) {
      const stderr = String((error as { stderr?: string }).stderr ?? "");
      const timeoutSuffix = "killed" in error && error.killed ? " (timed out)" : "";
      if (stderr) {
        throw new Error(`Failed to launch helper app${timeoutSuffix}: ${stderr.trim()}`);
      }
    }

    throw new Error(
      `Helper command '${command}' failed while launching helper app: ${describeUnknownError(error)}`,
    );
  } finally {
    await rm(tempDir, { recursive: true, force: true });
  }
}

export function jsonTextResult(payload: unknown) {
  return {
    content: [
      {
        type: "text" as const,
        text: JSON.stringify(payload, null, 2),
      },
    ],
  };
}
