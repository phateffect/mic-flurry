use anyhow::{Context, Result};
use control::{
    AudioStatus, ControlClient, DeviceInfo, Event, HidStatus, KeyboardAction, KeyboardSource,
    SettingsChange, SocketControlClient, Status,
};
use crossterm::{
    event::{Event as TerminalEvent, EventStream, KeyCode, KeyEventKind},
    execute, terminal,
};
use futures::StreamExt;
use ratatui::{
    Terminal,
    backend::CrosstermBackend,
    layout::{Constraint, Direction, Layout},
    style::{Color, Modifier, Style},
    text::{Line, Span},
    widgets::{Block, Borders, List, ListItem, ListState, Paragraph, Wrap},
};
use std::{
    fs::OpenOptions,
    io::{self, Stdout},
    path::PathBuf,
    sync::{Arc, Mutex, MutexGuard},
};
use tracing_subscriber::fmt::MakeWriter;

mod control;

#[tokio::main]
async fn main() -> Result<()> {
    let log_writer = std::env::var_os("MICFLURRY_LOG")
        .map(PathBuf::from)
        .map(|path| FileMakeWriter::open(&path))
        .transpose()?;
    tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::from_default_env())
        .with_ansi(log_writer.is_none())
        .with_writer(
            log_writer.map_or_else(|| FileMakeWriter::stderr().boxed(), FileMakeWriter::boxed),
        )
        .init();
    let client = SocketControlClient::new(parse_socket_path()?);
    run_ui(client).await
}

#[derive(Clone)]
struct FileMakeWriter {
    file: Arc<Mutex<Box<dyn io::Write + Send>>>,
}

impl FileMakeWriter {
    fn open(path: &PathBuf) -> Result<Self> {
        let file = OpenOptions::new()
            .create(true)
            .append(true)
            .open(path)
            .with_context(|| format!("open log file {}", path.display()))?;
        Ok(Self {
            file: Arc::new(Mutex::new(Box::new(file))),
        })
    }

    fn stderr() -> Self {
        Self {
            file: Arc::new(Mutex::new(Box::new(io::stderr()))),
        }
    }

    fn boxed(self) -> tracing_subscriber::fmt::writer::BoxMakeWriter {
        tracing_subscriber::fmt::writer::BoxMakeWriter::new(self)
    }
}

struct FileWriterGuard<'a>(MutexGuard<'a, Box<dyn io::Write + Send>>);

impl io::Write for FileWriterGuard<'_> {
    fn write(&mut self, buffer: &[u8]) -> io::Result<usize> {
        self.0.write(buffer)
    }

    fn flush(&mut self) -> io::Result<()> {
        self.0.flush()
    }
}

impl<'a> MakeWriter<'a> for FileMakeWriter {
    type Writer = FileWriterGuard<'a>;

    fn make_writer(&'a self) -> Self::Writer {
        FileWriterGuard(self.file.lock().expect("log writer lock poisoned"))
    }
}

fn parse_socket_path() -> Result<PathBuf> {
    let mut socket_path =
        SocketControlClient::default_socket_path().map_err(|error| anyhow::anyhow!(error))?;
    let mut arguments = std::env::args().skip(1);
    while let Some(argument) = arguments.next() {
        match argument.as_str() {
            "--socket" => {
                socket_path = PathBuf::from(arguments.next().context("--socket requires a path")?);
            }
            "-h" | "--help" => {
                println!(
                    "MicFlurry daemon TUI\n\nUsage: micflurry [--socket PATH]\n\nClosing the TUI does not stop the MicFlurry daemon, Bluetooth, audio, recording, or HID capture."
                );
                std::process::exit(0);
            }
            other => anyhow::bail!("unknown argument {other}"),
        }
    }
    Ok(socket_path)
}

async fn run_ui(client: SocketControlClient) -> Result<()> {
    let mut terminal = setup_terminal()?;
    let result = event_loop(&mut terminal, client).await;
    restore_terminal(&mut terminal)?;
    result
}

