use crate::{
    atvv::{self, Codec, ControlMessage, ImaAdpcmDecoder, MIC_CLOSE_ANY, MIC_OPEN},
    audio::{AudioSink, CoreAudioSink, DisconnectedSink},
    bluetooth::{Bluetooth, BluetoothEvent},
    keyboard,
    recording::Recording,
    resample::LinearResampler,
    storage::Store,
};
use anyhow::Result;
use async_trait::async_trait;
use futures::StreamExt;
use micflurry_control::{
    AudioStatus, BluetoothState, ControlClient, ControlError, DeviceId, Event, EventStream,
    KeyboardAction, RecordingStatus, Settings, SettingsChange, Status,
};
use std::{
    path::PathBuf,
    time::{Duration, Instant},
};
use tokio::{
    sync::{broadcast, mpsc, oneshot},
    task::JoinHandle,
};
use tokio_stream::wrappers::BroadcastStream;

#[derive(Clone, Debug, Default)]
pub struct RuntimeOptions {
    pub database_path: Option<PathBuf>,
    pub disable_audio: bool,
    pub disable_bluetooth: bool,
}

#[derive(Clone)]
pub struct LocalControlClient {
    commands: mpsc::Sender<Command>,
    events: broadcast::Sender<Event>,
}

/// Starts the in-process foreground runtime and returns its local client and task.
///
/// # Errors
///
/// Returns an error if the `SQLite` state database cannot be created or migrated.
pub async fn start(options: RuntimeOptions) -> Result<(LocalControlClient, JoinHandle<()>)> {
    let database_path = options
        .database_path
        .clone()
        .unwrap_or_else(default_database_path);
    let store = Store::open(&database_path)?;
    let settings = store.settings()?;
    let (commands, command_receiver) = mpsc::channel(32);
    let (hardware_sender, hardware_receiver) = mpsc::channel(128);
    let (events, _) = broadcast::channel(256);
    let client = LocalControlClient {
        commands,
        events: events.clone(),
    };
    let handle = tokio::spawn(async move {
        Runtime::new(
            store,
            settings,
            options,
            events,
            hardware_sender,
            hardware_receiver,
        )
        .run(command_receiver)
        .await;
    });
    Ok((client, handle))
}

impl LocalControlClient {
    pub async fn shutdown(&self) {
        let (sender, receiver) = oneshot::channel();
        let _ = self.commands.send(Command::Shutdown(sender)).await;
        let _ = receiver.await;
    }

    async fn request<T>(
        &self,
        build: impl FnOnce(oneshot::Sender<micflurry_control::Result<T>>) -> Command,
    ) -> micflurry_control::Result<T> {
        let (sender, receiver) = oneshot::channel();
        self.commands
            .send(build(sender))
            .await
            .map_err(|_| ControlError::Unavailable)?;
        receiver.await.map_err(|_| ControlError::Unavailable)?
    }
}

#[async_trait]
impl ControlClient for LocalControlClient {
    async fn status(&self) -> micflurry_control::Result<Status> {
        self.request(Command::Status).await
    }
    async fn settings(&self) -> micflurry_control::Result<Settings> {
        self.request(Command::Settings).await
    }
    async fn set_settings(&self, change: SettingsChange) -> micflurry_control::Result<Settings> {
        self.request(|reply| Command::SetSettings(change, reply))
            .await
    }
    async fn scan(&self) -> micflurry_control::Result<()> {
        self.request(Command::Scan).await
    }
    async fn pair_and_connect(&self, device: DeviceId) -> micflurry_control::Result<()> {
        self.request(|reply| Command::Connect(device, reply)).await
    }
    async fn disconnect(&self) -> micflurry_control::Result<()> {
        self.request(Command::Disconnect).await
    }
    async fn start_recording(&self) -> micflurry_control::Result<()> {
        self.request(Command::StartRecording).await
    }
    async fn stop_recording(&self) -> micflurry_control::Result<()> {
        self.request(Command::StopRecording).await
    }
    async fn keyboard_action(&self, action: KeyboardAction) -> micflurry_control::Result<()> {
        self.request(|reply| Command::Keyboard(action, reply)).await
    }
    fn subscribe(&self) -> EventStream {
        Box::pin(
            BroadcastStream::new(self.events.subscribe()).filter_map(|event| async { event.ok() }),
        )
    }
}

