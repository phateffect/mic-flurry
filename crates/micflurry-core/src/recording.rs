use anyhow::{Context, Result};
use chrono::{DateTime, Utc};
use hound::{SampleFormat, WavSpec, WavWriter};
use std::{
    fs::File,
    io::BufWriter,
    path::{Path, PathBuf},
};

pub struct Recording {
    writer: WavWriter<BufWriter<File>>,
    pub path: PathBuf,
    pub started_at: DateTime<Utc>,
    pub sample_count: u64,
    pub sample_rate: u32,
}

impl Recording {
    pub fn create(directory: &Path, sample_rate: u32) -> Result<Self> {
        std::fs::create_dir_all(directory)
            .with_context(|| format!("create {}", directory.display()))?;
        let started_at = Utc::now();
        let path = directory.join(format!(
            "micflurry-{}.wav",
            started_at.format("%Y%m%dT%H%M%S%.3fZ")
        ));
        let writer = WavWriter::create(
            &path,
            WavSpec {
                channels: 1,
                sample_rate,
                bits_per_sample: 32,
                sample_format: SampleFormat::Float,
            },
        )
        .with_context(|| format!("create {}", path.display()))?;
        Ok(Self {
            writer,
            path,
            started_at,
            sample_count: 0,
            sample_rate,
        })
    }

    pub fn write(&mut self, samples: &[f32]) -> Result<()> {
        for &sample in samples {
            self.writer.write_sample(sample)?;
        }
        self.sample_count += samples.len() as u64;
        Ok(())
    }

    pub fn finish(self) -> Result<FinishedRecording> {
        self.writer.finalize()?;
        Ok(FinishedRecording {
            path: self.path,
            started_at: self.started_at,
            finished_at: Utc::now(),
            sample_count: self.sample_count,
            sample_rate: self.sample_rate,
        })
    }
}

pub struct FinishedRecording {
    pub path: PathBuf,
    pub started_at: DateTime<Utc>,
    pub finished_at: DateTime<Utc>,
    pub sample_count: u64,
    pub sample_rate: u32,
}
