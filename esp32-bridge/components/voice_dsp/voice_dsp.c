#include "voice_dsp.h"
#include <math.h>
#include <string.h>

void voice_dsp_reset(voice_dsp_t *d) {
    memset(d, 0, sizeof(*d));
    d->gain = 4.0f;
}

void voice_dsp_process(voice_dsp_t *d, float *samples, int count) {
    static const float FLOOR = 0.0025f;
    /* 高通 100Hz, Q=0.707, fs=16000 */
    static const float HP_B0 =  0.974820f;
    static const float HP_B1 = -1.949640f;
    static const float HP_B2 =  0.974820f;
    static const float HP_A1 = -1.949640f;
    static const float HP_A2 =  0.949820f;
    /* 人声 EQ 2.5kHz, +3dB, Q=1.0, fs=16000 */
    static const float EQ_B0 =  1.251879f;
    static const float EQ_B1 = -1.958403f;
    static const float EQ_B2 =  0.748121f;
    static const float EQ_A1 = -1.958403f;
    static const float EQ_A2 =  0.748121f;

    for (int i = 0; i < count; i++) {
        float x = samples[i];
        /* 高通 */
        float y1 = HP_B0 * x + d->hp_z1;
        d->hp_z1 = HP_B1 * x - HP_A1 * y1 + d->hp_z2;
        d->hp_z2 = HP_B2 * x - HP_A2 * y1;
        /* 人声 EQ */
        float y2 = EQ_B0 * y1 + d->eq_z1;
        d->eq_z1 = EQ_B1 * y1 - EQ_A1 * y2 + d->eq_z2;
        d->eq_z2 = EQ_B2 * y1 - EQ_A2 * y2;
        x = y2;
        /* 包络 */
        d->env = fmaxf(fabsf(x), d->env * 0.999f);
        /* 噪声门 */
        float want = (d->env > FLOOR) ? 1.0f : 0.05f;
        float rate = (want > d->gate) ? 0.05f : 0.0005f;
        d->gate += (want - d->gate) * rate;
        x *= d->gate;
        /* AGC 目标响度 */
        if (d->env > FLOOR) {
            float desired = fminf(24.0f, fmaxf(1.0f, 0.25f / fmaxf(d->env, 1e-4f)));
            d->gain += (desired - d->gain) * 0.0008f;
        }
        /* 软限幅 */
        float ex = x * d->gain;
        samples[i] = tanhf(ex);
    }
}