enum Command {
    Status(oneshot::Sender<micflurry_control::Result<Status>>),
    Settings(oneshot::Sender<micflurry_control::Result<Settings>>),
    SetSettings(
        SettingsChange,
        oneshot::Sender<micflurry_control::Result<Settings>>,
    ),
    Scan(oneshot::Sender<micflurry_control::Result<()>>),
    Connect(DeviceId, oneshot::Sender<micflurry_control::Result<()>>),
    Disconnect(oneshot::Sender<micflurry_control::Result<()>>),
    StartRecording(oneshot::Sender<micflurry_control::Result<()>>),
    StopRecording(oneshot::Sender<micflurry_control::Result<()>>),
    Keyboard(
        KeyboardAction,
        oneshot::Sender<micflurry_control::Result<()>>,
    ),
    Shutdown(oneshot::Sender<()>),
}

struct Runtime {
    store: Store,
    settings: Settings,
    status: Status,
    bluetooth: Option<Bluetooth>,
    hardware_sender: mpsc::Sender<BluetoothEvent>,
    hardware_receiver: mpsc::Receiver<BluetoothEvent>,
    events: broadcast::Sender<Event>,
    audio_sink: Box<dyn AudioSink>,
    decoder: ImaAdpcmDecoder,
    resampler: LinearResampler,
    codec: Codec,
    recording: Option<Recording>,
    last_audio_event: Instant,
    options: RuntimeOptions,
}

impl Runtime {
    fn new(
        store: Store,
        settings: Settings,
        options: RuntimeOptions,
        events: broadcast::Sender<Event>,
        hardware_sender: mpsc::Sender<BluetoothEvent>,
        hardware_receiver: mpsc::Receiver<BluetoothEvent>,
    ) -> Self {
        let (audio_sink, audio_error) = open_audio(&settings, options.disable_audio);
        let output_rate_hz = settings.output_rate_hz;
        let mut status = Status {
            audio: AudioStatus {
                output_rate_hz: settings.output_rate_hz,
                ..AudioStatus::default()
            },
            ..Status::default()
        };
        status.last_error = audio_error;
        Self {
            store,
            settings,
            status,
            bluetooth: None,
            hardware_sender,
            hardware_receiver,
            events,
            audio_sink,
            decoder: ImaAdpcmDecoder::default(),
            resampler: LinearResampler::new(16_000, output_rate_hz),
            codec: Codec::Adpcm16Khz,
            recording: None,
            last_audio_event: Instant::now()
                .checked_sub(Duration::from_secs(1))
                .expect("one second is representable"),
            options,
        }
    }

    async fn run(mut self, mut commands: mpsc::Receiver<Command>) {
        if self.options.disable_bluetooth {
            self.status.bluetooth = BluetoothState::Unavailable;
        } else {
            match Bluetooth::new().await {
                Ok(bluetooth) => self.bluetooth = Some(bluetooth),
                Err(error) => {
                    self.status.bluetooth = BluetoothState::Unavailable;
                    self.report_error(format!("Bluetooth unavailable: {error:#}"));
                }
            }
        }
        self.publish_status();
        let mut ticker = tokio::time::interval(Duration::from_millis(200));
        loop {
            tokio::select! {
                Some(command) = commands.recv() => {
                    if self.handle_command(command).await { break; }
                }
                Some(event) = self.hardware_receiver.recv() => self.handle_hardware(event).await,
                _ = ticker.tick() => self.publish_status(),
                else => break,
            }
        }
        let _ = self.finish_recording();
        if let Some(bluetooth) = &mut self.bluetooth {
            let _ = bluetooth.disconnect().await;
        }
    }

    async fn handle_command(&mut self, command: Command) -> bool {
        match command {
            Command::Status(reply) => {
                let _ = reply.send(Ok(self.status.clone()));
            }
            Command::Settings(reply) => {
                let _ = reply.send(Ok(self.settings.clone()));
            }
            Command::SetSettings(change, reply) => {
                let result = self.apply_settings(change).map_err(control_failed);
                let _ = reply.send(result);
            }
            Command::Scan(reply) => {
                let result = if let Some(bluetooth) = &self.bluetooth {
                    self.status.bluetooth = BluetoothState::Scanning;
                    bluetooth
                        .start_scan(self.hardware_sender.clone())
                        .await
                        .map_err(control_failed)
                } else {
                    Err(ControlError::Failed("Bluetooth is unavailable".into()))
                };
                let _ = reply.send(result);
            }
            Command::Connect(device, reply) => {
                self.status.pairing = true;
                self.emit(Event::Pairing {
                    device: device.clone(),
                    active: true,
                });
                let result = if let Some(bluetooth) = &mut self.bluetooth {
                    bluetooth
                        .connect(&device, self.hardware_sender.clone())
                        .await
                } else {
                    Err(anyhow::anyhow!("Bluetooth is unavailable"))
                };
                self.status.pairing = false;
                self.emit(Event::Pairing {
                    device: device.clone(),
                    active: false,
                });
                match result {
                    Ok(()) => {
                        self.status.connected_device = Some(device.clone());
                        for item in &mut self.status.devices {
                            item.connected = item.id == device;
                        }
                        if let Some(item) =
                            self.status.devices.iter().find(|item| item.id == device)
                        {
                            let _ = self.store.remember_device(item);
                        }
                        self.emit(Event::Connected { device });
                        let _ = reply.send(Ok(()));
                    }
                    Err(error) => {
                        self.report_error(format!("pair/connect failed: {error:#}"));
                        let _ = reply.send(Err(control_failed(error)));
                    }
                }
            }
            Command::Disconnect(reply) => {
                let result = if let Some(bluetooth) = &mut self.bluetooth {
                    let _ = bluetooth.write_command(&MIC_CLOSE_ANY).await;
                    bluetooth.disconnect().await
                } else {
                    Ok(())
                };
                if result.is_ok() {
                    self.mark_disconnected();
                }
                let _ = reply.send(result.map_err(control_failed));
            }
            Command::StartRecording(reply) => {
                let result = self.begin_recording().map_err(control_failed);
                let _ = reply.send(result);
            }
            Command::StopRecording(reply) => {
                let result = self.finish_recording().map(|_| ()).map_err(control_failed);
                let _ = reply.send(result);
            }
            Command::Keyboard(action, reply) => {
                let _ = reply.send(keyboard::post(action).map_err(control_failed));
            }
            Command::Shutdown(reply) => {
                let _ = reply.send(());
                return true;
            }
        }
        false
    }

