pub trait AudioSink: Send {
    fn push(&mut self, samples: &[f32]);
    fn dropped_samples(&self) -> u64;
}

#[cfg(target_os = "macos")]
pub use macos::CoreAudioSink;

#[cfg(not(target_os = "macos"))]
pub struct CoreAudioSink {
    dropped: u64,
}

#[cfg(not(target_os = "macos"))]
impl CoreAudioSink {
    pub fn open(_uid: &str, _sample_rate: u32) -> anyhow::Result<Self> {
        anyhow::bail!("CoreAudio output is only available on macOS")
    }
}

#[cfg(not(target_os = "macos"))]
impl AudioSink for CoreAudioSink {
    fn push(&mut self, samples: &[f32]) {
        self.dropped += samples.len() as u64;
    }
    fn dropped_samples(&self) -> u64 {
        self.dropped
    }
}

/// Keeps the TUI usable for discovery/configuration if the driver is not installed yet.
pub struct DisconnectedSink {
    dropped: u64,
}

impl DisconnectedSink {
    pub const fn new() -> Self {
        Self { dropped: 0 }
    }
}

impl AudioSink for DisconnectedSink {
    fn push(&mut self, samples: &[f32]) {
        self.dropped += samples.len() as u64;
    }
    fn dropped_samples(&self) -> u64 {
        self.dropped
    }
}

#[cfg(target_os = "macos")]
mod macos {
    use super::AudioSink;
    use anyhow::{Context, Result, bail};
    use coreaudio::audio_unit::{
        AudioUnit, Element, SampleFormat, Scope, StreamFormat,
        audio_format::LinearPcmFlags,
        macos_helpers,
        render_callback::{Args, data},
    };
    use objc2_core_audio::{
        AudioDeviceID, AudioObjectGetPropertyData, AudioObjectPropertyAddress,
        kAudioHardwarePropertyTranslateUIDToDevice, kAudioObjectPropertyElementMain,
        kAudioObjectPropertyScopeGlobal, kAudioObjectSystemObject,
    };
    use objc2_core_foundation::CFString;
    use std::{
        collections::VecDeque,
        ptr::NonNull,
        sync::{
            Arc, Mutex,
            atomic::{AtomicU64, Ordering},
        },
    };

    pub struct CoreAudioSink {
        _audio_unit: AudioUnit,
        queue: Arc<Mutex<VecDeque<f32>>>,
        capacity: usize,
        dropped: Arc<AtomicU64>,
    }

    impl CoreAudioSink {
        pub fn open(uid: &str, sample_rate: u32) -> Result<Self> {
            // The injection endpoint is hidden from normal device enumeration, so resolve its UID
            // through the HAL system object instead of looking through the public device list.
            let device = device_id_for_uid(uid)
                .with_context(|| format!("CoreAudio output UID {uid} is not installed"))?;
            let mut audio_unit =
                macos_helpers::audio_unit_from_device_id_uninitialized(device, false)?;
            audio_unit.set_stream_format(
                StreamFormat {
                    sample_rate: f64::from(sample_rate),
                    sample_format: SampleFormat::F32,
                    flags: LinearPcmFlags::IS_FLOAT
                        | LinearPcmFlags::IS_PACKED
                        | LinearPcmFlags::IS_NON_INTERLEAVED,
                    channels: 1,
                },
                Scope::Input,
                Element::Output,
            )?;
            let capacity = usize::try_from(sample_rate).unwrap_or(48_000) / 2;
            let queue = Arc::new(Mutex::new(VecDeque::with_capacity(capacity)));
            let render_queue = Arc::clone(&queue);
            let dropped = Arc::new(AtomicU64::new(0));
            audio_unit.set_render_callback(move |mut args: Args<data::NonInterleaved<f32>>| {
                if let Ok(mut samples) = render_queue.try_lock() {
                    for channel in args.data.channels_mut() {
                        for output in channel {
                            *output = samples.pop_front().unwrap_or(0.0);
                        }
                    }
                } else {
                    for channel in args.data.channels_mut() {
                        channel.fill(0.0);
                    }
                }
                Ok(())
            })?;
            audio_unit.initialize()?;
            audio_unit.start()?;
            Ok(Self {
                _audio_unit: audio_unit,
                queue,
                capacity,
                dropped,
            })
        }
    }

    impl AudioSink for CoreAudioSink {
        fn push(&mut self, samples: &[f32]) {
            if let Ok(mut queue) = self.queue.lock() {
                let available = self.capacity.saturating_sub(queue.len());
                queue.extend(samples.iter().take(available).copied());
                self.dropped.fetch_add(
                    (samples.len() - available.min(samples.len())) as u64,
                    Ordering::Relaxed,
                );
            } else {
                self.dropped
                    .fetch_add(samples.len() as u64, Ordering::Relaxed);
            }
        }

        fn dropped_samples(&self) -> u64 {
            self.dropped.load(Ordering::Relaxed)
        }
    }

    #[allow(unsafe_code)]
    fn device_id_for_uid(uid: &str) -> Result<AudioDeviceID> {
        use std::mem::size_of;
        let address = AudioObjectPropertyAddress {
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain,
        };
        let qualifier = CFString::from_str(uid);
        let qualifier_ref: *const CFString = &raw const *qualifier;
        let mut device = AudioDeviceID::default();
        let size = u32::try_from(size_of::<AudioDeviceID>()).unwrap_or(4);
        let status = unsafe {
            AudioObjectGetPropertyData(
                kAudioObjectSystemObject as u32,
                NonNull::from(&address),
                u32::try_from(size_of::<*const CFString>()).unwrap_or(8),
                (&raw const qualifier_ref).cast(),
                NonNull::from(&size),
                NonNull::from(&mut device).cast(),
            )
        };
        if status != 0 {
            bail!("CoreAudio UID translation failed: {status}");
        }
        if device == 0 {
            bail!("CoreAudio returned no device for UID {uid}");
        }
        Ok(device)
    }
}
