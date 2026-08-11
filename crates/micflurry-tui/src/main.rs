use anyhow::{Context, Result};
use crossterm::{
    event::{Event as TerminalEvent, EventStream, KeyCode, KeyEventKind},
    execute, terminal,
};
use futures::StreamExt;
use micflurry_control::{ControlClient, Event, KeyboardAction, Status};
use micflurry_core::{LocalControlClient, RuntimeOptions};
use ratatui::{
    Terminal,
    backend::CrosstermBackend,
    layout::{Constraint, Direction, Layout},
    style::{Color, Modifier, Style},
    text::{Line, Span},
    widgets::{Block, Borders, Gauge, List, ListItem, ListState, Paragraph, Wrap},
};
use std::{
    io::{self, Stdout},
    path::PathBuf,
};

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::from_default_env())
        .with_writer(io::stderr)
        .init();
    let options = parse_options()?;
    let (client, runtime) = micflurry_core::start(options).await?;
    let result = run_ui(client.clone()).await;
    client.shutdown().await;
    runtime.await.context("runtime task failed")?;
    result
}

fn parse_options() -> Result<RuntimeOptions> {
    let mut options = RuntimeOptions::default();
    let mut arguments = std::env::args().skip(1);
    while let Some(argument) = arguments.next() {
        match argument.as_str() {
            "--database" => {
                options.database_path = Some(PathBuf::from(
                    arguments.next().context("--database requires a path")?,
                ));
            }
            "--no-audio" => options.disable_audio = true,
            "--no-bluetooth" => options.disable_bluetooth = true,
            "-h" | "--help" => {
                println!(
                    "MicFlurry foreground TUI\n\nUsage: micflurry [--database PATH] [--no-audio] [--no-bluetooth]"
                );
                std::process::exit(0);
            }
            other => anyhow::bail!("unknown argument {other}"),
        }
    }
    Ok(options)
}

async fn run_ui(client: LocalControlClient) -> Result<()> {
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
    client: LocalControlClient,
) -> Result<()> {
    let mut app = App {
        status: client.status().await?,
        ..App::default()
    };
    let mut runtime_events = client.subscribe();
    let mut terminal_events = EventStream::new();
    client.scan().await.ok();
    loop {
        terminal.draw(|frame| draw(frame, &mut app))?;
        tokio::select! {
            Some(event) = runtime_events.next() => app.apply(event),
            Some(event) = terminal_events.next() => {
                let TerminalEvent::Key(key) = event? else { continue };
                if key.kind != KeyEventKind::Press { continue; }
                match key.code {
                    KeyCode::Char('q') => break,
                    KeyCode::Char('s') => { client.scan().await.ok(); }
                    KeyCode::Up => app.previous(),
                    KeyCode::Down => app.next(),
                    KeyCode::Enter => {
                        if let Some(device) = app.status.devices.get(app.selected)
                            && let Err(error) = client.pair_and_connect(device.id.clone()).await
                        {
                            app.message = error.to_string();
                        }
                    }
                    KeyCode::Char('d') => { client.disconnect().await.ok(); }
                    KeyCode::Char('r') => {
                        let result = if app.status.recording.active { client.stop_recording().await } else { client.start_recording().await };
                        if let Err(error) = result { app.message = error.to_string(); }
                    }
                    KeyCode::Char(' ') => post(&client, &mut app, KeyboardAction::PlayPause).await,
                    KeyCode::Char('[') => post(&client, &mut app, KeyboardAction::Previous).await,
                    KeyCode::Char(']') => post(&client, &mut app, KeyboardAction::Next).await,
                    KeyCode::Char('-') => post(&client, &mut app, KeyboardAction::VolumeDown).await,
                    KeyCode::Char('+' | '=') => post(&client, &mut app, KeyboardAction::VolumeUp).await,
                    KeyCode::Char('m') => post(&client, &mut app, KeyboardAction::Mute).await,
                    _ => {}
                }
            }
        }
    }
    Ok(())
}

async fn post(client: &LocalControlClient, app: &mut App, action: KeyboardAction) {
    if let Err(error) = client.keyboard_action(action).await {
        app.message = error.to_string();
    }
}

#[derive(Default)]
struct App {
    status: Status,
    selected: usize,
    message: String,
}

impl App {
    fn apply(&mut self, event: Event) {
        match event {
            Event::Status(status) => self.status = status,
            Event::Error { message } => self.message = message,
            Event::RecordingStarted { path } => self.message = format!("Recording {path}"),
            Event::RecordingStopped { path, .. } => self.message = format!("Saved {path}"),
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
            if app.status.pairing {
                Span::styled(" · pairing", Style::default().fg(Color::Yellow))
            } else {
                Span::raw("")
            },
        ]))
        .block(Block::default().borders(Borders::ALL)),
        rows[0],
    );

    let columns = Layout::default()
        .direction(Direction::Horizontal)
        .constraints([Constraint::Percentage(55), Constraint::Percentage(45)])
        .split(rows[1]);
    let devices: Vec<ListItem<'_>> = app
        .status
        .devices
        .iter()
        .map(|device| {
            let profile = if device.supports_atvv {
                "ATVV"
            } else {
                "other"
            };
            let known = if device.known { " · paired" } else { "" };
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
        "Stream: {}\nSource: {} Hz → {} Hz\nDecoded: {} samples\nDropped: {} samples\nRecording: {}",
        if audio.active { "active" } else { "idle" },
        audio.source_rate_hz.unwrap_or_default(),
        audio.output_rate_hz,
        audio.decoded_frames,
        audio.dropped_frames,
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

    let level = audio.level_dbfs.unwrap_or(-96.0).clamp(-60.0, 0.0);
    let meter = ((level + 60.0) / 60.0).clamp(0.0, 1.0);
    let details = Layout::default()
        .direction(Direction::Vertical)
        .constraints([Constraint::Length(3), Constraint::Min(3)])
        .split(rows[2]);
    frame.render_widget(
        Gauge::default()
            .block(
                Block::default()
                    .title(" Input level ")
                    .borders(Borders::ALL),
            )
            .ratio(f64::from(meter))
            .label(format!("{level:.1} dBFS"))
            .gauge_style(Style::default().fg(Color::Green)),
        details[0],
    );
    let error = app.status.last_error.as_deref().unwrap_or("none");
    frame.render_widget(
        Paragraph::new(format!("Status: {}\nLast error: {error}", app.message))
            .wrap(Wrap { trim: true })
            .block(Block::default().title(" Events ").borders(Borders::ALL)),
        details[1],
    );

    frame.render_widget(Paragraph::new(" q quit · s scan · ↑/↓ select · enter pair/connect · d disconnect · r record · space/[ ]/-/+/m keys ")
        .style(Style::default().fg(Color::DarkGray)).block(Block::default().borders(Borders::ALL)), rows[3]);
}
