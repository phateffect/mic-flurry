use crate::{
    atvv::{
        self, Codec, ControlMessage, ImaAdpcmDecoder, MIC_CLOSE_ANY, MIC_OPEN, mic_close,
        mic_extend,
    },
    audio::{AudioSink, CoreAudioSink, DisconnectedSink},
    bluetooth::{Bluetooth, BluetoothEvent},
    hid_identity::HidMonitor,
    keyboard,
    recording::Recording,
    resample::LinearResampler,
    storage::Store,
};
use anyhow::{Context, Result};
use async_trait::async_trait;
use futures::StreamExt;
use micflurry_control::{
    AudioStatus, BluetoothState, ControlClient, ControlError, DeviceId, Event, EventStream,
    HidCaptureMode, HidInput, KeyboardAction, KeyboardOutput, KeyboardSource,
    NotificationSizeCount, RecordingStatus, Settings, SettingsChange, Status,
};
use std::{
    collections::BTreeMap,
    path::PathBuf,
    time::{Duration, Instant},
};
use tokio::{
    sync::{broadcast, mpsc, oneshot},
    task::JoinHandle,
};
use tokio_stream::wrappers::BroadcastStream;

const MAX_SESSION_DURATION: Duration = Duration::from_secs(60);

#[derive(Clone, Debug, Default)]
pub struct RuntimeOptions {
    pub database_path: Option<PathBuf>,
    pub disable_audio: bool,
    pub disable_bluetooth: bool,
    pub seize_hid: bool,
    /// One-based audio notification number to drop once per session for recovery validation.
    pub drop_audio_notification: Option<u64>,
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
    let (hid_sender, hid_receiver) = mpsc::channel(128);
    let (events, _) = broadcast::channel(256);
    let client = LocalControlClient {
        commands,
        events: events.clone(),
    };
    let channels = RuntimeChannels {
        events,
        hardware_sender,
        hardware_receiver,
        hid_sender,
        hid_receiver,
    };
    let handle = tokio::spawn(async move {
        Runtime::new(store, settings, options, channels)
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
    async fn refresh_devices(&self) -> micflurry_control::Result<()> {
        self.request(Command::RefreshDevices).await
    }
    async fn connect(&self, device: DeviceId) -> micflurry_control::Result<()> {
        self.request(|reply| Command::Connect(device, reply)).await
    }
    async fn release(&self) -> micflurry_control::Result<()> {
        self.request(Command::Release).await
    }
    async fn start_recording(&self) -> micflurry_control::Result<()> {
        self.request(Command::StartRecording).await
    }
    async fn stop_recording(&self) -> micflurry_control::Result<()> {
        self.request(Command::StopRecording).await
    }
    async fn start_hid_capture(&self) -> micflurry_control::Result<()> {
        Err(ControlError::Invalid(
            "the foreground runtime configures HID capture at startup".into(),
        ))
    }
    async fn stop_hid_capture(&self) -> micflurry_control::Result<()> {
        Err(ControlError::Invalid(
            "the foreground runtime configures HID capture at startup".into(),
        ))
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
    RefreshDevices(oneshot::Sender<micflurry_control::Result<()>>),
    Connect(DeviceId, oneshot::Sender<micflurry_control::Result<()>>),
    Release(oneshot::Sender<micflurry_control::Result<()>>),
    StartRecording(oneshot::Sender<micflurry_control::Result<()>>),
    StopRecording(oneshot::Sender<micflurry_control::Result<()>>),
    Keyboard(
        KeyboardAction,
        oneshot::Sender<micflurry_control::Result<()>>,
    ),
    Shutdown(oneshot::Sender<()>),
}

struct RuntimeChannels {
    events: broadcast::Sender<Event>,
    hardware_sender: mpsc::Sender<BluetoothEvent>,
    hardware_receiver: mpsc::Receiver<BluetoothEvent>,
    hid_sender: mpsc::Sender<HidInput>,
    hid_receiver: mpsc::Receiver<HidInput>,
}

struct Runtime {
    store: Store,
    settings: Settings,
    status: Status,
    bluetooth: Option<Bluetooth>,
    hardware_sender: mpsc::Sender<BluetoothEvent>,
    hardware_receiver: mpsc::Receiver<BluetoothEvent>,
    hid_sender: mpsc::Sender<HidInput>,
    hid_receiver: mpsc::Receiver<HidInput>,
    hid_monitor: Option<HidMonitor>,
    events: broadcast::Sender<Event>,
    audio_sink: Box<dyn AudioSink>,
    decoder: ImaAdpcmDecoder,
    resampler: LinearResampler,
    codec: Codec,
    recording: Option<Recording>,
    last_audio_event: Instant,
    active_stream_id: Option<u8>,
    audio_started_at: Option<Instant>,
    next_mic_extend: Option<Instant>,
    notification_sizes: BTreeMap<u32, u64>,
    next_audio_frame: Option<u16>,
    keyboard_sequence: u64,
    options: RuntimeOptions,
}

impl Runtime {
    fn new(
        store: Store,
        settings: Settings,
        options: RuntimeOptions,
        channels: RuntimeChannels,
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
        status.hid.mode = if options.seize_hid {
            HidCaptureMode::Seize
        } else {
            HidCaptureMode::Monitor
        };
        Self {
            store,
            settings,
            status,
            bluetooth: None,
            hardware_sender: channels.hardware_sender,
            hardware_receiver: channels.hardware_receiver,
            hid_sender: channels.hid_sender,
            hid_receiver: channels.hid_receiver,
            hid_monitor: None,
            events: channels.events,
            audio_sink,
            decoder: ImaAdpcmDecoder::default(),
            resampler: LinearResampler::new(16_000, output_rate_hz),
            codec: Codec::Adpcm16Khz,
            recording: None,
            last_audio_event: Instant::now()
                .checked_sub(Duration::from_secs(1))
                .expect("one second is representable"),
            active_stream_id: None,
            audio_started_at: None,
            next_mic_extend: None,
            notification_sizes: BTreeMap::new(),
            next_audio_frame: None,
            keyboard_sequence: 0,
            options,
        }
    }

    async fn run(mut self, mut commands: mpsc::Receiver<Command>) {
        if self.options.disable_bluetooth {
            self.status.bluetooth = BluetoothState::Unavailable;
        } else {
            match Bluetooth::new().await {
                Ok(bluetooth) => {
                    self.bluetooth = Some(bluetooth);
                }
                Err(error) => {
                    self.status.bluetooth = BluetoothState::Unavailable;
                    self.report_error(format!("Bluetooth unavailable: {error:#}"));
                }
            }
        }
        self.publish_status();
        let mut ticker = tokio::time::interval(Duration::from_millis(200));
        let startup_bluetooth = tokio::time::sleep(Duration::from_millis(250));
        tokio::pin!(startup_bluetooth);
        let mut startup_bluetooth_pending = self.bluetooth.is_some();
        loop {
            tokio::select! {
                Some(command) = commands.recv() => {
                    if self.handle_command(command).await { break; }
                }
                Some(event) = self.hardware_receiver.recv() => self.handle_hardware(event).await,
                Some(input) = self.hid_receiver.recv() => self.handle_hid_input(&input),
                _ = ticker.tick() => {
                    if !self.enforce_session_limit().await {
                        self.extend_active_stream().await;
                    }
                    self.publish_status();
                },
                () = &mut startup_bluetooth, if startup_bluetooth_pending => {
                    startup_bluetooth_pending = false;
                    if let Err(error) = self.refresh_system_connected().await {
                        self.report_error(format!("refresh macOS Bluetooth devices: {error:#}"));
                    }
                },
                else => break,
            }
        }
        let _ = self.finish_recording();
        self.stop_hid_monitor().await;
        if let Some(bluetooth) = &mut self.bluetooth {
            let _ = bluetooth.write_command(&MIC_CLOSE_ANY).await;
            let _ = bluetooth.release().await;
        }
    }

    async fn refresh_system_connected(&mut self) -> Result<()> {
        if self.status.audio.active {
            anyhow::bail!("cannot refresh Bluetooth devices during an active audio session");
        }
        let preferred = self.store.last_connected_device_id()?;
        if self.bluetooth.is_none() {
            anyhow::bail!("Bluetooth is unavailable");
        }
        self.status.bluetooth = BluetoothState::Refreshing;
        self.publish_status();
        let result = {
            let bluetooth = self
                .bluetooth
                .as_ref()
                .context("Bluetooth became unavailable during refresh")?;
            tokio::time::timeout(Duration::from_secs(5), bluetooth.connected_atvv_devices()).await
        };
        self.status.bluetooth = BluetoothState::Idle;
        self.publish_status();
        let mut devices = match result {
            Ok(result) => result.context("list system-connected ATVV peripherals")?,
            Err(_) => anyhow::bail!("listing system-connected ATVV peripherals timed out"),
        };
        if devices.is_empty() {
            tracing::debug!(
                event = "bluetooth_connected_devices_empty",
                "macOS has no connected ATVV peripherals"
            );
            if self.status.connected_device.is_some() {
                if let Some(bluetooth) = &mut self.bluetooth {
                    bluetooth.release().await?;
                }
                self.mark_disconnected().await;
            }
            self.status.devices.clear();
            return Ok(());
        }
        for device in &mut devices {
            device.known = self.store.is_known(&device.id.0)?;
            self.emit(Event::DeviceDiscovered {
                device: device.clone(),
            });
        }
        let supported: Vec<_> = devices
            .iter()
            .filter(|device| device.support.is_supported())
            .cloned()
            .collect();
        let selected: Option<micflurry_control::Device> = preferred
            .as_ref()
            .and_then(|id| supported.iter().find(|device| device.id == *id))
            .or_else(|| (supported.len() == 1).then(|| &supported[0]))
            .cloned();
        self.status.devices = devices;
        if supported.is_empty() {
            if self.status.connected_device.is_some() {
                if let Some(bluetooth) = &mut self.bluetooth {
                    bluetooth.release().await?;
                }
                self.mark_disconnected().await;
            }
            tracing::warn!(
                event = "bluetooth_connected_devices_unsupported",
                count = self.status.devices.len(),
                "macOS-connected ATVV peripherals do not match the supported device registry"
            );
            return Ok(());
        }
        let Some(device) = selected else {
            tracing::info!(
                event = "bluetooth_connected_devices_need_selection",
                count = supported.len(),
                "multiple supported system-connected ATVV peripherals require user selection"
            );
            return Ok(());
        };
        if self.status.connected_device.as_ref() == Some(&device.id) {
            return Ok(());
        }
        tracing::info!(
            event = "bluetooth_connected_device_selected",
            device_id = %device.id,
            device_name = %device.name,
            "using system-connected ATVV peripheral"
        );
        if let Err(error) = self.connect_device(&device.id).await {
            tracing::warn!(
                event = "bluetooth_connected_device_failed",
                device_id = %device.id,
                error = %format!("{error:#}"),
                "could not initialize system-connected ATVV peripheral"
            );
            return Err(error);
        }
        self.remember_connected_device(device);
        Ok(())
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
            Command::RefreshDevices(reply) => match self.refresh_system_connected().await {
                Ok(()) => {
                    let _ = reply.send(Ok(()));
                }
                Err(error) => {
                    let message = format!("refresh macOS Bluetooth devices: {error:#}");
                    self.report_error(message.clone());
                    let _ = reply.send(Err(ControlError::Failed(message)));
                }
            },
            Command::Connect(device, reply) => {
                if self.status.connected_device.as_ref() == Some(&device) {
                    let _ = reply.send(Ok(()));
                } else {
                    let result = self.connect_device(&device).await;
                    match result {
                        Ok(()) => {
                            if let Some(item) = self
                                .status
                                .devices
                                .iter()
                                .find(|item| item.id == device)
                                .cloned()
                            {
                                self.remember_connected_device(item);
                            } else {
                                self.status.connected_device = Some(device.clone());
                                self.emit(Event::Connected { device });
                            }
                            let _ = reply.send(Ok(()));
                        }
                        Err(error) => {
                            self.report_error(format!("attach failed: {error:#}"));
                            let _ = reply.send(Err(control_failed(error)));
                        }
                    }
                }
            }
            Command::Release(reply) => {
                let result = if let Some(bluetooth) = &mut self.bluetooth {
                    let _ = bluetooth.write_command(&MIC_CLOSE_ANY).await;
                    bluetooth.release().await
                } else {
                    Ok(())
                };
                match result {
                    Ok(()) => {
                        self.mark_disconnected().await;
                        let _ = reply.send(Ok(()));
                    }
                    Err(error) => {
                        let message = format!("release Bluetooth attachment: {error:#}");
                        self.report_error(message.clone());
                        let _ = reply.send(Err(ControlError::Failed(message)));
                    }
                }
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
                let result = self
                    .post_keyboard(action, KeyboardSource::Tui)
                    .map_err(control_failed);
                let _ = reply.send(result);
            }
            Command::Shutdown(reply) => {
                let _ = reply.send(());
                return true;
            }
        }
        false
    }

    fn remember_connected_device(&mut self, mut device: micflurry_control::Device) {
        device.known = true;
        device.connected = true;
        device.supports_atvv = true;
        debug_assert!(device.support.is_supported());
        self.status.connected_device = Some(device.id.clone());
        for item in &mut self.status.devices {
            item.connected = item.id == device.id;
            if item.id == device.id {
                *item = device.clone();
            }
        }
        if let Err(error) = self.store.remember_device(&device) {
            self.report_error(format!("remember connected Bluetooth device: {error:#}"));
        }
        self.emit(Event::Connected { device: device.id });
    }

    async fn connect_device(&mut self, device: &DeviceId) -> Result<()> {
        if let Some(candidate) = self.status.devices.iter().find(|item| item.id == *device)
            && !candidate.support.is_supported()
        {
            anyhow::bail!(
                "unsupported Bluetooth device {:?}; MicFlurry will not connect it",
                candidate.name
            );
        }
        if self
            .status
            .connected_device
            .as_ref()
            .is_some_and(|connected| connected != device)
        {
            if let Some(bluetooth) = &mut self.bluetooth {
                let _ = bluetooth.write_command(&MIC_CLOSE_ANY).await;
                bluetooth.release().await?;
            }
            self.mark_disconnected().await;
        }
        self.status.attaching = true;
        self.emit(Event::Attaching {
            device: device.clone(),
            active: true,
        });
        let result = if let Some(bluetooth) = &mut self.bluetooth {
            if let Ok(result) = tokio::time::timeout(
                Duration::from_secs(15),
                bluetooth.connect(device, self.hardware_sender.clone()),
            )
            .await
            {
                result
            } else {
                let _ = bluetooth.release().await;
                Err(anyhow::anyhow!(
                    "connection timed out after 15 seconds; wake the remote and try again"
                ))
            }
        } else {
            Err(anyhow::anyhow!("Bluetooth is unavailable"))
        };
        self.status.attaching = false;
        self.emit(Event::Attaching {
            device: device.clone(),
            active: false,
        });
        if result.is_err() && self.status.connected_device.is_some() {
            self.mark_disconnected().await;
        }
        let device_info = result?;
        self.status.device_info = Some(device_info);
        self.start_hid_monitor(device).await;
        Ok(())
    }

    async fn handle_hardware(&mut self, event: BluetoothEvent) {
        match event {
            BluetoothEvent::Control { device, bytes }
                if self.status.connected_device.as_ref() == Some(&device) =>
            {
                self.handle_atvv_control(&bytes).await;
            }
            BluetoothEvent::Audio { device, bytes }
                if self.status.connected_device.as_ref() == Some(&device) =>
            {
                self.handle_audio(&bytes);
            }
            BluetoothEvent::Disconnected(device)
                if self.status.connected_device.as_ref() == Some(&device) =>
            {
                self.mark_disconnected().await;
                self.emit(Event::Disconnected { device });
            }
            _ => tracing::debug!(
                event = "bluetooth_stale_event_ignored",
                "ignored an event from an inactive Bluetooth attachment"
            ),
        }
    }

    async fn start_hid_monitor(&mut self, device: &DeviceId) {
        self.stop_hid_monitor().await;
        self.status.hid.mode = if self.options.seize_hid {
            HidCaptureMode::Seize
        } else {
            HidCaptureMode::Monitor
        };
        self.status.hid.last_error = None;
        match HidMonitor::start(&device.0, self.options.seize_hid, self.hid_sender.clone()).await {
            Ok(monitor) => {
                self.hid_monitor = Some(monitor);
                self.status.hid.active = true;
                tracing::info!(
                    event = "hid_monitor_started",
                    device_id = %device,
                    seize = self.options.seize_hid,
                    "monitoring remote IOHID input"
                );
            }
            Err(error) => {
                let message = format!("start IOHID monitor: {error:#}");
                self.status.hid.active = false;
                self.status.hid.last_error = Some(message.clone());
                tracing::warn!(event = "hid_monitor_unavailable", error = %message, "remote HID input is unavailable");
            }
        }
    }

    async fn stop_hid_monitor(&mut self) {
        if let Some(mut monitor) = self.hid_monitor.take() {
            monitor.stop().await;
        }
        self.status.hid.active = false;
    }

    fn handle_hid_input(&mut self, input: &HidInput) {
        tracing::debug!(
            event = "hid_input",
            sequence = input.sequence,
            usage_page = input.usage_page,
            usage = input.usage,
            value = input.value,
            action = ?input.mapped_action,
            "received remote HID input"
        );
        push_recent(&mut self.status.hid.recent_inputs, input.clone(), 12);
        self.emit(Event::HidInput {
            input: input.clone(),
        });
        if self.options.seize_hid
            && input.pressed
            && let Some(action) = input.mapped_action
            && let Err(error) = self.post_keyboard(action, KeyboardSource::Hid)
        {
            self.report_error(format!("forward seized HID input: {error:#}"));
        }
    }

    fn post_keyboard(&mut self, action: KeyboardAction, source: KeyboardSource) -> Result<()> {
        let result = keyboard::post(action);
        self.keyboard_sequence += 1;
        let output = KeyboardOutput {
            sequence: self.keyboard_sequence,
            source,
            action,
            succeeded: result.is_ok(),
            error: result.as_ref().err().map(|error| format!("{error:#}")),
        };
        push_recent(&mut self.status.hid.recent_outputs, output.clone(), 12);
        self.emit(Event::KeyboardOutput { output });
        result
    }

    async fn handle_atvv_control(&mut self, bytes: &[u8]) {
        match atvv::parse_control(bytes) {
            Ok(ControlMessage::AudioStart {
                reason,
                codec,
                stream_id,
            }) => self.handle_audio_start(reason, codec, stream_id),
            Ok(ControlMessage::AudioSync {
                codec,
                frame,
                predictor,
                step_index,
            }) => self.handle_audio_sync(codec, frame, predictor, step_index),
            Ok(ControlMessage::AudioStop { reason }) => self.handle_audio_stop(reason),
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
            Ok(ControlMessage::Capabilities {
                version,
                codecs,
                interaction_model,
                frame_size,
                extra_configuration,
                reserved,
                firmware_data,
            }) => {
                log_capabilities(
                    version,
                    codecs,
                    interaction_model,
                    frame_size,
                    extra_configuration,
                    reserved,
                    &firmware_data,
                );
                self.status.audio.protocol_version = Some(version);
                self.status.audio.negotiated_codecs = Some(codecs);
                self.status.audio.interaction_model = Some(interaction_model);
                self.status.audio.frame_size = Some(frame_size);
                self.status.audio.extra_configuration = Some(extra_configuration);
            }
            Ok(ControlMessage::Unknown { .. }) => {}
            Err(error) => self.report_error(format!("invalid ATVV control notification: {error}")),
        }
    }

    fn handle_audio_start(&mut self, reason: u8, codec: Codec, stream_id: u8) {
        tracing::info!(
            event = "atvv_audio_start",
            reason,
            codec = ?codec,
            sample_rate_hz = codec.sample_rate(),
            stream_id,
            "ATVV audio started"
        );
        self.codec = codec;
        self.decoder.reset();
        self.resampler
            .reconfigure(codec.sample_rate(), self.settings.output_rate_hz);
        self.status.audio.active = true;
        self.status.audio.session_duration_ms = 0;
        self.active_stream_id = Some(stream_id);
        self.audio_started_at = Some(Instant::now());
        self.next_mic_extend = Some(Instant::now() + Duration::from_secs(10));
        self.status.audio.source_rate_hz = Some(codec.sample_rate());
        self.status.audio.stream_id = Some(stream_id);
        self.status.audio.mic_extends_sent = 0;
        self.status.audio.last_stop_reason = None;
        self.status.audio.notification_count = 0;
        self.status.audio.notification_bytes = 0;
        self.status.audio.notification_sizes.clear();
        self.status.audio.audio_sync_count = 0;
        self.status.audio.last_sync_frame = None;
        self.status.audio.last_sync_gap_frames = None;
        self.status.audio.injected_notification_drops = 0;
        self.notification_sizes.clear();
        self.next_audio_frame = None;
        if self.settings.auto_record && self.recording.is_none() {
            let _ = self.begin_recording();
        }
        self.emit(Event::AudioStarted {
            rate_hz: codec.sample_rate(),
        });
    }

    fn handle_audio_sync(&mut self, codec: Codec, frame: u16, predictor: i16, step_index: u8) {
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
        let gap = self
            .next_audio_frame
            .map(|expected| signed_frame_delta(frame, expected));
        self.status.audio.audio_sync_count += 1;
        self.status.audio.last_sync_frame = Some(frame);
        self.status.audio.last_sync_gap_frames = gap;
        self.next_audio_frame = Some(frame);
        tracing::info!(
            event = "atvv_audio_sync",
            codec = ?codec,
            frame,
            gap_frames = ?gap,
            predictor,
            step_index,
            "synchronized ATVV decoder state"
        );
    }

    fn handle_audio_stop(&mut self, reason: u8) {
        let was_active = self.status.audio.active;
        self.update_session_duration();
        log_audio_stop(reason, &self.status.audio);
        self.status.audio.active = false;
        self.active_stream_id = None;
        self.audio_started_at = None;
        self.next_mic_extend = None;
        self.next_audio_frame = None;
        self.status.audio.last_stop_reason = Some(reason);
        if was_active {
            self.emit(Event::AudioStopped);
        }
        if was_active && self.settings.auto_record {
            let _ = self.finish_recording();
        }
    }

    fn handle_audio(&mut self, bytes: &[u8]) {
        if !self.status.audio.active {
            return;
        }
        self.status.audio.notification_count += 1;
        self.status.audio.notification_bytes += bytes.len() as u64;
        let size = u32::try_from(bytes.len()).unwrap_or(u32::MAX);
        *self.notification_sizes.entry(size).or_default() += 1;
        self.status.audio.notification_sizes = self
            .notification_sizes
            .iter()
            .map(|(&bytes, &count)| NotificationSizeCount { bytes, count })
            .collect();
        if self.options.drop_audio_notification == Some(self.status.audio.notification_count) {
            self.status.audio.injected_notification_drops += 1;
            tracing::warn!(
                event = "atvv_audio_notification_dropped",
                notification = self.status.audio.notification_count,
                bytes = bytes.len(),
                "deliberately dropped ATVV audio notification for recovery validation"
            );
            return;
        }
        if let Some(frame) = &mut self.next_audio_frame {
            *frame = frame.wrapping_add(1);
        }
        let decoded = self.decoder.decode(bytes);
        self.status.audio.decoded_frames += decoded.len() as u64;
        let mut samples = self.resampler.process_i16(&decoded);
        apply_gain(&mut samples, self.settings.input_gain_db);
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

    async fn mark_disconnected(&mut self) {
        self.stop_hid_monitor().await;
        let was_active = self.status.audio.active;
        self.update_session_duration();
        if was_active {
            self.emit(Event::AudioStopped);
        }
        if was_active
            && self.settings.auto_record
            && let Err(error) = self.finish_recording()
        {
            self.report_error(format!(
                "stop recording after Bluetooth disconnect: {error:#}"
            ));
        }
        self.status.connected_device = None;
        self.status.device_info = None;
        self.status.audio.active = false;
        self.status.audio.stream_id = None;
        self.active_stream_id = None;
        self.audio_started_at = None;
        self.next_mic_extend = None;
        self.next_audio_frame = None;
        for device in &mut self.status.devices {
            device.connected = false;
        }
    }

    fn report_error(&mut self, message: String) {
        self.status.last_error = Some(message.clone());
        self.emit(Event::Error { message });
    }

    fn publish_status(&mut self) {
        self.update_session_duration();
        self.emit(Event::Status {
            status: Box::new(self.status.clone()),
        });
    }

    fn update_session_duration(&mut self) {
        if let Some(started_at) = self.audio_started_at {
            self.status.audio.session_duration_ms =
                bounded_session_duration_ms(started_at.elapsed());
        }
    }

    async fn enforce_session_limit(&mut self) -> bool {
        let (Some(stream_id), Some(started_at)) = (self.active_stream_id, self.audio_started_at)
        else {
            return false;
        };
        if started_at.elapsed() < MAX_SESSION_DURATION {
            return false;
        }

        tracing::info!(
            event = "atvv_session_limit",
            stream_id,
            limit_seconds = MAX_SESSION_DURATION.as_secs(),
            "closing ATVV audio at the host session limit"
        );
        if let Some(bluetooth) = &self.bluetooth
            && let Err(error) = bluetooth.write_command(&mic_close(stream_id)).await
        {
            self.report_error(format!("close ATVV audio at session limit: {error:#}"));
        }
        self.status.audio.session_duration_ms = bounded_session_duration_ms(MAX_SESSION_DURATION);
        self.status.audio.active = false;
        self.status.audio.stream_id = None;
        self.status.audio.last_stop_reason = Some(0x00);
        self.active_stream_id = None;
        self.audio_started_at = None;
        self.next_mic_extend = None;
        self.next_audio_frame = None;
        self.emit(Event::AudioStopped);
        if self.settings.auto_record
            && let Err(error) = self.finish_recording()
        {
            self.report_error(format!("stop recording at session limit: {error:#}"));
        }
        true
    }

    async fn extend_active_stream(&mut self) {
        let (Some(stream_id), Some(deadline)) = (self.active_stream_id, self.next_mic_extend)
        else {
            return;
        };
        if Instant::now() < deadline {
            return;
        }
        self.next_mic_extend = Some(Instant::now() + Duration::from_secs(10));
        if let Some(bluetooth) = &self.bluetooth {
            match bluetooth.write_command(&mic_extend(stream_id)).await {
                Ok(()) => {
                    self.status.audio.mic_extends_sent += 1;
                    tracing::info!(
                        event = "atvv_mic_extend",
                        stream_id,
                        sequence = self.status.audio.mic_extends_sent,
                        command = ?mic_extend(stream_id),
                        "ATVV MIC_EXTEND submitted"
                    );
                }
                Err(error) => {
                    tracing::error!(
                        event = "atvv_mic_extend_failed",
                        stream_id,
                        error = %format!("{error:#}"),
                        "ATVV MIC_EXTEND failed"
                    );
                    self.report_error(format!("extend ATVV audio stream: {error:#}"));
                }
            }
        }
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

fn apply_gain(samples: &mut [f32], gain_db: f32) {
    let gain = 10.0_f32.powf(gain_db / 20.0);
    for sample in samples {
        *sample = (*sample * gain).clamp(-1.0, 1.0);
    }
}

fn bounded_session_duration_ms(elapsed: Duration) -> u64 {
    u64::try_from(elapsed.min(MAX_SESSION_DURATION).as_millis()).unwrap_or(60_000)
}

fn signed_frame_delta(actual: u16, expected: u16) -> i32 {
    let forward = i32::from(actual.wrapping_sub(expected));
    if forward <= i32::from(i16::MAX) {
        forward
    } else {
        forward - 65_536
    }
}

fn push_recent<T>(items: &mut Vec<T>, item: T, limit: usize) {
    if items.len() == limit {
        items.remove(0);
    }
    items.push(item);
}

fn stop_reason_name(reason: u8) -> &'static str {
    match reason {
        0x00 => "mic_close",
        0x02 => "button_release",
        0x04 => "upcoming_audio_start",
        0x08 => "transfer_timeout",
        0x10 => "notifications_disabled",
        _ => "other",
    }
}

fn log_capabilities(
    version: u16,
    codecs: u8,
    interaction_model: u8,
    frame_size: u16,
    extra_configuration: u8,
    reserved: u8,
    firmware_data: &[u8],
) {
    tracing::info!(
        event = "atvv_capabilities",
        version = format_args!("{}.{:02}", version >> 8, version & 0xff),
        codecs,
        interaction_model,
        frame_size,
        extra_configuration,
        reserved,
        firmware_data,
        "ATVV capabilities negotiated"
    );
}

fn log_audio_stop(reason: u8, audio: &AudioStatus) {
    tracing::info!(
        event = "atvv_audio_stop",
        reason,
        reason_name = stop_reason_name(reason),
        stream_id = ?audio.stream_id,
        mic_extends_sent = audio.mic_extends_sent,
        decoded_samples = audio.decoded_frames,
        notifications = audio.notification_count,
        notification_bytes = audio.notification_bytes,
        notification_sizes = ?audio.notification_sizes,
        audio_syncs = audio.audio_sync_count,
        injected_drops = audio.injected_notification_drops,
        "ATVV audio stopped"
    );
}

#[cfg(test)]
mod tests {
    use super::*;

    fn test_runtime(options: RuntimeOptions) -> (Runtime, tempfile::TempDir) {
        let directory = tempfile::tempdir().unwrap();
        let store = Store::open(&directory.path().join("state.db")).unwrap();
        let settings = store.settings().unwrap();
        let (events, _) = broadcast::channel(32);
        let (hardware_sender, hardware_receiver) = mpsc::channel(32);
        let (hid_sender, hid_receiver) = mpsc::channel(32);
        (
            Runtime::new(
                store,
                settings,
                options,
                RuntimeChannels {
                    events,
                    hardware_sender,
                    hardware_receiver,
                    hid_sender,
                    hid_receiver,
                },
            ),
            directory,
        )
    }

    #[tokio::test]
    async fn local_client_round_trips_settings_without_hardware() {
        let directory = tempfile::tempdir().unwrap();
        let (client, handle) = start(RuntimeOptions {
            database_path: Some(directory.path().join("state.db")),
            disable_audio: true,
            disable_bluetooth: true,
            ..RuntimeOptions::default()
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

    #[test]
    fn gain_is_applied_and_clamped() {
        let mut samples = [0.1, -0.1, 0.5];
        apply_gain(&mut samples, 20.0);
        assert!((samples[0] - 1.0).abs() < f32::EPSILON);
        assert!((samples[1] + 1.0).abs() < f32::EPSILON);
        assert!((samples[2] - 1.0).abs() < f32::EPSILON);
    }

    #[test]
    fn session_duration_is_capped_at_product_limit() {
        assert_eq!(
            bounded_session_duration_ms(Duration::from_millis(12_345)),
            12_345
        );
        assert_eq!(bounded_session_duration_ms(Duration::from_secs(75)), 60_000);
    }

    #[tokio::test]
    async fn tracks_injected_loss_sync_gap_and_eight_khz_transition() {
        let (mut runtime, _directory) = test_runtime(RuntimeOptions {
            disable_audio: true,
            disable_bluetooth: true,
            drop_audio_notification: Some(2),
            ..RuntimeOptions::default()
        });
        runtime.handle_atvv_control(&[0x04, 0x03, 0x02, 0x2a]).await;
        runtime
            .handle_atvv_control(&[0x0a, 0x02, 0x00, 0x0a, 0x00, 0x00, 0x00])
            .await;
        runtime.handle_audio(&[0x17; 120]);
        let decoded_after_first = runtime.status.audio.decoded_frames;
        runtime.handle_audio(&[0x28; 120]);
        assert_eq!(runtime.status.audio.decoded_frames, decoded_after_first);
        runtime
            .handle_atvv_control(&[0x0a, 0x01, 0x00, 0x0c, 0x01, 0x00, 0x08])
            .await;

        assert_eq!(runtime.status.audio.source_rate_hz, Some(8_000));
        assert_eq!(runtime.status.audio.notification_count, 2);
        assert_eq!(runtime.status.audio.notification_bytes, 240);
        assert_eq!(runtime.status.audio.notification_sizes[0].bytes, 120);
        assert_eq!(runtime.status.audio.notification_sizes[0].count, 2);
        assert_eq!(runtime.status.audio.injected_notification_drops, 1);
        assert_eq!(runtime.status.audio.audio_sync_count, 2);
        assert_eq!(runtime.status.audio.last_sync_gap_frames, Some(1));
    }

    #[tokio::test]
    async fn host_session_limit_closes_runtime_state_with_negotiated_stream() {
        let (mut runtime, _directory) = test_runtime(RuntimeOptions {
            disable_audio: true,
            disable_bluetooth: true,
            ..RuntimeOptions::default()
        });
        runtime.status.audio.active = true;
        runtime.status.audio.stream_id = Some(0x2a);
        runtime.active_stream_id = Some(0x2a);
        runtime.audio_started_at = Some(
            Instant::now()
                .checked_sub(MAX_SESSION_DURATION)
                .expect("the 60-second test duration is representable"),
        );

        assert!(runtime.enforce_session_limit().await);
        assert!(!runtime.status.audio.active);
        assert_eq!(runtime.status.audio.stream_id, None);
        assert_eq!(runtime.status.audio.session_duration_ms, 60_000);
        assert_eq!(runtime.status.audio.last_stop_reason, Some(0x00));
    }

    #[test]
    fn frame_delta_wraps_and_reports_missing_notifications() {
        assert_eq!(signed_frame_delta(12, 11), 1);
        assert_eq!(signed_frame_delta(0, u16::MAX), 1);
        assert_eq!(signed_frame_delta(u16::MAX, 0), -1);
    }
}
