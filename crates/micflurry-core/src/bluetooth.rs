use crate::{
    atvv::{AUDIO_UUID, CONTROL_UUID, GET_CAPS, SERVICE_UUID, TX_UUID},
    hid_identity::{self, HidIdentity},
};
use anyhow::{Context, Result};
use btleplug::{
    api::{Central, Manager as _, Peripheral as _, WriteType},
    platform::{Adapter, Manager, Peripheral},
};
use futures::StreamExt;
use micflurry_control::{Device, DeviceId, DeviceInfo, DeviceSupport};
use std::time::Duration;
use tokio::{sync::mpsc, task::JoinHandle};
use uuid::{Uuid, uuid};

const XIAOMI_VOICE_REMOTE_MODEL: &str = "小米语音遥控器";
const XIAOMI_MANUFACTURER: &str = "MIOM";
const XIAOMI_VENDOR_ID: u32 = 10_007;
const XIAOMI_PRODUCT_ID: u32 = 12_984;

const DEVICE_INFORMATION_UUID: Uuid = uuid!("0000180a-0000-1000-8000-00805f9b34fb");
const MODEL_NUMBER_UUID: Uuid = uuid!("00002a24-0000-1000-8000-00805f9b34fb");
const SERIAL_NUMBER_UUID: Uuid = uuid!("00002a25-0000-1000-8000-00805f9b34fb");
const FIRMWARE_REVISION_UUID: Uuid = uuid!("00002a26-0000-1000-8000-00805f9b34fb");
const HARDWARE_REVISION_UUID: Uuid = uuid!("00002a27-0000-1000-8000-00805f9b34fb");
const SOFTWARE_REVISION_UUID: Uuid = uuid!("00002a28-0000-1000-8000-00805f9b34fb");
const MANUFACTURER_NAME_UUID: Uuid = uuid!("00002a29-0000-1000-8000-00805f9b34fb");

#[derive(Debug)]
pub enum BluetoothEvent {
    Control { device: DeviceId, bytes: Vec<u8> },
    Audio { device: DeviceId, bytes: Vec<u8> },
    Disconnected(DeviceId),
}

pub struct Bluetooth {
    adapter: Adapter,
    connected: Option<Peripheral>,
    connection_owned: bool,
    notification_task: Option<JoinHandle<()>>,
}

impl Bluetooth {
    pub async fn new() -> Result<Self> {
        let manager = Manager::new().await.context("initialize Bluetooth")?;
        let adapter = manager
            .adapters()
            .await?
            .into_iter()
            .next()
            .context("no Bluetooth adapter found")?;
        Ok(Self {
            adapter,
            connected: None,
            connection_owned: false,
            notification_task: None,
        })
    }

    pub async fn connect(
        &mut self,
        id: &DeviceId,
        sender: mpsc::Sender<BluetoothEvent>,
    ) -> Result<DeviceInfo> {
        tracing::info!(event = "bluetooth_connect_start", device_id = %id, "connecting BLE peripheral");
        let peripheral = self
            .adapter
            .peripherals()
            .await?
            .into_iter()
            .find(|candidate| candidate.id().to_string() == id.0)
            .with_context(|| {
                format!(
                    "Bluetooth device {} is no longer connected through macOS; refresh again",
                    id.0
                )
            })?;
        ensure_supported(&peripheral)?;
        self.release().await?;
        self.connect_peripheral(peripheral, id, sender).await
    }

