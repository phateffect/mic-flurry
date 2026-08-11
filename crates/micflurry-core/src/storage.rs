use anyhow::{Context, Result, bail};
use micflurry_control::{Device, Settings, SettingsChange};
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
        let connection =
            Connection::open(path).with_context(|| format!("open {}", path.display()))?;
        connection.pragma_update(None, "journal_mode", "WAL")?;
        connection.execute_batch(
            "BEGIN;
             CREATE TABLE IF NOT EXISTS settings (
                 key TEXT PRIMARY KEY NOT NULL,
                 value TEXT NOT NULL
             );
             CREATE TABLE IF NOT EXISTS known_devices (
                 id TEXT PRIMARY KEY NOT NULL,
                 name TEXT NOT NULL,
                 supports_atvv INTEGER NOT NULL,
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
             );
             PRAGMA user_version = 1;
             COMMIT;",
        )?;
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
        self.connection.execute(
            "INSERT INTO known_devices(id, name, supports_atvv, last_seen_at) VALUES (?1, ?2, ?3, ?4)
             ON CONFLICT(id) DO UPDATE SET name=excluded.name, supports_atvv=excluded.supports_atvv,
             last_seen_at=excluded.last_seen_at",
            params![device.id.0, device.name, device.supports_atvv, chrono::Utc::now().to_rfc3339()],
        )?;
        Ok(())
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
                ..SettingsChange::default()
            })
            .unwrap();
        drop(store);
        let settings = Store::open(&path).unwrap().settings().unwrap();
        assert!(settings.auto_record);
        assert_eq!(settings.output_rate_hz, 16_000);
    }
}