fn setup_terminal() -> Result<Terminal<CrosstermBackend<Stdout>>> {
    terminal::enable_raw_mode()?;
    let mut stdout = io::stdout();
    execute!(stdout, terminal::EnterAlternateScreen)?;
    Ok(Terminal::new(CrosstermBackend::new(stdout))?)
}

fn restore_terminal(terminal: &mut Terminal<CrosstermBackend<Stdout>>) -> Result<()> {
    terminal::disable_raw_mode()?;
    execute!(terminal.backend_mut(), terminal::LeaveAlternateScreen)?;
    terminal.show_cursor()?;
    Ok(())
}

async fn event_loop(
    terminal: &mut Terminal<CrosstermBackend<Stdout>>,
    client: SocketControlClient,
) -> Result<()> {
    let mut app = App {
        status: client.status().await?,
        input_gain_db: client.settings().await?.input_gain_db,
        ..App::default()
    };
    let mut runtime_events = client.subscribe();
    let mut terminal_events = EventStream::new();
    loop {
        terminal.draw(|frame| draw(frame, &mut app))?;
        tokio::select! {
            Some(event) = runtime_events.next() => app.apply(event),
            Some(event) = terminal_events.next() => {
                let TerminalEvent::Key(key) = event? else { continue };
                if key.kind != KeyEventKind::Press { continue; }
                match key.code {
                    KeyCode::Char('q') => break,
                    KeyCode::Char('s') => {
                        let client = client.clone();
                        tokio::spawn(async move { let _ = client.refresh_devices().await; });
                    }
                    KeyCode::Up => app.previous(),
                    KeyCode::Down => app.next(),
                    KeyCode::Enter => {
                        if let Some(device) = app.status.devices.get(app.selected)
                            && device.support.is_supported()
                        {
                            let client = client.clone();
                            let device = device.id.clone();
                            tokio::spawn(async move {
                                let _ = client.connect(device).await;
                            });
                        }
                    }
                    KeyCode::Char('d') => {
                        let client = client.clone();
                        tokio::spawn(async move { let _ = client.release().await; });
                    }
                    KeyCode::Char('r') => {
                        let result = if app.status.recording.active { client.stop_recording().await } else { client.start_recording().await };
                        if let Err(error) = result { app.message = error.to_string(); }
                    }
                    KeyCode::Char('h') => {
                        let result = if app.status.hid.active { client.stop_hid_capture().await } else { client.start_hid_capture().await };
                        if let Err(error) = result { app.message = error.to_string(); }
                    }
                    KeyCode::Char('<' | ',') => adjust_gain(&client, &mut app, -1.0).await,
                    KeyCode::Char('>' | '.') => adjust_gain(&client, &mut app, 1.0).await,
                    _ => {}
                }
            }
        }
    }
    Ok(())
}

async fn adjust_gain(client: &SocketControlClient, app: &mut App, delta_db: f32) {
    let gain_db = (app.input_gain_db + delta_db).clamp(-24.0, 24.0);
    match client
        .set_settings(SettingsChange {
            input_gain_db: Some(gain_db),
            ..SettingsChange::default()
        })
        .await
    {
        Ok(settings) => {
            app.input_gain_db = settings.input_gain_db;
            app.message = format!("Input gain: {:+.0} dB", settings.input_gain_db);
        }
        Err(error) => app.message = error.to_string(),
    }
}

#[derive(Default)]
struct App {
    status: Status,
    selected: usize,
    message: String,
    input_gain_db: f32,
}

