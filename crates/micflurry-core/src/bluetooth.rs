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
use micflurry_control::{Device, DeviceId, DeviceSupport};
use tokio::{sync::mpsc, task::JoinHandle};

const XIAOMI_VOICE_REMOTE_MODEL: &str = "小米语音遥控器";
const XIAOMI_MANUFACTURER: &str = "MIOM";
const XIAOMI_VENDOR_ID: u32 = 10_007;
const XIAOMI_PRODUCT_ID: u32 = 12_984;

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
    ) -> Result<()> {
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
    ) -> Result<()> {
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
    ) -> Result<()> {
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
        peripheral.subscribe(&audio).await?;
        peripheral.subscribe(&control).await?;
        peripheral
            .write(&tx, &GET_CAPS, WriteType::WithoutResponse)
            .await?;
        tracing::info!(event = "bluetooth_connected", device_id = %id, "subscribed to ATVV notifications and requested capabilities");

        let mut notifications = peripheral.notifications().await?;
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
        Ok(())
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
