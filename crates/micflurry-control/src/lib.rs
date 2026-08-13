//! UI-independent control boundary for the foreground runtime and the future daemon.

use async_trait::async_trait;
use serde::{Deserialize, Serialize};
use std::{fmt, pin::Pin};
use tokio_stream::Stream;

pub type EventStream = Pin<Box<dyn Stream<Item = Event> + Send>>;

#[derive(Clone, Debug, Default, Deserialize, PartialEq, Serialize)]
pub struct Status {
    pub bluetooth: BluetoothState,
    pub devices: Vec<Device>,
    pub connected_device: Option<DeviceId>,
    pub attaching: bool,
    pub device_info: Option<DeviceInfo>,
    pub hid: HidStatus,
    pub audio: AudioStatus,
    pub recording: RecordingStatus,
    pub last_error: Option<String>,
}

#[derive(Clone, Copy, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum BluetoothState {
    #[default]
    Idle,
    Refreshing,
    Unavailable,
}

#[derive(Clone, Debug, Deserialize, Eq, Hash, PartialEq, Serialize)]
pub struct DeviceId(pub String);

impl fmt::Display for DeviceId {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.0)
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct Device {
    pub id: DeviceId,
    pub name: String,
    pub rssi: Option<i16>,
    pub known: bool,
    pub connected: bool,
    pub supports_atvv: bool,
    /// Records whether the peripheral matches `MicFlurry`'s verified device registry.
    pub support: DeviceSupport,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum DeviceSupport {
    Unsupported,
    Supported { model: String },
}

impl DeviceSupport {
    #[must_use]
    pub const fn is_supported(&self) -> bool {
        matches!(self, Self::Supported { .. })
    }

    #[must_use]
    pub fn model(&self) -> Option<&str> {
        match self {
            Self::Supported { model } => Some(model),
            Self::Unsupported => None,
        }
    }
}

#[derive(Clone, Debug, Default, Deserialize, PartialEq, Serialize)]
pub struct AudioStatus {
    pub active: bool,
    pub session_duration_ms: u64,
    pub source_rate_hz: Option<u32>,
    pub output_rate_hz: u32,
    pub level_dbfs: Option<f32>,
    pub decoded_frames: u64,
    pub dropped_frames: u64,
    pub protocol_version: Option<u16>,
    pub stream_id: Option<u8>,
    pub mic_extends_sent: u64,
    pub last_stop_reason: Option<u8>,
    pub negotiated_codecs: Option<u8>,
    pub interaction_model: Option<u8>,
    pub frame_size: Option<u16>,
    pub extra_configuration: Option<u8>,
    pub notification_count: u64,
    pub notification_bytes: u64,
    pub notification_sizes: Vec<NotificationSizeCount>,
    pub audio_sync_count: u64,
    pub last_sync_frame: Option<u16>,
    pub last_sync_gap_frames: Option<i32>,
    pub injected_notification_drops: u64,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct NotificationSizeCount {
    pub bytes: u32,
    pub count: u64,
}

#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
pub struct DeviceInfo {
    pub att_mtu: Option<u16>,
    pub manufacturer_name: Option<String>,
    pub model_number: Option<String>,
    pub serial_number: Option<String>,
    pub hardware_revision: Option<String>,
    pub firmware_revision: Option<String>,
    pub software_revision: Option<String>,
    pub hid_manufacturer: Option<String>,
    pub hid_product: Option<String>,
    pub hid_vendor_id: Option<u32>,
    pub hid_product_id: Option<u32>,
    pub hid_transport: Option<String>,
    pub hid_serial_number: Option<String>,
    pub hid_version_number: Option<u32>,
    pub physical_device_id: Option<String>,
}

#[derive(Clone, Copy, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum HidCaptureMode {
    #[default]
    Monitor,
    Seize,
}

#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
pub struct HidStatus {
    pub mode: HidCaptureMode,
    pub active: bool,
    pub last_error: Option<String>,
    pub recent_inputs: Vec<HidInput>,
    pub recent_outputs: Vec<KeyboardOutput>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct HidInput {
    pub sequence: u64,
    pub usage_page: u32,
    pub usage: u32,
    pub usage_name: String,
    pub value: i64,
    pub pressed: bool,
    pub mapped_action: Option<KeyboardAction>,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum KeyboardSource {
    Tui,
    Hid,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct KeyboardOutput {
    pub sequence: u64,
    pub source: KeyboardSource,
    pub action: KeyboardAction,
    pub succeeded: bool,
    pub error: Option<String>,
}

#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
pub struct RecordingStatus {
    pub active: bool,
    pub path: Option<String>,
    pub sample_count: u64,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
pub struct Settings {
    pub injection_device_uid: String,
    pub output_rate_hz: u32,
    pub input_gain_db: f32,
    pub recording_directory: String,
    pub auto_record: bool,
}

#[derive(Clone, Debug, Default, Deserialize, PartialEq, Serialize)]
pub struct SettingsChange {
    pub injection_device_uid: Option<String>,
    pub output_rate_hz: Option<u32>,
    pub input_gain_db: Option<f32>,
    pub recording_directory: Option<String>,
    pub auto_record: Option<bool>,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum KeyboardAction {
    Up,
    Down,
    Left,
    Right,
    Select,
    Back,
    Home,
    PlayPause,
    Previous,
    Next,
    VolumeDown,
    VolumeUp,
    Mute,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Event {
    Status(Box<Status>),
    DeviceDiscovered { device: Device },
    Attaching { device: DeviceId, active: bool },
    Connected { device: DeviceId },
    Disconnected { device: DeviceId },
    AudioStarted { rate_hz: u32 },
    AudioLevel { dbfs: f32 },
    AudioStopped,
    RecordingStarted { path: String },
    RecordingStopped { path: String, sample_count: u64 },
    HidInput { input: HidInput },
    KeyboardOutput { output: KeyboardOutput },
    Error { message: String },
}

#[derive(Debug, thiserror::Error)]
pub enum ControlError {
    #[error("runtime is no longer available")]
    Unavailable,
    #[error("invalid request: {0}")]
    Invalid(String),
    #[error("operation failed: {0}")]
    Failed(String),
}

pub type Result<T> = std::result::Result<T, ControlError>;

#[async_trait]
pub trait ControlClient: Clone + Send + Sync + 'static {
    async fn status(&self) -> Result<Status>;
    async fn settings(&self) -> Result<Settings>;
    async fn set_settings(&self, change: SettingsChange) -> Result<Settings>;
    async fn refresh_devices(&self) -> Result<()>;
    async fn connect(&self, device: DeviceId) -> Result<()>;
    async fn release(&self) -> Result<()>;
    async fn start_recording(&self) -> Result<()>;
    async fn stop_recording(&self) -> Result<()>;
    async fn keyboard_action(&self, action: KeyboardAction) -> Result<()>;
    fn subscribe(&self) -> EventStream;
}