    #[cfg(target_vendor = "apple")]
    pub async fn connected_atvv_devices(&self) -> Result<Vec<Device>> {
        let hid_identities = hid_identity::identities().context("list connected HID identities")?;
        let peripherals = self
            .adapter
            .connected_peripherals_with_services(&[SERVICE_UUID])
            .await?;
        let mut devices = Vec::with_capacity(peripherals.len());
        for peripheral in peripherals {
            let properties = peripheral.properties().await?.unwrap_or_default();
            let uuid = uuid::Uuid::parse_str(&peripheral.id().to_string()).ok();
            let hid_identity = uuid.and_then(|uuid| hid_identities.get(&uuid));
            let identity = supported_identity(hid_identity);
            log_identity(&peripheral, &properties, hid_identity, identity);
            devices.push(Device {
                id: DeviceId(peripheral.id().to_string()),
                name: properties
                    .local_name
                    .or_else(|| hid_identity.and_then(|identity| identity.product.clone()))
                    .unwrap_or_else(|| "Connected ATVV remote".into()),
                rssi: properties.rssi,
                known: false,
                connected: true,
                supports_atvv: true,
                support: device_support(identity),
            });
        }
        Ok(devices)
    }

    #[cfg(not(target_vendor = "apple"))]
    pub async fn connected_atvv_devices(&self) -> Result<Vec<Device>> {
        Ok(Vec::new())
    }

    async fn connect_peripheral(
        &mut self,
        peripheral: Peripheral,
        id: &DeviceId,
        sender: mpsc::Sender<BluetoothEvent>,
    ) -> Result<DeviceInfo> {
        let was_connected = peripheral.is_connected().await?;
        if !was_connected {
            peripheral.connect().await?;
        }
        let result = self
            .initialize_atvv(&peripheral, id, sender, !was_connected)
            .await;
        if result.is_err() {
            unsubscribe_atvv(&peripheral).await;
            if !was_connected && peripheral.is_connected().await.unwrap_or(false) {
                let _ = peripheral.disconnect().await;
            }
        }
        result
    }

    async fn initialize_atvv(
        &mut self,
        peripheral: &Peripheral,
        id: &DeviceId,
        sender: mpsc::Sender<BluetoothEvent>,
        connection_owned: bool,
    ) -> Result<DeviceInfo> {
        peripheral.discover_services().await?;
        let characteristics = peripheral.characteristics();
        let tx = characteristics
            .iter()
            .find(|characteristic| characteristic.uuid == TX_UUID)
            .cloned()
            .context("device does not expose the ATVV TX characteristic")?;
        let audio = characteristics
            .iter()
            .find(|characteristic| characteristic.uuid == AUDIO_UUID)
            .cloned()
            .context("device does not expose the ATVV audio characteristic")?;
        let control = characteristics
            .iter()
            .find(|characteristic| characteristic.uuid == CONTROL_UUID)
            .cloned()
            .context("device does not expose the ATVV control characteristic")?;
        // Create the receiver before subscribing and writing GET_CAPS so fast notifications are
        // buffered instead of being lost before the forwarding task starts.
        let mut notifications = peripheral.notifications().await?;
        peripheral.subscribe(&audio).await?;
        peripheral.subscribe(&control).await?;
        let device_info = read_device_info(peripheral, id).await;
        peripheral
            .write(&tx, &GET_CAPS, WriteType::WithoutResponse)
            .await?;
        tracing::info!(event = "bluetooth_connected", device_id = %id, "subscribed to ATVV notifications and requested capabilities");

        let notification_id = id.clone();
        let disconnected_id = id.clone();
        self.notification_task = Some(tokio::spawn(async move {
            while let Some(notification) = notifications.next().await {
                let event = if notification.uuid == AUDIO_UUID {
                    BluetoothEvent::Audio {
                        device: notification_id.clone(),
                        bytes: notification.value,
                    }
                } else if notification.uuid == CONTROL_UUID {
                    BluetoothEvent::Control {
                        device: notification_id.clone(),
                        bytes: notification.value,
                    }
                } else {
                    continue;
                };
                if sender.send(event).await.is_err() {
                    return;
                }
            }
            let _ = sender
                .send(BluetoothEvent::Disconnected(disconnected_id))
                .await;
        }));
        self.connected = Some(peripheral.clone());
        self.connection_owned = connection_owned;
        Ok(device_info)
    }

