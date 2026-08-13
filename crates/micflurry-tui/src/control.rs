//! UI-independent control boundary for the foreground runtime and the future daemon.

use async_trait::async_trait;
use serde::{Deserialize, Serialize, de::DeserializeOwned};
use serde_json::{Value, json};
use std::{
    fmt,
    path::{Path, PathBuf},
    pin::Pin,
    sync::{
        Arc,
        atomic::{AtomicU64, Ordering},
    },
};
use tokio::{
    io::{AsyncBufReadExt, AsyncWriteExt, BufReader},
    net::UnixStream,
    sync::mpsc,
};
use tokio_stream::Stream;

pub type EventStream = Pin<Box<dyn Stream<Item = Event> + Send>>;

#[derive(Clone, Debug, Default, Deserialize, PartialEq, Serialize)]
#[serde(default)]
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

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum DeviceSupport {
    Unsupported,
    Supported { model: String },
}

#[derive(Deserialize)]
#[serde(untagged)]
enum DeviceSupportDecode {
    Current(DeviceSupportObject),
    Legacy(DeviceSupportLegacy),
}

#[derive(Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
enum DeviceSupportObject {
    Unsupported {},
    Supported { model: String },
}

#[derive(Deserialize)]
#[serde(rename_all = "snake_case")]
enum DeviceSupportLegacy {
    Unsupported,
    Supported { model: String },
}

impl<'de> Deserialize<'de> for DeviceSupport {
    fn deserialize<D>(deserializer: D) -> std::result::Result<Self, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        let decoded = DeviceSupportDecode::deserialize(deserializer)?;
        Ok(match decoded {
            DeviceSupportDecode::Current(DeviceSupportObject::Unsupported {})
            | DeviceSupportDecode::Legacy(DeviceSupportLegacy::Unsupported) => Self::Unsupported,
            DeviceSupportDecode::Current(DeviceSupportObject::Supported { model })
            | DeviceSupportDecode::Legacy(DeviceSupportLegacy::Supported { model }) => {
                Self::Supported { model }
            }
        })
    }
}

impl Serialize for DeviceSupport {
    fn serialize<S>(&self, serializer: S) -> std::result::Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        match self {
            Self::Unsupported => DeviceSupportObject::Unsupported {}.serialize(serializer),
            Self::Supported { model } => DeviceSupportObject::Supported {
                model: model.clone(),
            }
            .serialize(serializer),
        }
    }
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
#[serde(default)]
pub struct AudioStatus {
    pub active: bool,
    #[serde(alias = "session_duration_milliseconds")]
    pub session_duration_ms: u64,
    pub source_rate_hz: Option<u32>,
    pub output_rate_hz: u32,
    pub level_dbfs: Option<f32>,
    pub decoded_frames: u64,
    pub dropped_frames: u64,
    pub protocol_version: Option<u16>,
    pub stream_id: Option<u8>,
    #[serde(alias = "microphone_extends_sent")]
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
#[serde(default)]
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
#[serde(default)]
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
    Status { status: Box<Status> },
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
    async fn start_hid_capture(&self) -> Result<()>;
    async fn stop_hid_capture(&self) -> Result<()>;
    fn subscribe(&self) -> EventStream;
}

#[derive(Clone, Debug)]
pub struct SocketControlClient {
    socket_path: Arc<PathBuf>,
    next_id: Arc<AtomicU64>,
}

impl SocketControlClient {
    #[must_use]
    pub fn new(socket_path: impl Into<PathBuf>) -> Self {
        Self {
            socket_path: Arc::new(socket_path.into()),
            next_id: Arc::new(AtomicU64::new(1)),
        }
    }

    /// Returns the standard per-user daemon socket path.
    ///
    /// # Errors
    ///
    /// Returns an error when the platform does not expose an application-support directory.
    pub fn default_socket_path() -> Result<PathBuf> {
        dirs::data_dir()
            .map(|directory| directory.join("MicFlurry/run/control.sock"))
            .ok_or_else(|| {
                ControlError::Invalid("application support directory unavailable".into())
            })
    }

    async fn request<R: DeserializeOwned>(&self, method: &str, params: Option<Value>) -> Result<R> {
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        let request = WireRequest {
            jsonrpc: "2.0",
            id,
            method,
            params,
        };
        let mut stream = UnixStream::connect(self.socket_path.as_ref())
            .await
            .map_err(|error| socket_error(self.socket_path.as_ref(), &error))?;
        let mut frame = serde_json::to_vec(&request)
            .map_err(|error| ControlError::Invalid(error.to_string()))?;
        frame.push(b'\n');
        stream
            .write_all(&frame)
            .await
            .map_err(|error| socket_error(self.socket_path.as_ref(), &error))?;

        let mut lines = BufReader::new(stream).lines();
        while let Some(line) = lines
            .next_line()
            .await
            .map_err(|error| socket_error(self.socket_path.as_ref(), &error))?
        {
            let response: WireResponse = serde_json::from_str(&line)
                .map_err(|error| ControlError::Invalid(error.to_string()))?;
            if response.id != Some(id) {
                continue;
            }
            if let Some(error) = response.error {
                return Err(ControlError::Failed(format!(
                    "{} ({})",
                    error.message, error.code
                )));
            }
            return serde_json::from_value(response.result.unwrap_or(Value::Null))
                .map_err(|error| ControlError::Invalid(error.to_string()));
        }
        Err(ControlError::Unavailable)
    }
}