    async fn handle_hardware(&mut self, event: BluetoothEvent) {
        match event {
            BluetoothEvent::ScanComplete(mut devices) => {
                for device in &mut devices {
                    device.known = self.store.is_known(&device.id.0).unwrap_or(false);
                    self.emit(Event::DeviceDiscovered {
                        device: device.clone(),
                    });
                }
                self.status.devices = devices;
                self.status.bluetooth = BluetoothState::Idle;
            }
            BluetoothEvent::Control(bytes) => self.handle_atvv_control(&bytes).await,
            BluetoothEvent::Audio(bytes) => self.handle_audio(&bytes),
            BluetoothEvent::Disconnected(device) => {
                self.mark_disconnected();
                self.emit(Event::Disconnected { device });
            }
            BluetoothEvent::Error(message) => {
                self.status.bluetooth = BluetoothState::Idle;
                self.report_error(message);
            }
        }
    }

    async fn handle_atvv_control(&mut self, bytes: &[u8]) {
        match atvv::parse_control(bytes) {
            Ok(ControlMessage::AudioStart { codec, .. }) => {
                self.codec = codec;
                self.decoder.reset();
                self.resampler
                    .reconfigure(codec.sample_rate(), self.settings.output_rate_hz);
                self.status.audio.active = true;
                self.status.audio.source_rate_hz = Some(codec.sample_rate());
                if self.settings.auto_record && self.recording.is_none() {
                    let _ = self.begin_recording();
                }
                self.emit(Event::AudioStarted {
                    rate_hz: codec.sample_rate(),
                });
            }
            Ok(ControlMessage::AudioSync {
                codec,
                predictor,
                step_index,
                ..
            }) => {
                if let Err(error) = self.decoder.synchronize(predictor, step_index) {
                    self.report_error(error.to_string());
                    return;
                }
                if codec != self.codec {
                    self.codec = codec;
                    self.resampler
                        .reconfigure(codec.sample_rate(), self.settings.output_rate_hz);
                    self.status.audio.source_rate_hz = Some(codec.sample_rate());
                }
            }
            Ok(ControlMessage::AudioStop { .. }) => {
                self.status.audio.active = false;
                self.emit(Event::AudioStopped);
                if self.settings.auto_record {
                    let _ = self.finish_recording();
                }
            }
            Ok(ControlMessage::StartSearch) => {
                if let Some(bluetooth) = &self.bluetooth
                    && let Err(error) = bluetooth.write_command(&MIC_OPEN).await
                {
                    self.report_error(format!("request ATVV audio: {error:#}"));
                }
            }
            Ok(ControlMessage::MicOpenError { code }) => self.report_error(format!(
                "ATVV remote rejected microphone open: 0x{code:04x}"
            )),
            Ok(ControlMessage::Capabilities { .. } | ControlMessage::Unknown { .. }) => {}
            Err(error) => self.report_error(format!("invalid ATVV control notification: {error}")),
        }
    }

