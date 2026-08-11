//! Google Voice over BLE (ATVV) v1 profile and IMA ADPCM decoder.

use uuid::{Uuid, uuid};

pub const SERVICE_UUID: Uuid = uuid!("ab5e0001-5a21-4f05-bc7d-af01f617b664");
pub const TX_UUID: Uuid = uuid!("ab5e0002-5a21-4f05-bc7d-af01f617b664");
pub const AUDIO_UUID: Uuid = uuid!("ab5e0003-5a21-4f05-bc7d-af01f617b664");
pub const CONTROL_UUID: Uuid = uuid!("ab5e0004-5a21-4f05-bc7d-af01f617b664");

pub const GET_CAPS: [u8; 6] = [0x0a, 0x01, 0x00, 0x00, 0x03, 0x03];
pub const MIC_OPEN: [u8; 2] = [0x0c, 0x00];
pub const MIC_CLOSE_ANY: [u8; 2] = [0x0d, 0xff];

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Codec {
    Adpcm8Khz,
    Adpcm16Khz,
}

impl Codec {
    #[must_use]
    pub const fn sample_rate(self) -> u32 {
        match self {
            Self::Adpcm8Khz => 8_000,
            Self::Adpcm16Khz => 16_000,
        }
    }

    fn from_byte(value: u8) -> Option<Self> {
        match value {
            0x01 => Some(Self::Adpcm8Khz),
            0x02 => Some(Self::Adpcm16Khz),
            _ => None,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ControlMessage {
    AudioStop {
        reason: u8,
    },
    AudioStart {
        reason: u8,
        codec: Codec,
        stream_id: u8,
    },
    StartSearch,
    AudioSync {
        codec: Codec,
        frame: u16,
        predictor: i16,
        step_index: u8,
    },
    Capabilities {
        version: u16,
        codecs: u8,
        interaction_model: u8,
        frame_size: u16,
        extra_configuration: u8,
        reserved: u8,
        firmware_data: Vec<u8>,
    },
    MicOpenError {
        code: u16,
    },
    Unknown {
        command: u8,
        payload: Vec<u8>,
    },
}

#[derive(Debug, thiserror::Error, Eq, PartialEq)]
pub enum ProtocolError {
    #[error("empty ATVV control notification")]
    Empty,
    #[error("ATVV command 0x{command:02x} requires {needed} payload bytes, received {actual}")]
    TooShort {
        command: u8,
        needed: usize,
        actual: usize,
    },
    #[error("unsupported ATVV codec 0x{0:02x}")]
    UnsupportedCodec(u8),
    #[error("invalid IMA ADPCM step index {0}")]
    InvalidStepIndex(u8),
}

fn payload<const N: usize>(command: u8, bytes: &[u8]) -> Result<&[u8], ProtocolError> {
    bytes.get(1..=N).ok_or(ProtocolError::TooShort {
        command,
        needed: N,
        actual: bytes.len().saturating_sub(1),
    })
}

/// Parses an ATVV control characteristic notification.
///
/// # Errors
///
/// Returns an error for truncated messages or unsupported codec identifiers.
pub fn parse_control(bytes: &[u8]) -> Result<ControlMessage, ProtocolError> {
    let command = *bytes.first().ok_or(ProtocolError::Empty)?;
    Ok(match command {
        0x00 => ControlMessage::AudioStop {
            reason: payload::<1>(command, bytes)?[0],
        },
        0x04 => {
            let data = payload::<3>(command, bytes)?;
            ControlMessage::AudioStart {
                reason: data[0],
                codec: Codec::from_byte(data[1]).ok_or(ProtocolError::UnsupportedCodec(data[1]))?,
                stream_id: data[2],
            }
        }
        0x08 => ControlMessage::StartSearch,
        0x0a => {
            let data = payload::<6>(command, bytes)?;
            ControlMessage::AudioSync {
                codec: Codec::from_byte(data[0]).ok_or(ProtocolError::UnsupportedCodec(data[0]))?,
                frame: u16::from_be_bytes([data[1], data[2]]),
                predictor: i16::from_be_bytes([data[3], data[4]]),
                step_index: data[5],
            }
        }
        0x0b => {
            let data = payload::<8>(command, bytes)?;
            ControlMessage::Capabilities {
                version: u16::from_be_bytes([data[0], data[1]]),
                codecs: data[2],
                interaction_model: data[3],
                frame_size: u16::from_be_bytes([data[4], data[5]]),
                extra_configuration: data[6],
                reserved: data[7],
                firmware_data: bytes[9..].to_vec(),
            }
        }
        0x0c => {
            let data = payload::<2>(command, bytes)?;
            ControlMessage::MicOpenError {
                code: u16::from_be_bytes([data[0], data[1]]),
            }
        }
        _ => ControlMessage::Unknown {
            command,
            payload: bytes[1..].to_vec(),
        },
    })
}

#[derive(Clone, Debug, Default)]
pub struct ImaAdpcmDecoder {
    predictor: i32,
    step_index: usize,
}

impl ImaAdpcmDecoder {
    /// Replaces decoder state from an ATVV `AUDIO_SYNC` message.
    ///
    /// # Errors
    ///
    /// Returns an error when the step index is outside the IMA ADPCM table.
    pub fn synchronize(&mut self, predictor: i16, step_index: u8) -> Result<(), ProtocolError> {
        if usize::from(step_index) >= STEP_TABLE.len() {
            return Err(ProtocolError::InvalidStepIndex(step_index));
        }
        self.predictor = i32::from(predictor);
        self.step_index = usize::from(step_index);
        Ok(())
    }

    pub fn reset(&mut self) {
        *self = Self::default();
    }

    pub fn decode(&mut self, encoded: &[u8]) -> Vec<i16> {
        let mut decoded = Vec::with_capacity(encoded.len() * 2);
        for &byte in encoded {
            decoded.push(self.decode_nibble(byte >> 4));
            decoded.push(self.decode_nibble(byte & 0x0f));
        }
        decoded
    }

    fn decode_nibble(&mut self, nibble: u8) -> i16 {
        let step = STEP_TABLE[self.step_index];
        let mut difference = step >> 3;
        if nibble & 0x04 != 0 {
            difference += step;
        }
        if nibble & 0x02 != 0 {
            difference += step >> 1;
        }
        if nibble & 0x01 != 0 {
            difference += step >> 2;
        }
        if nibble & 0x08 != 0 {
            self.predictor -= difference;
        } else {
            self.predictor += difference;
        }
        self.predictor = self
            .predictor
            .clamp(i32::from(i16::MIN), i32::from(i16::MAX));
        let next_index = (i32::try_from(self.step_index).unwrap_or(88)
            + INDEX_TABLE[usize::from(nibble)])
        .clamp(0, 88);
        self.step_index = usize::try_from(next_index).expect("clamped ADPCM step index");
        i16::try_from(self.predictor).expect("clamped ADPCM predictor")
    }
}

const INDEX_TABLE: [i32; 16] = [-1, -1, -1, -1, 2, 4, 6, 8, -1, -1, -1, -1, 2, 4, 6, 8];
const STEP_TABLE: [i32; 89] = [
    7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31, 34, 37, 41, 45, 50, 55, 60, 66,
    73, 80, 88, 97, 107, 118, 130, 143, 157, 173, 190, 209, 230, 253, 279, 307, 337, 371, 408, 449,
    494, 544, 598, 658, 724, 796, 876, 963, 1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066, 2272,
    2499, 2749, 3024, 3327, 3660, 4026, 4428, 4871, 5358, 5894, 6484, 7132, 7845, 8630, 9493,
    10442, 11487, 12635, 13899, 15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767,
];

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_audio_sync_in_network_byte_order() {
        let message = parse_control(&[0x0a, 0x02, 0x12, 0x34, 0xfe, 0xdc, 0x20]).unwrap();
        assert_eq!(
            message,
            ControlMessage::AudioSync {
                codec: Codec::Adpcm16Khz,
                frame: 0x1234,
                predictor: -292,
                step_index: 32,
            }
        );
    }

    #[test]
    fn decodes_high_nibble_first() {
        let mut decoder = ImaAdpcmDecoder::default();
        assert_eq!(decoder.decode(&[0x70]), vec![11, 13]);
    }

    #[test]
    fn rejects_bad_sync_index() {
        assert_eq!(
            ImaAdpcmDecoder::default().synchronize(0, 89),
            Err(ProtocolError::InvalidStepIndex(89))
        );
    }

    #[test]
    fn parses_complete_capability_payload_and_firmware_data() {
        assert_eq!(
            parse_control(&[0x0b, 0x01, 0x00, 0x03, 0x01, 0x00, 0xa0, 0x01, 0x00, 0xaa]).unwrap(),
            ControlMessage::Capabilities {
                version: 0x0100,
                codecs: 0x03,
                interaction_model: 0x01,
                frame_size: 160,
                extra_configuration: 0x01,
                reserved: 0,
                firmware_data: vec![0xaa],
            }
        );
    }
}
