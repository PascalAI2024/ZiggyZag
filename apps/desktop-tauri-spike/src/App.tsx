import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import { FitAddon } from "@xterm/addon-fit";
import { Terminal } from "@xterm/xterm";
import { Check, FolderOpen, Monitor, Plus, Settings, Sparkles, TerminalSquare, X } from "lucide-react";
import {
  closeTerminal,
  createTerminal,
  extractShellIntegrationEvents,
  listenForTerminalData,
  type ShellIntegrationEvent,
  resizeTerminal,
  type TerminalSettings,
  type TerminalTheme,
  writeToTerminal,
} from "./tauriTerminal";

type Tab = {
  id: string;
  title: string;
  status: "starting" | "ready" | "offline";
  cwd?: string;
  lastCommand?: string;
  lastExit?: number;
  lastDurationMs?: number;
};

const defaultSettings: TerminalSettings = {
  shellPath: "",
  startupDirectory: "",
  fontFamily: "JetBrains Mono, Cascadia Mono, SFMono-Regular, Consolas, monospace",
  fontSize: 14,
  scrollback: 5000,
  theme: "ziggy",
};

const themeOptions: Array<{ id: TerminalTheme; label: string }> = [
  { id: "ziggy", label: "Ziggy" },
  { id: "ember", label: "Ember" },
  { id: "paper", label: "Paper" },
];

const terminalThemes = {
  ziggy: {
    background: "#111315",
    foreground: "#eef2e2",
    cursor: "#b6f09c",
    selectionBackground: "#344338",
    black: "#111315",
    red: "#ff7b72",
    green: "#9be28f",
    yellow: "#f2cc60",
    blue: "#7aa2f7",
    magenta: "#c792ea",
    cyan: "#69d9df",
    white: "#d6dbc9",
    brightBlack: "#5d645f",
    brightRed: "#ff9b91",
    brightGreen: "#b6f09c",
    brightYellow: "#ffe08a",
    brightBlue: "#9bbbff",
    brightMagenta: "#ddb2ff",
    brightCyan: "#8ff3f7",
    brightWhite: "#ffffff",
  },
  ember: {
    background: "#161311",
    foreground: "#f3e8d4",
    cursor: "#ffb86b",
    selectionBackground: "#46342a",
  },
  paper: {
    background: "#f8f6ef",
    foreground: "#262925",
    cursor: "#2f6f62",
    selectionBackground: "#dbe7dd",
  },
};

function newTab(index: number): Tab {
  return {
    id: `terminal-${Date.now()}-${index}`,
    title: `Shell ${index}`,
    status: "starting",
  };
}

