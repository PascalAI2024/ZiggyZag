import { invoke } from "@tauri-apps/api/core";
import { listen, type UnlistenFn } from "@tauri-apps/api/event";

export type TerminalTheme = "ziggy" | "ember" | "paper";

export type TerminalSettings = {
  shellPath: string;
  startupDirectory: string;
  fontFamily: string;
  fontSize: number;
  scrollback: number;
  theme: TerminalTheme;
};

export type TerminalData = {
  terminalId: string;
  data: string;
};

export type ShellIntegrationEvent = {
  type: "session.ready" | "prompt.rendered" | "command.started" | "command.finished" | string;
  id?: number;
  protocol?: number;
  shell?: string;
  version?: string;
  cwd?: string;
  command?: string;
  status?: number;
  duration_ms?: number;
  last_status?: number;
  last_duration_ms?: number;
  jobs?: number;
};

type TerminalDataPayload =
  | string
  | {
      terminalId?: string;
      terminal_id?: string;
      id?: string;
      data?: string;
    };

export async function createTerminal(
  terminalId: string,
  settings: TerminalSettings,
  size: { cols: number; rows: number },
) {
  return invoke("create_terminal", {
    terminalId,
    terminal_id: terminalId,
    shellPath: settings.shellPath || null,
    startupDirectory: settings.startupDirectory || null,
    cols: size.cols,
    rows: size.rows,
  });
}

export async function writeToTerminal(terminalId: string, data: string) {
  return invoke("write_to_terminal", {
    terminalId,
    terminal_id: terminalId,
    data,
  });
}

export async function resizeTerminal(terminalId: string, cols: number, rows: number) {
  return invoke("resize_terminal", {
    terminalId,
    terminal_id: terminalId,
    cols,
    rows,
  });
}

export async function closeTerminal(terminalId: string) {
  return invoke("close_terminal", {
    terminalId,
    terminal_id: terminalId,
  });
}

export function listenForTerminalData(handler: (event: TerminalData) => void): Promise<UnlistenFn> {
  return listen<TerminalDataPayload>("terminal://data", (event) => {
    const payload = event.payload;

    if (typeof payload === "string") {
      handler({ terminalId: "default", data: payload });
      return;
    }

    handler({
      terminalId: payload.terminalId ?? payload.terminal_id ?? payload.id ?? "default",
      data: payload.data ?? "",
    });
  });
}

export function extractShellIntegrationEvents(data: string): ShellIntegrationEvent[] {
  const events: ShellIntegrationEvent[] = [];
  const pattern = /\x1b\]777;ziggyzag:event:([^\x07]*)\x07/g;
  let match: RegExpExecArray | null;

  while ((match = pattern.exec(data)) !== null) {
    try {
      events.push(JSON.parse(match[1]) as ShellIntegrationEvent);
    } catch {
      // Ignore malformed app events and keep the terminal stream moving.
    }
  }

  return events;
}
