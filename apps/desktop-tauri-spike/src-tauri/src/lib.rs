use portable_pty::{native_pty_system, Child, CommandBuilder, MasterPty, PtySize};
use serde::Serialize;
use std::{
    collections::HashMap,
    env,
    io::{Read, Write},
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
    thread,
};
use tauri::{AppHandle, Emitter, Manager, State};

type TerminalMap = Arc<Mutex<HashMap<String, TerminalProcess>>>;

struct TerminalProcess {
    master: Box<dyn MasterPty + Send>,
    writer: Box<dyn Write + Send>,
    child: Box<dyn Child + Send>,
}

#[derive(Default)]
struct Terminals(TerminalMap);

#[derive(Serialize, Clone)]
struct TerminalData {
    id: String,
    data: String,
}

#[tauri::command]
fn create_terminal(
    app: AppHandle,
    terminals: State<'_, Terminals>,
    terminal_id: String,
    shell_path: Option<String>,
    startup_directory: Option<String>,
    cols: u16,
    rows: u16,
) -> Result<(), String> {
    if let Some(mut terminal) = terminals.0.lock().map_err(lock_error)?.remove(&terminal_id) {
        let _ = terminal.child.kill();
        let _ = terminal.child.wait();
    }

    let shell = resolve_shell(shell_path)?;
    let size = PtySize {
        rows: rows.max(1),
        cols: cols.max(1),
        pixel_width: 0,
        pixel_height: 0,
    };

    let pty_system = native_pty_system();
    let pair = pty_system.openpty(size).map_err(|error| error.to_string())?;
    let mut command = CommandBuilder::new(shell);
    command.env("ZIGGYZAG_APP", "1");
    command.env("ZIGGYZAG_INTEGRATION", "1");
    command.env("TERM", "xterm-256color");

    if let Some(directory) = startup_directory.filter(|value| !value.trim().is_empty()) {
        command.cwd(PathBuf::from(directory));
    }

    let child = pair
        .slave
        .spawn_command(command)
        .map_err(|error| error.to_string())?;
    drop(pair.slave);

    let mut reader = pair
        .master
        .try_clone_reader()
        .map_err(|error| error.to_string())?;
    let writer = pair.master.take_writer().map_err(|error| error.to_string())?;
    let terminal_id_for_reader = terminal_id.clone();
    let app_for_reader = app.clone();

    thread::spawn(move || {
        let mut buffer = [0_u8; 8192];
        loop {
            match reader.read(&mut buffer) {
                Ok(0) => break,
                Ok(count) => {
                    let data = String::from_utf8_lossy(&buffer[..count]).to_string();
                    let _ = app_for_reader.emit(
                        "terminal://data",
                        TerminalData {
                            id: terminal_id_for_reader.clone(),
                            data,
                        },
                    );
                }
                Err(_) => break,
            }
        }
    });

    terminals.0.lock().map_err(lock_error)?.insert(
        terminal_id,
        TerminalProcess {
            master: pair.master,
            writer,
            child,
        },
    );

    Ok(())
}

#[tauri::command]
fn write_to_terminal(
    terminals: State<'_, Terminals>,
    terminal_id: String,
    data: String,
) -> Result<(), String> {
    let mut terminals = terminals.0.lock().map_err(lock_error)?;
    let terminal = terminals
        .get_mut(&terminal_id)
        .ok_or_else(|| format!("terminal not found: {terminal_id}"))?;
    terminal
        .writer
        .write_all(data.as_bytes())
        .map_err(|error| error.to_string())?;
    terminal.writer.flush().map_err(|error| error.to_string())
}

#[tauri::command]
fn resize_terminal(
    terminals: State<'_, Terminals>,
    terminal_id: String,
    cols: u16,
    rows: u16,
) -> Result<(), String> {
    let mut terminals = terminals.0.lock().map_err(lock_error)?;
    let terminal = terminals
        .get_mut(&terminal_id)
        .ok_or_else(|| format!("terminal not found: {terminal_id}"))?;
    terminal
        .master
        .resize(PtySize {
            rows: rows.max(1),
            cols: cols.max(1),
            pixel_width: 0,
            pixel_height: 0,
        })
        .map_err(|error| error.to_string())
}

#[tauri::command]
fn close_terminal(terminals: State<'_, Terminals>, terminal_id: String) -> Result<(), String> {
    if let Some(mut terminal) = terminals.0.lock().map_err(lock_error)?.remove(&terminal_id) {
        let _ = terminal.child.kill();
        let _ = terminal.child.wait();
    }
    Ok(())
}

fn resolve_shell(shell_path: Option<String>) -> Result<PathBuf, String> {
    if let Some(path) = shell_path.filter(|value| !value.trim().is_empty()) {
        return Ok(PathBuf::from(path));
    }

    if let Ok(path) = env::var("ZIGGYZAG_SHELL_PATH") {
        if !path.trim().is_empty() {
            return Ok(PathBuf::from(path));
        }
    }

    let manifest_dir = Path::new(env!("CARGO_MANIFEST_DIR"));
    let repo_root = manifest_dir
        .parent()
        .and_then(Path::parent)
        .and_then(Path::parent)
        .ok_or_else(|| "unable to resolve repository root".to_string())?;
    let binary_name = if cfg!(windows) {
        "ziggyzag.exe"
    } else {
        "ziggyzag"
    };
    let candidate = repo_root.join("zig-out").join("bin").join(binary_name);
    if candidate.exists() {
        return Ok(candidate);
    }

    Err(format!(
        "could not find ZiggyZag shell at {}. Run `zig build` or set ZIGGYZAG_SHELL_PATH.",
        candidate.display()
    ))
}

fn lock_error<T>(_: std::sync::PoisonError<T>) -> String {
    "terminal state lock poisoned".to_string()
}

pub fn run() {
    tauri::Builder::default()
        .manage(Terminals::default())
        .invoke_handler(tauri::generate_handler![
            create_terminal,
            write_to_terminal,
            resize_terminal,
            close_terminal
        ])
        .setup(|app| {
            let _ = app.app_handle().emit(
                "terminal://data",
                TerminalData {
                    id: "default".to_string(),
                    data: String::new(),
                },
            );
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running ZiggyZag desktop");
}
