// adpcm.rs — IMA ADPCM 解码器（移植自 Mac 版 Engine.swift 的 ADPCM struct）
// 格式：16kHz mono，low-nibble-first

const STEP_TABLE: [i32; 89] = [
    7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31, 34, 37, 41, 45, 50, 55, 60, 66,
    73, 80, 88, 97, 107, 118, 130, 143, 157, 173, 190, 209, 230, 253, 279, 307, 337, 371, 408, 449,
    494, 544, 598, 658, 724, 796, 876, 963, 1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066, 2272,
    2499, 2749, 3024, 3327, 3660, 4026, 4428, 4871, 5358, 5894, 6484, 7132, 7845, 8630, 9493,
    10442, 11487, 12635, 13899, 15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767,
];

const INDEX_TABLE: [i32; 16] = [-1, -1, -1, -1, 2, 4, 6, 8, -1, -1, -1, -1, 2, 4, 6, 8];

pub struct AdpcmDecoder {
    predictor: i32,
    index: i32,
}

impl AdpcmDecoder {
    pub fn new() -> Self {
        Self {
            predictor: 0,
            index: 0,
        }
    }

    pub fn reset(&mut self) {
        self.predictor = 0;
        self.index = 0;
    }

    /// 解码一个 nibble（4 位）→ Float32 样本
    fn decode_nibble(&mut self, nibble: u8) -> f32 {
        let step = STEP_TABLE[self.index as usize];
        let mut diff = step >> 3;
        if nibble & 4 != 0 {
            diff += step;
        }
        if nibble & 2 != 0 {
            diff += step >> 1;
        }
        if nibble & 1 != 0 {
            diff += step >> 2;
        }
        self.predictor = if nibble & 8 != 0 {
            self.predictor - diff
        } else {
            self.predictor + diff
        };
        self.predictor = self.predictor.clamp(-32768, 32767);
        self.index += INDEX_TABLE[(nibble & 15) as usize];
        self.index = self.index.clamp(0, 88);
        self.predictor as f32 / 32768.0
    }

    /// 解码一段 ADPCM 数据 → Float32 PCM 样本数组
    /// low-nibble-first：每字节先解低 4 位，再解高 4 位
    pub fn decode(&mut self, data: &[u8]) -> Vec<f32> {
        let mut out = Vec::with_capacity(data.len() * 2);
        for &byte in data {
            out.push(self.decode_nibble(byte & 15));
            out.push(self.decode_nibble((byte >> 4) & 15));
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_decode_silence() {
        let mut decoder = AdpcmDecoder::new();
        // 全零数据应解码出接近零的样本
        let silence = vec![0u8; 10];
        let pcm = decoder.decode(&silence);
        assert_eq!(pcm.len(), 20);
        // 全零 nibble → predictor 不变（始终 0）
        for sample in &pcm {
            assert!(sample.abs() < 0.001);
        }
    }
}