export default function App() {
  const [tabs, setTabs] = useState<Tab[]>(() => [newTab(1)]);
  const [activeTabId, setActiveTabId] = useState(() => tabs[0].id);
  const [settings, setSettings] = useState(defaultSettings);
  const [settingsOpen, setSettingsOpen] = useState(false);
  const activeTab = tabs.find((tab) => tab.id === activeTabId) ?? tabs[0];

  const addTab = useCallback(() => {
    const tab = newTab(tabs.length + 1);
    setTabs((current) => [...current, tab]);
    setActiveTabId(tab.id);
  }, [tabs.length]);

  const closeTab = useCallback(
    (tabId: string) => {
      if (tabs.length === 1) {
        return;
      }

      void closeTerminal(tabId).catch(() => undefined);
      setTabs((current) => current.filter((tab) => tab.id !== tabId));
      if (activeTabId === tabId) {
        const nextTab = tabs.find((tab) => tab.id !== tabId);
        if (nextTab) {
          setActiveTabId(nextTab.id);
        }
      }
    },
    [activeTabId, tabs],
  );

  const updateTabStatus = useCallback((tabId: string, status: Tab["status"]) => {
    setTabs((current) => current.map((tab) => (tab.id === tabId ? { ...tab, status } : tab)));
  }, []);

  const updateTabFromShellEvent = useCallback((tabId: string, event: ShellIntegrationEvent) => {
    setTabs((current) =>
      current.map((tab) => {
        if (tab.id !== tabId) {
          return tab;
        }

        if (event.type === "prompt.rendered") {
          return {
            ...tab,
            cwd: event.cwd ?? tab.cwd,
            lastExit: event.last_status ?? tab.lastExit,
            lastDurationMs: event.last_duration_ms ?? tab.lastDurationMs,
          };
        }

        if (event.type === "command.started") {
          return {
            ...tab,
            lastCommand: event.command ?? tab.lastCommand,
            cwd: event.cwd ?? tab.cwd,
          };
        }

        if (event.type === "command.finished") {
          return {
            ...tab,
            cwd: event.cwd ?? tab.cwd,
            lastExit: event.status ?? tab.lastExit,
            lastDurationMs: event.duration_ms ?? tab.lastDurationMs,
          };
        }

        return tab;
      }),
    );
  }, []);

  return (
    <main className={`app-shell theme-${settings.theme}`}>
      <header className="top-bar">
        <div className="brand">
          <div className="brand-mark">
            <Sparkles size={18} aria-hidden="true" />
          </div>
          <div>
            <h1>ZiggyZag</h1>
            <span>{activeTab?.status === "ready" ? "PTY connected" : "Waiting for PTY bridge"}</span>
          </div>
        </div>

        <div className="window-actions">
          <button type="button" className="icon-button" aria-label="Open settings" onClick={() => setSettingsOpen(true)}>
            <Settings size={18} aria-hidden="true" />
          </button>
        </div>
      </header>

      <section className="tab-strip" aria-label="Terminal tabs">
        {tabs.map((tab) => (
          <button
            type="button"
            key={tab.id}
            className={`tab ${tab.id === activeTabId ? "active" : ""}`}
            onClick={() => setActiveTabId(tab.id)}
          >
            <TerminalSquare size={16} aria-hidden="true" />
            <span>{tab.title}</span>
            <span className={`status-dot ${tab.status}`} aria-label={tab.status} />
            {tabs.length > 1 ? (
              <span
                role="button"
                tabIndex={0}
                className="tab-close"
                aria-label={`Close ${tab.title}`}
                onClick={(event) => {
                  event.stopPropagation();
                  closeTab(tab.id);
                }}
                onKeyDown={(event) => {
                  if (event.key === "Enter" || event.key === " ") {
                    event.preventDefault();
                    event.stopPropagation();
                    closeTab(tab.id);
                  }
                }}
              >
                <X size={14} aria-hidden="true" />
              </span>
            ) : null}
          </button>
        ))}

        <button type="button" className="add-tab" aria-label="New terminal tab" onClick={addTab}>
          <Plus size={17} aria-hidden="true" />
        </button>
      </section>

      <section className="terminal-stack" aria-label="Terminal viewport">
        {tabs.map((tab) => (
          <TerminalPane
            key={tab.id}
            tabId={tab.id}
            active={tab.id === activeTabId}
            settings={settings}
            onStatusChange={updateTabStatus}
            onShellEvent={updateTabFromShellEvent}
          />
        ))}
      </section>

      <footer className="status-bar">
        <span>{activeTab?.title}</span>
        <span>{activeTab?.cwd ?? settings.theme + " theme"}</span>
        <span>{formatExitStatus(activeTab)}</span>
      </footer>

      {settingsOpen ? (
        <SettingsPanel
          settings={settings}
          onChange={setSettings}
          onClose={() => setSettingsOpen(false)}
        />
      ) : null}
    </main>
  );
}

function TerminalPane({
  tabId,
  active,
  settings,
  onStatusChange,
  onShellEvent,
}: {
  tabId: string;
  active: boolean;
  settings: TerminalSettings;
  onStatusChange: (tabId: string, status: Tab["status"]) => void;
  onShellEvent: (tabId: string, event: ShellIntegrationEvent) => void;
}) {
  const containerRef = useRef<HTMLDivElement | null>(null);
  const terminalRef = useRef<Terminal | null>(null);
  const fitAddonRef = useRef<FitAddon | null>(null);

  const xtermTheme = useMemo(() => terminalThemes[settings.theme], [settings.theme]);

  useLayoutEffect(() => {
    if (!active) {
      return;
    }

    requestAnimationFrame(() => {
      fitAddonRef.current?.fit();
      terminalRef.current?.focus();
    });
  }, [active]);

  useEffect(() => {
    const container = containerRef.current;
    if (!container) {
      return;
    }

    const terminal = new Terminal({
      allowProposedApi: false,
      cursorBlink: true,
      fontFamily: settings.fontFamily,
      fontSize: settings.fontSize,
      scrollback: settings.scrollback,
      theme: xtermTheme,
    });
    const fitAddon = new FitAddon();
    terminalRef.current = terminal;
    fitAddonRef.current = fitAddon;

    terminal.loadAddon(fitAddon);
    terminal.open(container);
    fitAddon.fit();
    terminal.focus();

    const size = {
      cols: terminal.cols,
      rows: terminal.rows,
    };

    terminal.writeln("ZiggyZag desktop shell");
    terminal.writeln("Starting PTY bridge...");

    const dataDisposable = terminal.onData((data) => {
      void writeToTerminal(tabId, data).catch(() => {
        terminal.writeln("\r\nUnable to write to PTY backend.");
        onStatusChange(tabId, "offline");
      });
    });

    const resizeObserver = new ResizeObserver(() => {
      fitAddon.fit();
      void resizeTerminal(tabId, terminal.cols, terminal.rows).catch(() => undefined);
    });
    resizeObserver.observe(container);

    void createTerminal(tabId, settings, size)
      .then(() => {
        terminal.clear();
        onStatusChange(tabId, "ready");
      })
      .catch(() => {
        terminal.writeln("PTY backend is not available yet.");
        terminal.writeln("The frontend is ready for create_terminal, write_to_terminal, resize_terminal, close_terminal, and terminal://data.");
        onStatusChange(tabId, "offline");
      });

    let unlisten: (() => void) | undefined;
    void listenForTerminalData((event) => {
      if (event.terminalId === tabId || event.terminalId === "default") {
        for (const shellEvent of extractShellIntegrationEvents(event.data)) {
          onShellEvent(tabId, shellEvent);
        }
        terminal.write(event.data);
      }
    }).then((listener) => {
      unlisten = listener;
    });

    return () => {
      unlisten?.();
      resizeObserver.disconnect();
      dataDisposable.dispose();
      void closeTerminal(tabId).catch(() => undefined);
      terminal.dispose();
    };
  }, [onShellEvent, onStatusChange, settings, tabId, xtermTheme]);

  return (
    <section className={`terminal-frame ${active ? "active" : ""}`} aria-hidden={!active}>
      <div ref={containerRef} className="terminal-viewport" />
    </section>
  );
}

