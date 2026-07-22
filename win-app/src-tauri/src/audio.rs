// audio.rs — Ring buffer + cpal 输出到 VB-Cable（移植自 Mac 版 Ring + AVAudioEngine）
// 16kHz mono Float32，和 Mac 版完全一致，无需重采样。

use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::{SampleFormat, Stream};
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
    pub device_name: String,
    pub using_vbcable: bool,
    pub sample_rate: u32,
    pub channels: u16,
    _stream: Stream, // 保持 stream 存活（drop 会停止输出）
}

impl AudioOut {
    /// 初始化音频输出。优先找 "CABLE Input"（VB-Cable），找不到用默认输出。
    pub fn new() -> Result<Self, String> {
        let ring = Arc::new(AudioRing::new());
        let ring_clone = ring.clone();

        let host = cpal::default_host();

        // 尝试找 VB-Cable
        let device = host
            .output_devices()
            .map_err(|e| format!("枚举输出设备失败: {}", e))?
            .find(|d| {
                d.name()
                    .map(|n| n.contains("CABLE Input") || n.contains("VB-Audio"))
                    .unwrap_or(false)
            })
            .or_else(|| host.default_output_device());

        let device = device.ok_or("找不到输出设备")?;

        let device_name = device.name().unwrap_or_default();
        let using_vbcable = device_name.contains("CABLE Input") || device_name.contains("VB-Audio");
        log::info!(
            "音频输出设备: {} (VB-Cable: {})",
            device_name,
            using_vbcable
        );

        // VB-CABLE 在 Windows 上通常是 44.1/48kHz 双声道，而遥控器源是 16kHz
        // 单声道。选择设备支持的 F32 配置，输出回调中再做简单重采样和声道复制。
        let supported_config = device
            .supported_output_configs()
            .map_err(|e| format!("查询设备配置失败: {}", e))?
            .find(|c| c.sample_format() == SampleFormat::F32)
            .ok_or("输出设备不支持 Float32 音频；当前版本请将 VB-CABLE 配置为共享模式默认格式")?;

        let config = supported_config.with_max_sample_rate().config();
        let sample_rate = config.sample_rate.0;
        let channels = config.channels as usize;
        let playback = Arc::new(Mutex::new(PlaybackState::new(sample_rate)));
        let playback_clone = playback.clone();

        let stream = device
            .build_output_stream(
                &config,
                move |output: &mut [f32], _: &cpal::OutputCallbackInfo| {
                    let mut state = playback_clone.lock().unwrap();
                    for frame in output.chunks_exact_mut(channels) {
                        let sample = state.next_sample(&ring_clone);
                        for channel in frame {
                            *channel = sample;
                        }
                    }
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
            device_name,
            using_vbcable,
            sample_rate,
            channels: config.channels,
            _stream: stream,
        })
    }

    /// 是否检测到 VB-Cable
    pub fn vbcable_found() -> bool {
        let host = cpal::default_host();
        if let Ok(mut devices) = host.output_devices() {
            return devices.any(|d| {
                d.name()
                    .map(|n| n.contains("CABLE Input") || n.contains("VB-Audio"))
                    .unwrap_or(false)
            });
        }
        false
    }
}

struct PlaybackState {
    step: f64,
    phase: f64,
    current: f32,
}

impl PlaybackState {
    fn new(output_rate: u32) -> Self {
        Self {
            step: 16_000.0 / output_rate as f64,
            phase: 1.0,
            current: 0.0,
        }
    }

    fn next_sample(&mut self, ring: &AudioRing) -> f32 {
        while self.phase >= 1.0 {
            self.current = ring.pop(1)[0];
            self.phase -= 1.0;
        }
        self.phase += self.step;
        self.current
    }
}