    fn handle_audio(&mut self, bytes: &[u8]) {
        if !self.status.audio.active {
            return;
        }
        let decoded = self.decoder.decode(bytes);
        self.status.audio.decoded_frames += decoded.len() as u64;
        let samples = self.resampler.process_i16(&decoded);
        let peak = samples
            .iter()
            .fold(0.0_f32, |value, sample| value.max(sample.abs()));
        let level = if peak > 0.0 {
            20.0 * peak.log10()
        } else {
            -96.0
        };
        self.status.audio.level_dbfs = Some(level.max(-96.0));
        self.audio_sink.push(&samples);
        self.status.audio.dropped_frames = self.audio_sink.dropped_samples();
        let recording_result = self.recording.as_mut().map(|recording| {
            let result = recording.write(&samples);
            (result, recording.sample_count)
        });
        if let Some((result, count)) = recording_result {
            self.status.recording.sample_count = count;
            if let Err(error) = result {
                self.report_error(format!("recording write failed: {error:#}"));
            }
        }
        if self.last_audio_event.elapsed() >= Duration::from_millis(100) {
            self.last_audio_event = Instant::now();
            self.emit(Event::AudioLevel { dbfs: level });
        }
    }

    fn apply_settings(&mut self, change: SettingsChange) -> Result<Settings> {
        let previous = self.settings.clone();
        self.settings = self.store.update_settings(change)?;
        if previous.output_rate_hz != self.settings.output_rate_hz
            || previous.injection_device_uid != self.settings.injection_device_uid
        {
            let (sink, error) = open_audio(&self.settings, self.options.disable_audio);
            self.audio_sink = sink;
            self.status.last_error = error;
            self.status.audio.output_rate_hz = self.settings.output_rate_hz;
            self.resampler
                .reconfigure(self.codec.sample_rate(), self.settings.output_rate_hz);
        }
        Ok(self.settings.clone())
    }

    fn begin_recording(&mut self) -> Result<()> {
        if self.recording.is_some() {
            return Ok(());
        }
        let recording = Recording::create(
            PathBuf::from(&self.settings.recording_directory).as_path(),
            self.settings.output_rate_hz,
        )?;
        let path = recording.path.to_string_lossy().into_owned();
        self.status.recording = RecordingStatus {
            active: true,
            path: Some(path.clone()),
            sample_count: 0,
        };
        self.recording = Some(recording);
        self.emit(Event::RecordingStarted { path });
        Ok(())
    }

    fn finish_recording(&mut self) -> Result<Option<String>> {
        let Some(recording) = self.recording.take() else {
            return Ok(None);
        };
        self.status.recording = RecordingStatus::default();
        let finished = recording.finish()?;
        let path = finished.path.to_string_lossy().into_owned();
        let device = self
            .status
            .connected_device
            .as_ref()
            .map(|id| id.0.as_str());
        self.store.add_recording(
            &path,
            device,
            finished.sample_rate,
            finished.sample_count,
            &finished.started_at.to_rfc3339(),
            &finished.finished_at.to_rfc3339(),
        )?;
        self.emit(Event::RecordingStopped {
            path: path.clone(),
            sample_count: finished.sample_count,
        });
        Ok(Some(path))
    }

    fn mark_disconnected(&mut self) {
        if self.status.audio.active {
            self.emit(Event::AudioStopped);
        }
        self.status.connected_device = None;
        self.status.audio.active = false;
        for device in &mut self.status.devices {
            device.connected = false;
        }
    }

    fn report_error(&mut self, message: String) {
        self.status.last_error = Some(message.clone());
        self.emit(Event::Error { message });
    }

    fn publish_status(&self) {
        self.emit(Event::Status(self.status.clone()));
    }
    fn emit(&self, event: Event) {
        let _ = self.events.send(event);
    }
}

fn open_audio(settings: &Settings, disabled: bool) -> (Box<dyn AudioSink>, Option<String>) {
    if disabled {
        return (Box::new(DisconnectedSink::new()), None);
    }
    match CoreAudioSink::open(&settings.injection_device_uid, settings.output_rate_hz) {
        Ok(sink) => (Box::new(sink), None),
        Err(error) => (
            Box::new(DisconnectedSink::new()),
            Some(format!("CoreAudio unavailable: {error:#}")),
        ),
    }
}

fn default_database_path() -> PathBuf {
    dirs::data_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join("MicFlurry/micflurry.db")
}

#[allow(clippy::needless_pass_by_value)]
fn control_failed(error: anyhow::Error) -> ControlError {
    ControlError::Failed(format!("{error:#}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn local_client_round_trips_settings_without_hardware() {
        let directory = tempfile::tempdir().unwrap();
        let (client, handle) = start(RuntimeOptions {
            database_path: Some(directory.path().join("state.db")),
            disable_audio: true,
            disable_bluetooth: true,
        })
        .await
        .unwrap();
        let settings = client
            .set_settings(SettingsChange {
                auto_record: Some(true),
                ..SettingsChange::default()
            })
            .await
            .unwrap();
        assert!(settings.auto_record);
        client.shutdown().await;
        handle.await.unwrap();
    }
}
