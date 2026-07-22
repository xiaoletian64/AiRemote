// ble.rs — BLE ATVV 语音传输（移植自 Mac 版 Engine.swift BLE 路径）
// 小米/联想遥控器的语音走 BLE ATVV 协议（服务 AB5E0001...）
// 数据流：BLE RX 通知 → ADPCM 解码 → DSP 增强 → ring buffer → cpal → VB-Cable

use crate::adpcm::AdpcmDecoder;
use crate::audio::AudioRing;
use crate::dsp::VoiceDsp;
use btleplug::api::{
    Central, Manager as _, Peripheral as _, ScanFilter, ValueNotification, WriteType,
};
use btleplug::platform::{Adapter, Manager, Peripheral};
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::Arc;
use tokio::time::{timeout, Duration};
use uuid::Uuid;

// ATVV 协议常量（和 Mac 版 Engine.swift 完全一致）
const UUID_ATVV: Uuid = Uuid::from_u128(0xAB5E0001_5A21_4F05_BC7D_AF01F617B664);
const UUID_TX: Uuid = Uuid::from_u128(0xAB5E0002_5A21_4F05_BC7D_AF01F617B664);
const UUID_RX: Uuid = Uuid::from_u128(0xAB5E0003_5A21_4F05_BC7D_AF01F617B664);
const UUID_CTL: Uuid = Uuid::from_u128(0xAB5E0004_5A21_4F05_BC7D_AF01F617B664);

// GET_CAPS 握手字节
const GET_CAPS: &[u8] = &[0x0A, 0x00, 0x06, 0x00, 0x01];

/// BLE 语音传输器
pub struct BleVoice {
    pub streaming: Arc<AtomicBool>,
    pub mic_streaming: Arc<AtomicBool>,
    pub packet_count: Arc<AtomicU32>,
    pub voice_connected: Arc<AtomicBool>,
}

impl BleVoice {
    pub fn new() -> Self {
        Self {
            streaming: Arc::new(AtomicBool::new(false)),
            mic_streaming: Arc::new(AtomicBool::new(false)),
            packet_count: Arc::new(AtomicU32::new(0)),
            voice_connected: Arc::new(AtomicBool::new(false)),
        }
    }

    /// 启动 BLE 语音监听（异步，需在 tokio runtime 中运行）
    pub async fn run(
        &self,
        ring: Arc<AudioRing>,
        log: impl Fn(&str) + Send + 'static,
    ) {
        loop {
            log("BLE 语音：初始化蓝牙适配器…");
            match self.connect_and_stream(ring.clone(), &log).await {
                Ok(()) => {
                    log("BLE 语音：连接结束，3 秒后重试");
                }
                Err(e) => {
                    log(&format!("BLE 语音错误: {}，3 秒后重试", e));
                }
            }
            tokio::time::sleep(Duration::from_secs(3)).await;
        }
    }