impl App {
    fn apply(&mut self, event: Event) {
        match event {
            Event::Status { status } => {
                let mut status = *status;
                // recent_outputs is accumulated locally from keyboard_output events;
                // the daemon's status broadcast does not carry it, so keep ours.
                status.hid.recent_outputs = std::mem::take(&mut self.status.hid.recent_outputs);
                self.status = status;
            }
            Event::Attaching { active, .. } => self.status.attaching = active,
            Event::Error { message } => self.message = message,
            Event::RecordingStarted { path } => self.message = format!("Recording {path}"),
            Event::RecordingStopped { path, .. } => self.message = format!("Saved {path}"),
            Event::HidInput { input } => {
                push_recent(&mut self.status.hid.recent_inputs, input, 12);
            }
            Event::KeyboardOutput { output } => {
                push_recent(&mut self.status.hid.recent_outputs, output, 12);
            }
            _ => {}
        }
        self.selected = self
            .selected
            .min(self.status.devices.len().saturating_sub(1));
    }

    fn previous(&mut self) {
        self.selected = self.selected.saturating_sub(1);
    }
    fn next(&mut self) {
        if self.selected + 1 < self.status.devices.len() {
            self.selected += 1;
        }
    }
}

#[allow(clippy::too_many_lines)]
fn draw(frame: &mut ratatui::Frame<'_>, app: &mut App) {
    let rows = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Length(3),
            Constraint::Min(8),
            Constraint::Length(7),
            Constraint::Length(3),
            Constraint::Length(3),
        ])
        .split(frame.area());
    let connection = app
        .status
        .connected_device
        .as_ref()
        .map_or("not connected".into(), |id| format!("connected: {id}"));
    frame.render_widget(
        Paragraph::new(Line::from(vec![
            Span::styled(
                " MicFlurry ",
                Style::default()
                    .fg(Color::Black)
                    .bg(Color::Cyan)
                    .add_modifier(Modifier::BOLD),
            ),
            Span::raw(format!("  {:?} · {connection}", app.status.bluetooth)),
            if app.status.attaching {
                Span::styled(" · attaching", Style::default().fg(Color::Yellow))
            } else {
                Span::raw("")
            },
        ]))
        .block(Block::default().borders(Borders::ALL)),
        rows[0],
    );

    let columns = Layout::default()
        .direction(Direction::Horizontal)
        .constraints([Constraint::Percentage(45), Constraint::Percentage(55)])
        .split(rows[1]);
    let devices: Vec<ListItem<'_>> = app
        .status
        .devices
        .iter()
        .map(|device| {
            let profile = if device.support.is_supported() {
                device.support.model().unwrap_or("supported")
            } else if device.supports_atvv {
                "unsupported ATVV"
            } else {
                "other"
            };
            let known = if device.known { " · remembered" } else { "" };
            ListItem::new(format!(
                "{}  [{} · {} dBm{}]",
                device.name,
                profile,
                device.rssi.unwrap_or_default(),
                known
            ))
        })
        .collect();
    let mut state =
        ListState::default().with_selected((!devices.is_empty()).then_some(app.selected));
    frame.render_stateful_widget(
        List::new(devices)
            .highlight_symbol("› ")
            .highlight_style(
                Style::default()
                    .fg(Color::Cyan)
                    .add_modifier(Modifier::BOLD),
            )
            .block(
                Block::default()
                    .title(" Bluetooth devices ")
                    .borders(Borders::ALL),
            ),
        columns[0],
        &mut state,
    );

    let audio = &app.status.audio;
    let audio_text = format!(
        "{} · {} · {}→{} Hz · {:+.0} dB\nATVV {} · codec {} · model {} · frame {} B\nN: {} · {} B · sizes {}\nSync: {} · last {} · gap {} · lost {}\nPCM: {} · sink lost {} · stream {} · ext {}\nLevel: {:.1} dBFS · stop {} · rec {}",
        if audio.active { "active" } else { "idle" },
        format_duration(audio.session_duration_ms),
        audio.source_rate_hz.unwrap_or_default(),
        audio.output_rate_hz,
        app.input_gain_db,
        audio
            .protocol_version
            .map_or_else(|| "unknown".into(), format_atvv_version),
        audio
            .negotiated_codecs
            .map_or_else(|| "-".into(), |value| format!("0x{value:02x}")),
        audio
            .interaction_model
            .map_or_else(|| "-".into(), |value| value.to_string()),
        audio
            .frame_size
            .map_or_else(|| "-".into(), |value| value.to_string()),
        audio.notification_count,
        audio.notification_bytes,
        format_notification_sizes(audio),
        audio.audio_sync_count,
        audio
            .last_sync_frame
            .map_or_else(|| "-".into(), |value| value.to_string()),
        audio
            .last_sync_gap_frames
            .map_or_else(|| "-".into(), |value| format!("{value:+}")),
        audio.injected_notification_drops,
        audio.decoded_frames,
        audio.dropped_frames,
        audio
            .stream_id
            .map_or_else(|| "-".into(), |id| format!("0x{id:02x}")),
        audio.mic_extends_sent,
        audio.level_dbfs.unwrap_or(-96.0),
        audio
            .last_stop_reason
            .map_or_else(|| "-".into(), format_stop_reason),
        if app.status.recording.active {
            format!("{} samples", app.status.recording.sample_count)
        } else {
            "off".into()
        },
    );
    frame.render_widget(
        Paragraph::new(audio_text)
            .block(Block::default().title(" Audio path ").borders(Borders::ALL)),
        columns[1],
    );

    let diagnostics = Layout::default()
        .direction(Direction::Horizontal)
        .constraints([
            Constraint::Percentage(34),
            Constraint::Percentage(33),
            Constraint::Percentage(33),
        ])
        .split(rows[2]);
    frame.render_widget(
        Paragraph::new(format_device_info(app.status.device_info.as_ref())).block(
            Block::default()
                .title(" Device info ")
                .borders(Borders::ALL),
        ),
        diagnostics[0],
    );
    frame.render_widget(
        Paragraph::new(format_hid_status(&app.status.hid))
            .block(Block::default().title(" HID input ").borders(Borders::ALL)),
        diagnostics[1],
    );
    frame.render_widget(
        Paragraph::new(format_cgevent_outputs(&app.status.hid)).block(
            Block::default()
                .title(" CGEvent output ")
                .borders(Borders::ALL),
        ),
        diagnostics[2],
    );

    let error = app.status.last_error.as_deref().unwrap_or("none");
    frame.render_widget(
        Paragraph::new(format!("Status: {} · Error: {error}", app.message))
            .wrap(Wrap { trim: true })
            .block(Block::default().title(" Events ").borders(Borders::ALL)),
        rows[3],
    );

    frame.render_widget(Paragraph::new(" q quit · s refresh macOS · ↑/↓ select · enter attach · d release · r record · h HID · </> gain ")
        .style(Style::default().fg(Color::DarkGray)).block(Block::default().borders(Borders::ALL)), rows[4]);
}

