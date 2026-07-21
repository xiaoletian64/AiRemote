// dsp.rs — 语音增强 DSP（移植自 Mac 版 Engine.swift 的 VoiceDSP + Biquad）
// 链路：DC去除 → 高通 → 低shelf → 中频EQ → 高频EQ → 高shelf → 谱减 → 噪声门 → AGC → 软限幅

/// Biquad 滤波器（Direct Form 1，移植自 Mac 版 Biquad struct）
#[derive(Clone, Copy)]
pub struct Biquad {
    b0: f32, b1: f32, b2: f32,
    a1: f32, a2: f32,
    z1: f32, z2: f32,
}

impl Biquad {
    fn new(b0: f32, b1: f32, b2: f32, a1: f32, a2: f32) -> Self {
        Self { b0, b1, b2, a1, a2, z1: 0.0, z2: 0.0 }
    }

    pub fn reset(&mut self) { self.z1 = 0.0; self.z2 = 0.0; }

    pub fn run(&mut self, x: f32) -> f32 {
        let y = self.b0 * x + self.z1;
        self.z1 = self.b1 * x - self.a1 * y + self.z2;
        self.z2 = self.b2 * x - self.a2 * y;
        y
    }

    pub fn highpass(f0: f32, fs: f32, q: f32) -> Self {
        let w = 2.0 * std::f32::consts::PI * f0 / fs;
        let cw = w.cos();
        let al = w.sin() / (2.0 * q);
        let a0 = 1.0 + al;
        Self::new(
            (1.0 + cw) / 2.0 / a0,
            -(1.0 + cw) / a0,
            (1.0 + cw) / 2.0 / a0,
            -2.0 * cw / a0,
            (1.0 - al) / a0,
        )
    }

    pub fn peaking(f0: f32, fs: f32, q: f32, db_gain: f32) -> Self {
        let a = 10.0_f32.powf(db_gain / 40.0);
        let w = 2.0 * std::f32::consts::PI * f0 / fs;
        let cw = w.cos();
        let al = w.sin() / (2.0 * q);
        let a0 = 1.0 + al / a;
        Self::new(
            (1.0 + al * a) / a0,
            -2.0 * cw / a0,
            (1.0 - al * a) / a0,
            -2.0 * cw / a0,
            (1.0 - al / a) / a0,
        )
    }

    pub fn lowshelf(f0: f32, fs: f32, q: f32, db_gain: f32) -> Self {
        let a = 10.0_f32.powf(db_gain / 40.0);
        let w = 2.0 * std::f32::consts::PI * f0 / fs;
        let cw = w.cos();
        let al = w.sin() / (2.0 * q);
        let a0 = 1.0 + al / a;
        Self::new(
            (1.0 + al * a) / a0,
            -2.0 * cw / a0,
            (1.0 - al * a) / a0,
            -2.0 * cw / a0,
            (1.0 - al / a) / a0,
        )
    }

    pub fn highshelf(f0: f32, fs: f32, q: f32, db_gain: f32) -> Self {
        let a = 10.0_f32.powf(db_gain / 40.0);
        let w = 2.0 * std::f32::consts::PI * f0 / fs;
        let cw = w.cos();
        let al = w.sin() / (2.0 * q);
        let a0 = (a + 1.0) - (a - 1.0) * cw + 2.0 * a.sqrt() * al;
        Self::new(
            (a * ((a + 1.0) + (a - 1.0) * cw + 2.0 * a.sqrt() * al)) / a0,
            (-2.0 * a * ((a + 1.0) - (a - 1.0) * cw)) / a0,
            (a * ((a + 1.0) + (a - 1.0) * cw - 2.0 * a.sqrt() * al)) / a0,
            (2.0 * ((a - 1.0) + (a + 1.0) * cw)) / a0,
            ((a + 1.0) + (a - 1.0) * cw - 2.0 * a.sqrt() * al) / a0,
        )
    }
}

