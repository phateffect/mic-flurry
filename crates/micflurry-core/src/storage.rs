use anyhow::{Context, Result, bail};
use micflurry_control::{Device, DeviceId, Settings, SettingsChange};
use rusqlite::{Connection, OptionalExtension, params};
use std::path::{Path, PathBuf};

pub struct Store {
    connection: Connection,
}

impl Store {
    pub fn open(path: &Path) -> Result<Self> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)
                .with_context(|| format!("create {}", parent.display()))?;
        }
        let mut connection =
            Connection::open(path).with_context(|| format!("open {}", path.display()))?;
        connection.pragma_update(None, "journal_mode", "WAL")?;
        let transaction = connection.transaction()?;
        transaction.execute_batch(
            "CREATE TABLE IF NOT EXISTS settings (
                 key TEXT PRIMARY KEY NOT NULL,
                 value TEXT NOT NULL
             );
             CREATE TABLE IF NOT EXISTS known_devices (
                 id TEXT PRIMARY KEY NOT NULL,
                 name TEXT NOT NULL,
                 supports_atvv INTEGER NOT NULL,
                 supported_model TEXT,
                 last_seen_at TEXT NOT NULL
             );
             CREATE TABLE IF NOT EXISTS recordings (
                 id INTEGER PRIMARY KEY AUTOINCREMENT,
                 path TEXT UNIQUE NOT NULL,
                 device_id TEXT,
                 sample_rate_hz INTEGER NOT NULL,
                 sample_count INTEGER NOT NULL,
                 started_at TEXT NOT NULL,
                 finished_at TEXT NOT NULL
             );",
        )?;
        let has_supported_model = transaction.query_row(
            "SELECT EXISTS(
                 SELECT 1 FROM pragma_table_info('known_devices') WHERE name='supported_model'
             )",
            [],
            |row| row.get::<_, bool>(0),
        )?;
        if !has_supported_model {
            transaction.execute(
                "ALTER TABLE known_devices ADD COLUMN supported_model TEXT",
                [],
            )?;
        }
        transaction.pragma_update(None, "user_version", 2)?;
        transaction.commit()?;
        Ok(Self { connection })
    }

    pub fn settings(&self) -> Result<Settings> {
        let default_recordings = dirs::audio_dir()
            .unwrap_or_else(|| PathBuf::from("."))
            .join("MicFlurry")
            .to_string_lossy()
            .into_owned();
        Ok(Settings {
            injection_device_uid: self
                .get("injection_device_uid")?
                .unwrap_or_else(|| "MicFlurry_2_UID".into()),
            output_rate_hz: self
                .get("output_rate_hz")?
                .and_then(|value| value.parse().ok())
                .unwrap_or(48_000),
            input_gain_db: self
                .get("input_gain_db")?
                .and_then(|value| value.parse().ok())
                .unwrap_or(12.0),
            recording_directory: self
                .get("recording_directory")?
                .unwrap_or(default_recordings),
            auto_record: self
                .get("auto_record")?
                .is_some_and(|value| value == "true"),
        })
    }

    pub fn update_settings(&mut self, change: SettingsChange) -> Result<Settings> {
        if let Some(uid) = change.injection_device_uid {
            if uid.trim().is_empty() {
                bail!("injection device UID cannot be empty");
            }
            self.set("injection_device_uid", uid.trim())?;
        }
        if let Some(rate) = change.output_rate_hz {
            if ![8_000, 16_000, 44_100, 48_000].contains(&rate) {
                bail!("unsupported output rate {rate}");
            }
            self.set("output_rate_hz", &rate.to_string())?;
        }
        if let Some(gain_db) = change.input_gain_db {
            if !gain_db.is_finite() || !(-24.0..=24.0).contains(&gain_db) {
                bail!("input gain must be between -24 and +24 dB");
            }
            self.set("input_gain_db", &gain_db.to_string())?;
        }
        if let Some(directory) = change.recording_directory {
            if directory.trim().is_empty() {
                bail!("recording directory cannot be empty");
            }
            self.set("recording_directory", directory.trim())?;
        }
        if let Some(enabled) = change.auto_record {
            self.set("auto_record", if enabled { "true" } else { "false" })?;
        }
        self.settings()
    }

    pub fn remember_device(&self, device: &Device) -> Result<()> {
        if !device.support.is_supported() {
            bail!("refusing to remember an unsupported Bluetooth device");
        }
        let transaction = self.connection.unchecked_transaction()?;
        transaction.execute(
            "INSERT INTO known_devices(
                 id, name, supports_atvv, supported_model, last_seen_at
             ) VALUES (?1, ?2, ?3, ?4, ?5)
             ON CONFLICT(id) DO UPDATE SET name=excluded.name, supports_atvv=excluded.supports_atvv,
             supported_model=excluded.supported_model, last_seen_at=excluded.last_seen_at",
            params![
                device.id.0,
                device.name,
                device.supports_atvv,
                device.support.model(),
                chrono::Utc::now().to_rfc3339()
            ],
        )?;
        transaction.execute(
            "INSERT INTO settings(key, value) VALUES ('last_connected_device_id', ?1)
             ON CONFLICT(key) DO UPDATE SET value=excluded.value",
            [&device.id.0],
        )?;
        transaction.commit()?;
        Ok(())
    }

    pub fn last_connected_device_id(&self) -> Result<Option<DeviceId>> {
        if let Some(id) = self.get("last_connected_device_id")? {
            let supported = self
                .connection
                .query_row(
                    "SELECT supported_model FROM known_devices WHERE id=?1",
                    [&id],
                    |row| row.get::<_, Option<String>>(0),
                )
                .optional()?
                .flatten()
                .is_some();
            if supported {
                return Ok(Some(DeviceId(id)));
            }
        }
        Ok(self
            .connection
            .query_row(
                "SELECT id FROM known_devices
                 WHERE supported_model IS NOT NULL
                 ORDER BY last_seen_at DESC LIMIT 1",
                [],
                |row| row.get::<_, String>(0),
            )
            .optional()?
            .map(DeviceId))
    }

    pub fn is_known(&self, id: &str) -> Result<bool> {
        Ok(self
            .connection
            .query_row("SELECT 1 FROM known_devices WHERE id=?1", [id], |_| Ok(()))
            .optional()?
            .is_some())
    }

    pub fn add_recording(
        &self,
        path: &str,
        device_id: Option<&str>,
        rate: u32,
        samples: u64,
        started_at: &str,
        finished_at: &str,
    ) -> Result<()> {
        self.connection.execute(
            "INSERT INTO recordings(path, device_id, sample_rate_hz, sample_count, started_at, finished_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            params![path, device_id, rate, samples, started_at, finished_at],
        )?;
        Ok(())
    }

    fn get(&self, key: &str) -> Result<Option<String>> {
        Ok(self
            .connection
            .query_row("SELECT value FROM settings WHERE key=?1", [key], |row| {
                row.get(0)
            })
            .optional()?)
    }

    fn set(&mut self, key: &str, value: &str) -> Result<()> {
        self.connection.execute(
            "INSERT INTO settings(key, value) VALUES (?1, ?2)
             ON CONFLICT(key) DO UPDATE SET value=excluded.value",
            [key, value],
        )?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn persists_settings_and_migrates() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("state.db");
        let mut store = Store::open(&path).unwrap();
        store
            .update_settings(SettingsChange {
                auto_record: Some(true),
                output_rate_hz: Some(16_000),
                input_gain_db: Some(9.0),
                ..SettingsChange::default()
            })
            .unwrap();
        drop(store);
        let settings = Store::open(&path).unwrap().settings().unwrap();
        assert!(settings.auto_record);
        assert_eq!(settings.output_rate_hz, 16_000);
        assert!((settings.input_gain_db - 9.0).abs() < f32::EPSILON);
    }

    #[test]
    fn defaults_to_twelve_db_and_rejects_unsafe_gain() {
        let directory = tempfile::tempdir().unwrap();
        let mut store = Store::open(&directory.path().join("state.db")).unwrap();
        assert!((store.settings().unwrap().input_gain_db - 12.0).abs() < f32::EPSILON);
        assert!(
            store
                .update_settings(SettingsChange {
                    input_gain_db: Some(25.0),
                    ..SettingsChange::default()
                })
                .is_err()
        );
    }

    #[test]
    fn remembers_the_last_connected_device() {
        let directory = tempfile::tempdir().unwrap();
        let store = Store::open(&directory.path().join("state.db")).unwrap();
        assert_eq!(store.last_connected_device_id().unwrap(), None);
        let device = Device {
            id: DeviceId("8f61ca0d-0025-4f26-a6a9-e787acbf6771".into()),
            name: "Remote".into(),
            rssi: Some(-42),
            known: false,
            connected: true,
            supports_atvv: true,
            support: micflurry_control::DeviceSupport::Supported {
                model: "小米语音遥控器".into(),
            },
        };
        store.remember_device(&device).unwrap();
        assert_eq!(store.last_connected_device_id().unwrap(), Some(device.id));
    }

    #[test]
    fn selects_the_latest_supported_device_from_an_existing_database() {
        let directory = tempfile::tempdir().unwrap();
        let store = Store::open(&directory.path().join("state.db")).unwrap();
        store
            .connection
            .execute(
                "INSERT INTO known_devices(
                     id, name, supports_atvv, supported_model, last_seen_at
                 ) VALUES ('older', 'Older', 1, 'Supported Remote', '2026-08-12T00:00:00Z'),
                          ('newer', 'Newer', 1, 'Supported Remote', '2026-08-13T00:00:00Z')",
                [],
            )
            .unwrap();
        assert_eq!(
            store.last_connected_device_id().unwrap(),
            Some(DeviceId("newer".into()))
        );
    }

    #[test]
    fn old_atvv_records_are_not_trusted_for_automatic_selection() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("state.db");
        {
            let connection = Connection::open(&path).unwrap();
            connection
                .execute_batch(
                    "CREATE TABLE settings (
                         key TEXT PRIMARY KEY NOT NULL,
                         value TEXT NOT NULL
                     );
                     CREATE TABLE known_devices (
                         id TEXT PRIMARY KEY NOT NULL,
                         name TEXT NOT NULL,
                         supports_atvv INTEGER NOT NULL,
                         last_seen_at TEXT NOT NULL
                     );
                     INSERT INTO known_devices VALUES (
                         'legacy', 'Unknown ATVV', 1, '2026-08-13T00:00:00Z'
                     );
                     INSERT INTO settings VALUES ('last_connected_device_id', 'legacy');",
                )
                .unwrap();
        }
        let store = Store::open(&path).unwrap();
        assert_eq!(store.last_connected_device_id().unwrap(), None);
    }
}