fn format_atvv_version(version: u16) -> String {
    format!("{}.{}", version >> 8, version & 0xff)
}

fn format_duration(duration_ms: u64) -> String {
    let total_seconds = duration_ms / 1_000;
    format!(
        "{:02}:{:02}.{:01}",
        total_seconds / 60,
        total_seconds % 60,
        (duration_ms % 1_000) / 100
    )
}

fn format_stop_reason(reason: u8) -> String {
    let name = match reason {
        0x00 => "mic close",
        0x02 => "button release",
        0x04 => "new stream",
        0x08 => "transfer timeout",
        0x10 => "notifications disabled",
        _ => "other",
    };
    format!("0x{reason:02x} {name}")
}

fn format_notification_sizes(audio: &AudioStatus) -> String {
    if audio.notification_sizes.is_empty() {
        return "-".into();
    }
    audio
        .notification_sizes
        .iter()
        .map(|size| format!("{}×{}", size.bytes, size.count))
        .collect::<Vec<_>>()
        .join(",")
}

fn format_device_info(info: Option<&DeviceInfo>) -> String {
    let Some(info) = info else {
        return "Attach a supported remote to read GATT and IOHID identity.".into();
    };
    format!(
        "GATT: {} · {}\nFW/HW/SW: {} / {} / {}\nSerial: {}\nHID: {} · {}\nVID:PID {}:{} · v{} · {} · MTU {}",
        info.manufacturer_name.as_deref().unwrap_or("-"),
        info.model_number.as_deref().unwrap_or("-"),
        info.firmware_revision.as_deref().unwrap_or("-"),
        info.hardware_revision.as_deref().unwrap_or("-"),
        info.software_revision.as_deref().unwrap_or("-"),
        info.serial_number.as_deref().unwrap_or("-"),
        info.hid_manufacturer.as_deref().unwrap_or("-"),
        info.hid_product.as_deref().unwrap_or("-"),
        format_optional_hex(info.hid_vendor_id),
        format_optional_hex(info.hid_product_id),
        format_optional_hex(info.hid_version_number),
        info.hid_transport.as_deref().unwrap_or("-"),
        info.att_mtu
            .map_or_else(|| "-".into(), |value| value.to_string()),
    )
}

