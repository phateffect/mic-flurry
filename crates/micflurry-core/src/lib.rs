//! Foreground `MicFlurry` runtime: BLE, ATVV audio, `CoreAudio`, persistence and actions.

pub mod atvv;
mod audio;
mod bluetooth;
mod hid_identity;
mod keyboard;
mod recording;
mod resample;
mod runtime;
mod storage;

pub use runtime::{LocalControlClient, RuntimeOptions, start};