    pub async fn write_command(&self, bytes: &[u8]) -> Result<()> {
        let peripheral = self
            .connected
            .as_ref()
            .context("no ATVV remote is connected")?;
        let characteristic = peripheral
            .characteristics()
            .iter()
            .find(|characteristic| characteristic.uuid == TX_UUID)
            .cloned()
            .context("connected device lost its ATVV TX characteristic")?;
        peripheral
            .write(&characteristic, bytes, WriteType::WithoutResponse)
            .await?;
        tracing::debug!(event = "atvv_command_written", command = ?bytes, "wrote ATVV command");
        Ok(())
    }

    /// Releases `MicFlurry`'s GATT attachment without disconnecting a link that macOS owned first.
    pub async fn release(&mut self) -> Result<()> {
        self.stop_notifications();
        if let Some(peripheral) = self.connected.take() {
            unsubscribe_atvv(&peripheral).await;
            if self.connection_owned && peripheral.is_connected().await? {
                peripheral.disconnect().await?;
            }
        }
        self.connection_owned = false;
        Ok(())
    }

    fn stop_notifications(&mut self) {
        if let Some(task) = self.notification_task.take() {
            task.abort();
        }
    }
}

async fn read_device_info(peripheral: &Peripheral, id: &DeviceId) -> DeviceInfo {
    let characteristics = peripheral.characteristics();
    let find = |uuid| {
        characteristics
            .iter()
            .find(|characteristic| {
                characteristic.service_uuid == DEVICE_INFORMATION_UUID
                    && characteristic.uuid == uuid
            })
            .cloned()
    };
    let hid = Uuid::parse_str(&id.0).ok().and_then(|identifier| {
        hid_identity::identities()
            .ok()
            .and_then(|identities| identities.get(&identifier).cloned())
    });
    let (
        manufacturer_name,
        model_number,
        serial_number,
        hardware_revision,
        firmware_revision,
        software_revision,
    ) = tokio::join!(
        read_text(peripheral, find(MANUFACTURER_NAME_UUID)),
        read_text(peripheral, find(MODEL_NUMBER_UUID)),
        read_text(peripheral, find(SERIAL_NUMBER_UUID)),
        read_text(peripheral, find(HARDWARE_REVISION_UUID)),
        read_text(peripheral, find(FIRMWARE_REVISION_UUID)),
        read_text(peripheral, find(SOFTWARE_REVISION_UUID)),
    );
    let info = DeviceInfo {
        att_mtu: Some(peripheral.mtu()),
        manufacturer_name,
        model_number,
        serial_number,
        hardware_revision,
        firmware_revision,
        software_revision,
        hid_manufacturer: hid
            .as_ref()
            .and_then(|identity| identity.manufacturer.clone()),
        hid_product: hid.as_ref().and_then(|identity| identity.product.clone()),
        hid_vendor_id: hid.as_ref().and_then(|identity| identity.vendor_id),
        hid_product_id: hid.as_ref().and_then(|identity| identity.product_id),
        hid_transport: hid.as_ref().and_then(|identity| identity.transport.clone()),
        hid_serial_number: hid
            .as_ref()
            .and_then(|identity| identity.serial_number.clone()),
        hid_version_number: hid.as_ref().and_then(|identity| identity.version_number),
        physical_device_id: hid.and_then(|identity| identity.physical_device_id),
    };
    tracing::info!(
        event = "device_info",
        device_id = %id,
        att_mtu = ?info.att_mtu,
        manufacturer = ?info.manufacturer_name,
        model = ?info.model_number,
        firmware = ?info.firmware_revision,
        hardware = ?info.hardware_revision,
        hid_product = ?info.hid_product,
        hid_transport = ?info.hid_transport,
        "read connected remote device information"
    );
    info
}

async fn read_text(
    peripheral: &Peripheral,
    characteristic: Option<btleplug::api::Characteristic>,
) -> Option<String> {
    let characteristic = characteristic?;
    let bytes = match tokio::time::timeout(Duration::from_secs(2), peripheral.read(&characteristic))
        .await
    {
        Ok(Ok(bytes)) => bytes,
        Ok(Err(error)) => {
            tracing::debug!(
                event = "device_info_read_failed",
                characteristic = %characteristic.uuid,
                error = %error,
                "could not read optional Device Information characteristic"
            );
            return None;
        }
        Err(_) => {
            tracing::debug!(
                event = "device_info_read_timeout",
                characteristic = %characteristic.uuid,
                "optional Device Information read timed out"
            );
            return None;
        }
    };
    let value = String::from_utf8_lossy(&bytes)
        .trim_matches(char::from(0))
        .trim()
        .to_owned();
    (!value.is_empty()).then_some(value)
}

