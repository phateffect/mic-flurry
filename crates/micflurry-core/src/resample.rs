//! Stateful mono linear resampler suitable for the speech-rate ATVV stream.

#[derive(Debug)]
pub struct LinearResampler {
    input_rate: u32,
    output_rate: u32,
    previous: Option<f32>,
    input_position: u64,
    next_output_position: f64,
}

impl LinearResampler {
    pub fn new(input_rate: u32, output_rate: u32) -> Self {
        Self {
            input_rate,
            output_rate,
            previous: None,
            input_position: 0,
            next_output_position: 0.0,
        }
    }

    pub fn reconfigure(&mut self, input_rate: u32, output_rate: u32) {
        *self = Self::new(input_rate, output_rate);
    }

    // Long-running sample positions exceed exact f32 precision, so timing stays in f64; the
    // interpolation fraction is intentionally narrowed only when producing f32 audio.
    #[allow(clippy::cast_precision_loss, clippy::cast_possible_truncation)]
    pub fn process_i16(&mut self, samples: &[i16]) -> Vec<f32> {
        let mut output = Vec::with_capacity(
            samples.len() * usize::try_from(self.output_rate).unwrap_or(1)
                / usize::try_from(self.input_rate).unwrap_or(1)
                + 2,
        );
        for &sample in samples {
            let current = f32::from(sample) / 32768.0;
            let current_position = self.input_position as f64;
            if let Some(previous) = self.previous {
                let previous_position = current_position - 1.0;
                while self.next_output_position <= current_position {
                    let fraction =
                        (self.next_output_position - previous_position).clamp(0.0, 1.0) as f32;
                    output.push(previous + (current - previous) * fraction);
                    self.next_output_position +=
                        f64::from(self.input_rate) / f64::from(self.output_rate);
                }
            } else {
                output.push(current);
                self.next_output_position =
                    f64::from(self.input_rate) / f64::from(self.output_rate);
            }
            self.previous = Some(current);
            self.input_position += 1;
        }
        output
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde::Deserialize;
    use std::{fs, path::PathBuf};

    #[derive(Deserialize)]
    struct Fixtures {
        resampling: Vec<ResamplingFixture>,
    }

    #[derive(Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct ResamplingFixture {
        input_rate: u32,
        output_rate: u32,
        blocks: Vec<Vec<i16>>,
        expected: Vec<f32>,
    }

    fn fixtures() -> Fixtures {
        let path = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../Fixtures/audio-core.json");
        serde_json::from_slice(&fs::read(path).unwrap()).unwrap()
    }

    #[test]
    fn shared_resampling_fixtures_match_the_accepted_rust_behavior() {
        for fixture in fixtures().resampling {
            let mut resampler = LinearResampler::new(fixture.input_rate, fixture.output_rate);
            let actual: Vec<f32> = fixture
                .blocks
                .iter()
                .flat_map(|block| resampler.process_i16(block))
                .collect();
            assert_eq!(actual.len(), fixture.expected.len());
            for (actual, expected) in actual.iter().zip(fixture.expected) {
                assert!((actual - expected).abs() < 0.000_001);
            }
        }
    }

    #[test]
    fn upsamples_across_block_boundaries() {
        let mut resampler = LinearResampler::new(8_000, 16_000);
        let mut output = resampler.process_i16(&[0, 10_000]);
        output.extend(resampler.process_i16(&[20_000]));
        assert_eq!(output.len(), 5);
        assert!((output[3] - (15_000.0 / 32768.0)).abs() < 0.0001);
    }

    #[test]
    fn downsample_count_is_stable() {
        let mut resampler = LinearResampler::new(16_000, 8_000);
        let output = resampler.process_i16(&vec![0; 160]);
        assert_eq!(output.len(), 80);
    }
}
