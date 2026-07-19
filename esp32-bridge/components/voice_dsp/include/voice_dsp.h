#pragma once
#include <stdint.h>

typedef struct {
    float hp_z1, hp_z2;
    float eq_z1, eq_z2;
    float env;
    float gate;
    float gain;
} voice_dsp_t;

void voice_dsp_reset(voice_dsp_t *dsp);
void voice_dsp_process(voice_dsp_t *dsp, float *samples, int count);