async fn unsubscribe_atvv(peripheral: &Peripheral) {
    for characteristic in peripheral.characteristics() {
        if [AUDIO_UUID, CONTROL_UUID].contains(&characteristic.uuid)
            && let Err(error) = peripheral.unsubscribe(&characteristic).await
        {
            tracing::warn!(
                event = "bluetooth_unsubscribe_failed",
                characteristic = %characteristic.uuid,
                error = %error,
                "could not release ATVV notification subscription"
            );
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct SupportedIdentity {
    model: &'static str,
}

fn supported_identity(identity: Option<&HidIdentity>) -> Option<SupportedIdentity> {
    let identity = identity?;
    (identity.manufacturer.as_deref() == Some(XIAOMI_MANUFACTURER)
        && identity.vendor_id == Some(XIAOMI_VENDOR_ID)
        && identity.product_id == Some(XIAOMI_PRODUCT_ID))
    .then_some(SupportedIdentity {
        model: XIAOMI_VOICE_REMOTE_MODEL,
    })
}

fn device_support(identity: Option<SupportedIdentity>) -> DeviceSupport {
    identity.map_or(DeviceSupport::Unsupported, |identity| {
        DeviceSupport::Supported {
            model: identity.model.into(),
        }
    })
}

fn log_identity(
    peripheral: &Peripheral,
    properties: &btleplug::api::PeripheralProperties,
    hid_identity: Option<&HidIdentity>,
    identity: Option<SupportedIdentity>,
) {
    let ble_manufacturer_ids: Vec<_> = properties.manufacturer_data.keys().copied().collect();
    tracing::debug!(
        event = "bluetooth_device_identified",
        device_id = %peripheral.id(),
        device_name = ?properties.local_name,
        ?ble_manufacturer_ids,
        hid_manufacturer = ?hid_identity.and_then(|identity| identity.manufacturer.as_deref()),
        hid_product = ?hid_identity.and_then(|identity| identity.product.as_deref()),
        hid_vendor_id = ?hid_identity.and_then(|identity| identity.vendor_id),
        hid_product_id = ?hid_identity.and_then(|identity| identity.product_id),
        supports_atvv = true,
        supported = identity.is_some(),
        supported_model = identity.map(|identity| identity.model),
        "classified BLE peripheral"
    );
}

fn ensure_supported(peripheral: &Peripheral) -> Result<SupportedIdentity> {
    let uuid = uuid::Uuid::parse_str(&peripheral.id().to_string())?;
    let identities = hid_identity::identities().context("list connected HID identities")?;
    supported_identity(identities.get(&uuid)).with_context(|| {
        format!(
            "unsupported Bluetooth device {}; connect a supported remote in macOS Bluetooth settings",
            peripheral.id()
        )
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_verified_hid_fingerprint_is_supported() {
        let supported = HidIdentity {
            manufacturer: Some("MIOM".into()),
            product: Some("user may rename this".into()),
            vendor_id: Some(10_007),
            product_id: Some(12_984),
            ..HidIdentity::default()
        };
        assert!(supported_identity(Some(&supported)).is_some());
        assert!(
            supported_identity(Some(&HidIdentity {
                product: Some("小米语音遥控器".into()),
                ..HidIdentity::default()
            }))
            .is_none()
        );
        assert!(
            supported_identity(Some(&HidIdentity {
                manufacturer: Some("MIOM".into()),
                vendor_id: Some(10_007),
                product_id: Some(1),
                ..HidIdentity::default()
            }))
            .is_none()
        );
        assert!(supported_identity(None).is_none());
    }
}