fn format_hid_status(hid: &HidStatus) -> String {
    let mut lines = vec![format!(
        "Mode: {:?} · {}{}",
        hid.mode,
        if hid.active { "active" } else { "inactive" },
        hid.last_error
            .as_ref()
            .map_or_else(String::new, |error| format!(" · {error}"))
    )];
    lines.extend(hid.recent_inputs.iter().rev().take(4).map(|input| {
        format!(
            "IN #{:04} {:04x}/{:04x} {}={} {}{}",
            input.sequence,
            input.usage_page,
            input.usage,
            input.usage_name,
            input.value,
            if input.pressed { "press" } else { "release" },
            input
                .mapped_action
                .map_or_else(String::new, |action| format!(
                    " → {}",
                    keyboard_action_label(action)
                ))
        )
    }));
    lines.join("\n")
}

fn format_cgevent_outputs(hid: &HidStatus) -> String {
    if hid.recent_outputs.is_empty() {
        return "No CGEvent posted yet.".into();
    }
    hid.recent_outputs
        .iter()
        .rev()
        .take(5)
        .map(|output| {
            format!(
                "OUT #{:04} {} → {} {}{}",
                output.sequence,
                keyboard_source_label(output.source),
                keyboard_action_label(output.action),
                if output.succeeded { "sent" } else { "failed" },
                output
                    .error
                    .as_ref()
                    .map_or_else(String::new, |error| format!(" · {error}"))
            )
        })
        .collect::<Vec<_>>()
        .join("\n")
}

fn keyboard_source_label(source: KeyboardSource) -> &'static str {
    match source {
        KeyboardSource::Tui => "tui",
        KeyboardSource::Hid => "hid",
        KeyboardSource::Audio => "audio",
    }
}

fn keyboard_action_label(action: KeyboardAction) -> &'static str {
    match action {
        KeyboardAction::Up => "up",
        KeyboardAction::Down => "down",
        KeyboardAction::Left => "left",
        KeyboardAction::Right => "right",
        KeyboardAction::Select => "select",
        KeyboardAction::Back => "back",
        KeyboardAction::Home => "home",
        KeyboardAction::PlayPause => "play_pause",
        KeyboardAction::Previous => "previous",
        KeyboardAction::Next => "next",
        KeyboardAction::VolumeDown => "volume_down",
        KeyboardAction::VolumeUp => "volume_up",
        KeyboardAction::Mute => "mute",
        KeyboardAction::DictationStart => "dictation_start fn+ctrl",
        KeyboardAction::DictationEnd => "dictation_end fn",
    }
}

fn format_optional_hex(value: Option<u32>) -> String {
    value.map_or_else(|| "-".into(), |value| format!("0x{value:04x}"))
}

fn push_recent<T>(items: &mut Vec<T>, item: T, limit: usize) {
    if items.len() == limit {
        items.remove(0);
    }
    items.push(item);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn formats_session_duration_to_tenths() {
        assert_eq!(format_duration(0), "00:00.0");
        assert_eq!(format_duration(60_080), "01:00.0");
        assert_eq!(format_duration(125_987), "02:05.9");
    }
}
