use crate::atvv::{AUDIO_UUID, CONTROL_UUID, GET_CAPS, SERVICE_UUID, TX_UUID};
use anyhow::{Context, Result, bail};
use btleplug::{
    api::{Central, Manager as _, Peripheral as _, ScanFilter, WriteType},
    platform::{Adapter, Manager, Peripheral},
};
use futures::StreamExt;
use micflurry_control::{Device, DeviceId};
use std::time::Duration;
use tokio::{sync::mpsc, task::JoinHandle};

#[derive(Debug)]
pub enum BluetoothEvent {
    ScanComplete(Vec<Device>),
    Control(Vec<u8>),
    Audio(Vec<u8>),
    Disconnected(DeviceId),
    Error(String),
}

pub struct Bluetooth {
    adapter: Adapter,
    connected: Option<Peripheral>,
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
            notification_task: None,
        })
    }

    pub async fn start_scan(&self, sender: mpsc::Sender<BluetoothEvent>) -> Result<()> {
        self.adapter.start_scan(ScanFilter::default()).await?;
        let adapter = self.adapter.clone();
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_secs(4)).await;
            let result = collect_devices(&adapter).await;
            let _ = adapter.stop_scan().await;
            let event = match result {
                Ok(devices) => BluetoothEvent::ScanComplete(devices),
                Err(error) => BluetoothEvent::Error(format!("Bluetooth scan failed: {error:#}")),
            };
            let _ = sender.send(event).await;
        });
        Ok(())
    }

    pub async fn connect(
        &mut self,
        id: &DeviceId,
        sender: mpsc::Sender<BluetoothEvent>,
    ) -> Result<()> {
        self.disconnect().await?;
        let peripheral = self
            .adapter
            .peripherals()
            .await?
            .into_iter()
            .find(|candidate| candidate.id().to_string() == id.0)
            .with_context(|| {
                format!(
                    "Bluetooth device {} is no longer available; scan again",
                    id.0
                )
            })?;
        if !peripheral.is_connected().await? {
            peripheral.connect().await?;
        }
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

        let mut notifications = peripheral.notifications().await?;
        let watched = peripheral.clone();
        let disconnected_id = id.clone();
        self.notification_task = Some(tokio::spawn(async move {
            while let Some(notification) = notifications.next().await {
                let event = if notification.uuid == AUDIO_UUID {
                    BluetoothEvent::Audio(notification.value)
                } else if notification.uuid == CONTROL_UUID {
                    BluetoothEvent::Control(notification.value)
                } else {
                    continue;
                };
                if sender.send(event).await.is_err() {
                    return;
                }
            }
            if !watched.is_connected().await.unwrap_or(false) {
                let _ = sender
                    .send(BluetoothEvent::Disconnected(disconnected_id))
                    .await;
            }
        }));
        self.connected = Some(peripheral);
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
        Ok(())
    }

    pub async fn disconnect(&mut self) -> Result<()> {
        if let Some(task) = self.notification_task.take() {
            task.abort();
        }
        if let Some(peripheral) = self.connected.take()
            && peripheral.is_connected().await?
        {
            peripheral.disconnect().await?;
        }
        Ok(())
    }
}

async fn collect_devices(adapter: &Adapter) -> Result<Vec<Device>> {
    let mut devices = Vec::new();
    for peripheral in adapter.peripherals().await? {
        let Some(properties) = peripheral.properties().await? else {
            continue;
        };
        let supports_atvv = properties.services.contains(&SERVICE_UUID)
            || peripheral
                .services()
                .iter()
                .any(|service| service.uuid == SERVICE_UUID);
        devices.push(Device {
            id: DeviceId(peripheral.id().to_string()),
            name: properties
                .local_name
                .unwrap_or_else(|| "Unnamed BLE device".into()),
            rssi: properties.rssi,
            known: false,
            connected: peripheral.is_connected().await.unwrap_or(false),
            supports_atvv,
        });
    }
    devices.sort_by(|left, right| {
        right
            .supports_atvv
            .cmp(&left.supports_atvv)
            .then_with(|| right.rssi.cmp(&left.rssi))
    });
    if devices.is_empty() {
        bail!("no Bluetooth LE devices found");
    }
    Ok(devices)
}