/// 语音增强 DSP（移植自 Mac 版 VoiceDSP）
pub struct VoiceDsp {
    hp: Biquad,          // 高通 160Hz
    ls: Biquad,          // 低shelf 220Hz -6dB
    eq1: Biquad,         // 中频 1500Hz +2dB
    eq2: Biquad,         // 高频 3000Hz +4dB
    hs: Biquad,          // 高shelf 4000Hz +3dB
    env: f32,
    gate: f32,
    gain: f32,
    noise_floor: f32,
    noise_min: f32,
    noise_est: f32,
    dc_offset: f32,
}

impl VoiceDsp {
    pub fn new() -> Self {
        Self {
            hp: Biquad::highpass(160.0, 16000.0, 0.7),
            ls: Biquad::lowshelf(220.0, 16000.0, 0.5, -6.0),
            eq1: Biquad::peaking(1500.0, 16000.0, 1.2, 2.0),
            eq2: Biquad::peaking(3000.0, 16000.0, 1.0, 4.0),
            hs: Biquad::highshelf(4000.0, 16000.0, 0.7, 3.0),
            env: 0.0,
            gate: 0.0,
            gain: 4.0,
            noise_floor: 0.0025,
            noise_min: 1.0,
            noise_est: 0.002,
            dc_offset: 0.0,
        }
    }

    pub fn reset(&mut self) {
        self.hp.reset();
        self.ls.reset();
        self.eq1.reset();
        self.eq2.reset();
        self.hs.reset();
        self.env = 0.0;
        self.gate = 0.0;
        self.noise_floor = 0.0025;
        self.noise_min = 1.0;
        self.noise_est = 0.002;
        self.dc_offset = 0.0;
    }

    pub fn process(&mut self, xs: &[f32]) -> Vec<f32> {
        let mut out = Vec::with_capacity(xs.len());
        for &x0 in xs {
            // 1) DC 去除
            self.dc_offset += (x0 - self.dc_offset) * 0.001;
            let mut x = x0 - self.dc_offset;
            // 2) 频谱整形链
            x = self.hp.run(x);
            x = self.ls.run(x);
            x = self.eq1.run(x);
            x = self.eq2.run(x);
            x = self.hs.run(x);
            let ax = x.abs();
            self.env = ax.max(self.env * 0.999);
            self.noise_min = self.noise_min.min(ax + 1e-6);
            // 3) 宽频噪声估计
            if ax < self.noise_floor * 2.0 {
                self.noise_est += (ax - self.noise_est) * 0.02;
            }
            self.noise_est = self.noise_est.max(ax * 0.15);
            self.noise_est = self.noise_est.clamp(0.0003, 0.02);
            if ax < self.noise_floor * 2.0 {
                self.noise_floor += (self.noise_min - self.noise_floor) * 0.001;
            }
            self.noise_floor = self.noise_floor.clamp(0.0003, 0.008);
            self.noise_min = (self.noise_min + 0.00001).min(1.0);
            // 4) 宽频谱减
            if ax > self.noise_est * 1.5 {
                let over_sub = self.noise_est * 1.5;
                let reduced = (ax * ax - over_sub * over_sub).max(0.0).sqrt();
                x *= reduced / ax.max(1e-6);
            } else {
                x *= 0.1;
            }
            // 5) 噪声门
            let snr = self.env / self.noise_floor.max(1e-6);
            let gate_open = if snr > 3.0 { 1.0 }
                else if snr < 1.5 { 0.02 }
                else { (snr - 1.5) / 1.5 * 0.98 + 0.02 };
            let rate = if gate_open > self.gate { 0.05 } else { 0.0008 };
            self.gate += (gate_open - self.gate) * rate;
            x *= self.gate;
            // 6) AGC
            if self.env > self.noise_floor * 3.0 {
                let desired = (0.3 / self.env.max(1e-4)).clamp(1.0, 24.0);
                self.gain += (desired - self.gain) * 0.003;
            }
            // 7) 软限幅
            out.push((x * self.gain).tanh());
        }
        out
    }
}