function formatExitStatus(tab: Tab | undefined) {
  if (!tab || tab.lastExit === undefined) {
    return "waiting";
  }

  const duration = tab.lastDurationMs !== undefined ? ` · ${tab.lastDurationMs}ms` : "";
  return `exit ${tab.lastExit}${duration}`;
}

function SettingsPanel({
  settings,
  onChange,
  onClose,
}: {
  settings: TerminalSettings;
  onChange: (settings: TerminalSettings) => void;
  onClose: () => void;
}) {
  const patchSettings = <K extends keyof TerminalSettings>(key: K, value: TerminalSettings[K]) => {
    onChange({ ...settings, [key]: value });
  };

  return (
    <div className="settings-backdrop" role="presentation" onMouseDown={onClose}>
      <aside
        className="settings-panel"
        role="dialog"
        aria-modal="true"
        aria-labelledby="settings-title"
        onMouseDown={(event) => event.stopPropagation()}
      >
        <div className="panel-header">
          <div>
            <h2 id="settings-title">Settings</h2>
            <p>Runtime preferences for newly opened PTY tabs.</p>
          </div>
          <button type="button" className="icon-button" aria-label="Close settings" onClick={onClose}>
            <X size={18} aria-hidden="true" />
          </button>
        </div>

        <label className="field">
          <span>Shell path</span>
          <div className="input-row">
            <Monitor size={16} aria-hidden="true" />
            <input
              value={settings.shellPath}
              placeholder="Use backend default"
              onChange={(event) => patchSettings("shellPath", event.target.value)}
            />
          </div>
        </label>

        <label className="field">
          <span>Startup directory</span>
          <div className="input-row">
            <FolderOpen size={16} aria-hidden="true" />
            <input
              value={settings.startupDirectory}
              placeholder="Use backend default"
              onChange={(event) => patchSettings("startupDirectory", event.target.value)}
            />
          </div>
        </label>

        <label className="field">
          <span>Font family</span>
          <input
            value={settings.fontFamily}
            onChange={(event) => patchSettings("fontFamily", event.target.value)}
          />
        </label>

        <div className="field-grid">
          <label className="field">
            <span>Font size</span>
            <input
              type="number"
              min="11"
              max="24"
              value={settings.fontSize}
              onChange={(event) => patchSettings("fontSize", Number(event.target.value))}
            />
          </label>
          <label className="field">
            <span>Scrollback</span>
            <input
              type="number"
              min="500"
              max="50000"
              step="500"
              value={settings.scrollback}
              onChange={(event) => patchSettings("scrollback", Number(event.target.value))}
            />
          </label>
        </div>

        <div className="field">
          <span>Theme</span>
          <div className="theme-picker">
            {themeOptions.map((theme) => (
              <button
                type="button"
                key={theme.id}
                className={settings.theme === theme.id ? "selected" : ""}
                onClick={() => patchSettings("theme", theme.id)}
              >
                {settings.theme === theme.id ? <Check size={15} aria-hidden="true" /> : null}
                {theme.label}
              </button>
            ))}
          </div>
        </div>
      </aside>
    </div>
  );
}