#[async_trait]
impl ControlClient for SocketControlClient {
    async fn status(&self) -> Result<Status> {
        self.request("v1.status", None).await
    }

    async fn settings(&self) -> Result<Settings> {
        self.request("v1.settings", None).await
    }

    async fn set_settings(&self, change: SettingsChange) -> Result<Settings> {
        self.request("v1.set_settings", Some(json!(change))).await
    }

    async fn refresh_devices(&self) -> Result<()> {
        self.request("v1.refresh_devices", None).await
    }

    async fn connect(&self, device: DeviceId) -> Result<()> {
        self.request("v1.connect", Some(json!({ "device": device })))
            .await
    }

    async fn release(&self) -> Result<()> {
        self.request("v1.release", None).await
    }

    async fn start_recording(&self) -> Result<()> {
        self.request("v1.start_recording", None).await
    }

    async fn stop_recording(&self) -> Result<()> {
        self.request("v1.stop_recording", None).await
    }

    async fn start_hid_capture(&self) -> Result<()> {
        self.request("v1.start_hid_capture", None).await
    }

    async fn stop_hid_capture(&self) -> Result<()> {
        self.request("v1.stop_hid_capture", None).await
    }

    fn subscribe(&self) -> EventStream {
        let path = Arc::clone(&self.socket_path);
        let (sender, receiver) = mpsc::channel(256);
        tokio::spawn(async move {
            let result = async {
                let stream = UnixStream::connect(path.as_ref())
                    .await
                    .map_err(|error| socket_error(path.as_ref(), &error))?;
                let mut lines = BufReader::new(stream).lines();
                while let Some(line) = lines
                    .next_line()
                    .await
                    .map_err(|error| socket_error(path.as_ref(), &error))?
                {
                    let notification: WireNotification = match serde_json::from_str(&line) {
                        Ok(value) => value,
                        Err(_) => continue,
                    };
                    if notification.method != "v1.event" {
                        continue;
                    }
                    let event = serde_json::from_value(notification.params)
                        .map_err(|error| ControlError::Invalid(error.to_string()))?;
                    if sender.send(event).await.is_err() {
                        return Ok(());
                    }
                }
                Err(ControlError::Unavailable)
            }
            .await;
            if let Err(error) = result {
                let _ = sender
                    .send(Event::Error {
                        message: error.to_string(),
                    })
                    .await;
            }
        });
        Box::pin(tokio_stream::wrappers::ReceiverStream::new(receiver))
    }
}

fn socket_error(path: &Path, error: &std::io::Error) -> ControlError {
    ControlError::Failed(format!("{}: {error}", path.display()))
}

#[derive(Serialize)]
struct WireRequest<'a> {
    jsonrpc: &'static str,
    id: u64,
    method: &'a str,
    #[serde(skip_serializing_if = "Option::is_none")]
    params: Option<Value>,
}

#[derive(Deserialize)]
struct WireResponse {
    id: Option<u64>,
    result: Option<Value>,
    error: Option<WireError>,
}

#[derive(Deserialize)]
struct WireError {
    code: i64,
    message: String,
}

#[derive(Deserialize)]
struct WireNotification {
    method: String,
    params: Value,
}

#[cfg(test)]
mod tests {
    use super::{DeviceSupport, Event};

    #[test]
    fn decodes_swift_device_support_shapes() {
        assert_eq!(
            serde_json::from_str::<DeviceSupport>(r#"{"unsupported":{}}"#).unwrap(),
            DeviceSupport::Unsupported
        );
        assert_eq!(
            serde_json::from_str::<DeviceSupport>(r#"{"supported":{"model":"RC003"}}"#).unwrap(),
            DeviceSupport::Supported {
                model: "RC003".into()
            }
        );
        assert_eq!(
            serde_json::from_str::<DeviceSupport>(r#""unsupported""#).unwrap(),
            DeviceSupport::Unsupported
        );
    }

    #[test]
    fn decodes_swift_status_event_envelope() {
        let event: Event = serde_json::from_str(
            r#"{"type":"status","status":{"bluetooth":"idle","hid":{},"audio":{},"recording":{}}}"#,
        )
        .unwrap();
        assert!(matches!(event, Event::Status { .. }));
    }
}
