// audio.rs — Ring buffer + cpal 输出到 VB-Cable（移植自 Mac 版 Ring + AVAudioEngine）
// 16kHz mono Float32，和 Mac 版完全一致，无需重采样。

use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::{SampleFormat, SampleRate, Stream, StreamConfig};
use std::collections::VecDeque;
use std::sync::{Arc, Mutex};

const RING_CAPACITY: usize = 16000 * 4; // 64000 samples = 4 seconds @ 16kHz

/// 线程安全的 ring buffer（移植自 Mac 版 Ring struct）
pub struct AudioRing {
    buf: Mutex<VecDeque<f32>>,
}

impl AudioRing {
    pub fn new() -> Self {
        Self {
            buf: Mutex::new(VecDeque::with_capacity(RING_CAPACITY)),
        }
    }

    /// 推入 PCM 样本（溢出时丢弃最旧的）
    pub fn push(&self, samples: &[f32]) {
        let mut buf = self.buf.lock().unwrap();
        for &s in samples {
            buf.push_back(s);
            if buf.len() > RING_CAPACITY {
                buf.pop_front();
            }
        }
    }

    /// 取出 n 个样本，不足补零（cpal 回调用，避免杂音）
    pub fn pop(&self, n: usize) -> Vec<f32> {
        let mut buf = self.buf.lock().unwrap();
        let mut out = Vec::with_capacity(n);
        for _ in 0..n {
            out.push(buf.pop_front().unwrap_or(0.0));
        }
        out
    }

    /// 清空（语音键按下时调用，避免残留旧音频）
    pub fn clear(&self) {
        self.buf.lock().unwrap().clear();
    }
}

/// 音频输出：cpal stream → VB-Cable（或默认输出设备）
pub struct AudioOut {
    pub ring: Arc<AudioRing>,
    _stream: Stream, // 保持 stream 存活（drop 会停止输出）
}

impl AudioOut {
    /// 初始化音频输出。优先找 "CABLE Input"（VB-Cable），找不到用默认输出。
    pub fn new() -> Result<Self, String> {
        let ring = Arc::new(AudioRing::new());
        let ring_clone = ring.clone();

        let host = cpal::default_host();

        // 尝试找 VB-Cable
        let device = host.output_devices()
            .map_err(|e| format!("枚举输出设备失败: {}", e))?
            .find(|d| {
                d.name()
                    .map(|n| n.contains("CABLE Input") || n.contains("VB-Audio"))
                    .unwrap_or(false)
            })
            .or_else(|| host.default_output_device());

        let device = device.ok_or("找不到输出设备")?;

        let device_name = device.name().unwrap_or_default();
        log::info!("音频输出设备: {}", device_name);

        let supported_config = device
            .supported_output_configs()
            .map_err(|e| format!("查询设备配置失败: {}", e))?
            .find(|c| c.channels() == 1 && c.sample_format() == SampleFormat::F32)
            .or_else(|| {
                // 设备不支持单声道 F32，用默认配置
                device.supported_output_configs().ok()?.next()
            })
            .ok_or("设备不支持所需音频配置")?;

        // 固定 16kHz（和 ADPCM 解码输出一致）
        let config = StreamConfig {
            channels: 1,
            sample_rate: SampleRate(16000),
            buffer_size: cpal::BufferSize::Default,
        };

        let stream = device
            .build_output_stream(
                &config,
                move |output: &mut [f32], _: &cpal::OutputCallbackInfo| {
                    // 从 ring buffer 取数据，不足补零
                    let samples = ring_clone.pop(output.len());
                    output.copy_from_slice(&samples);
                },
                |err| log::error!("cpal 音频错误: {:?}", err),
                None,
            )
            .map_err(|e| format!("创建音频流失败: {}", e))?;

        stream
            .play()
            .map_err(|e| format!("启动音频流失败: {}", e))?;

        log::info!("音频输出已启动: 16kHz mono F32 → {}", device_name);

        Ok(AudioOut {
            ring,
            _stream: stream,
        })
    }

    /// 是否检测到 VB-Cable
    pub fn vbcable_found() -> bool {
        if let Ok(host) = cpal::default_host().output_devices() {
            return host.any(|d| {
                d.name()
                    .map(|n| n.contains("CABLE Input") || n.contains("VB-Audio"))
                    .unwrap_or(false)
            });
        }
        false
    }
}