    async fn connect_and_stream(
        &self,
        ring: Arc<AudioRing>,
        log: &impl Fn(&str),
    ) -> Result<(), String> {
        // 1. 获取蓝牙适配器
        let manager = Manager::new()
            .await
            .map_err(|e| format!("蓝牙管理器初始化失败: {}", e))?;
        let adapters = manager
            .adapters()
            .await
            .map_err(|e| format!("枚举适配器失败: {}", e))?;
        let adapter = adapters
            .into_iter()
            .next()
            .ok_or("没有找到蓝牙适配器")?;

        // 2. 扫描 BLE 设备（无过滤，因为 Windows 广播名常缺失）
        log("BLE 语音：正在扫描 BLE 设备…");
        adapter
            .start_scan(ScanFilter::default())
            .await
            .map_err(|e| format!("启动扫描失败: {}", e))?;

        // 3. 等待发现 ATVV 服务设备（最多 30 秒）
        let peripheral = timeout(Duration::from_secs(30), async {
            loop {
                let peripherals = adapter.peripherals().await.unwrap_or_default();
                for p in &peripherals {
                    // 检查设备名称
                    if let Ok(Some(props)) = p.properties().await {
                        if let Some(ref name) = props.local_name {
                            let name_lower = name.to_lowercase();
                            if name_lower.contains("xiaomi")
                                || name_lower.contains("遥控")
                                || name_lower.contains("remote")
                                || name_lower.contains("rc003")
                                || name_lower.contains("xiaoxin")
                            {
                                return p.clone();
                            }
                        }
                        // 也检查 advertised services
                        if props.services.contains(&UUID_ATVV) {
                            return p.clone();
                        }
                    }
                }
                tokio::time::sleep(Duration::from_secs(1)).await;
            }
        })
        .await
        .map_err(|_| "30 秒内未发现 ATVV 设备".to_string())?;

        log("BLE 语音：发现设备，正在连接…");

        // 4. 连接
        peripheral
            .connect()
            .await
            .map_err(|e| format!("BLE 连接失败: {}", e))?;

        log("BLE 语音：已连接，正在发现服务…");

        // 5. 发现服务和特征
        peripheral
            .discover_services()
            .await
            .map_err(|e| format!("发现服务失败: {}", e))?;

        let chars = peripheral.characteristics();

        // 找 ATVV 特征
        let tx = chars
            .iter()
            .find(|c| c.uuid == UUID_TX)
            .ok_or("未找到 TX 特征")?
            .clone();
        let rx = chars
            .iter()
            .find(|c| c.uuid == UUID_RX)
            .ok_or("未找到 RX 特征")?
            .clone();
        let ctl = chars
            .iter()
            .find(|c| c.uuid == UUID_CTL)
            .ok_or("未找到 CTL 特征")?
            .clone();

        log("BLE 语音：找到 TX/RX/CTL 特征");

        // 6. 订阅 RX + CTL
        peripheral
            .subscribe(&rx)
            .await
            .map_err(|e| format!("订阅 RX 失败: {}", e))?;
        peripheral
            .subscribe(&ctl)
            .await
            .map_err(|e| format!("订阅 CTL 失败: {}", e))?;

        log("BLE 语音：已订阅 RX + CTL");

        // 7. 发送 GET_CAPS 握手
        peripheral
            .write(&tx, GET_CAPS, WriteType::WithResponse)
            .await
            .map_err(|e| format!("GET_CAPS 写入失败: {}", e))?;

        self.voice_connected.store(true, Ordering::Relaxed);
        log("BLE 语音：ATVV 握手完成，等待语音键…");

        // 8. 通知循环
        let mut codec = AdpcmDecoder::new();
        let mut dsp = VoiceDsp::new();
        let mut notifications = peripheral
            .notifications()
            .await
            .map_err(|e| format!("获取通知流失败: {}", e))?;

        use tokio_stream::StreamExt;
        while let Some(notification) = notifications.next().await {
            if notification.uuid == UUID_RX {
                // 音频帧
                if self.streaming.load(Ordering::Relaxed) {
                    self.packet_count.fetch_add(1, Ordering::Relaxed);
                    let pcm = codec.decode(&notification.value);
                    let enhanced = dsp.process(&pcm);
                    if self.mic_streaming.load(Ordering::Relaxed) {
                        ring.push(&enhanced);
                    }
                }
            } else if notification.uuid == UUID_CTL {
                // 语音键按下/松开
                if let Some(&first_byte) = notification.value.first() {
                    match first_byte {
                        0x04 => {
                            // 语音键按下：重置解码器 + DSP，开始流式传输
                            codec.reset();
                            dsp.reset();
                            self.streaming.store(true, Ordering::Relaxed);
                            self.packet_count.store(0, Ordering::Relaxed);
                            ring.clear();
                            log("🎤 语音键按下，开始接收音频…");

                            // 1.2 秒握手超时：如果没收到音频帧，重发 GET_CAPS
                            let tx_clone = tx.clone();
                            let peripheral_clone = peripheral.clone();
                            let packet_count_clone = self.packet_count.clone();
                            let streaming_clone = self.streaming.clone();
                            let log_clone = log; // 简化：闭包不捕获 log
                            tokio::spawn(async move {
                                tokio::time::sleep(Duration::from_millis(1200)).await;
                                if streaming_clone.load(Ordering::Relaxed)
                                    && packet_count_clone.load(Ordering::Relaxed) == 0
                                {
                                    let _ = peripheral_clone
                                        .write(&tx_clone, GET_CAPS, WriteType::WithResponse)
                                        .await;
                                    log_clone("⚠️ 1.2s 无音频帧，已重发 GET_CAPS");
                                }
                            });
                        }
                        0x00 => {
                            // 语音键松开：延迟 300ms 收尾音包
                            log("语音键松开，等待尾音包…");
                            let streaming = self.streaming.clone();
                            let mic_streaming = self.mic_streaming.clone();
                            let ring_clone = ring.clone();
                            tokio::spawn(async move {
                                tokio::time::sleep(Duration::from_millis(300)).await;
                                streaming.store(false, Ordering::Relaxed);
                                mic_streaming.store(false, Ordering::Relaxed);
                            });
                        }
                        _ => {}
                    }
                }
            }
        }

        // 通知流结束 = 断开
        self.voice_connected.store(false, Ordering::Relaxed);
        self.streaming.store(false, Ordering::Relaxed);
        log("BLE 语音：通知流结束（设备断开）");
        Ok(())
    }
}
