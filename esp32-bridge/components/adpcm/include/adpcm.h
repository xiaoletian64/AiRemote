#pragma once
#include <stdint.h>

typedef struct {
    int32_t pred;
    int32_t idx;
} adpcm_state_t;

void adpcm_reset(adpcm_state_t *s);
int adpcm_decode(adpcm_state_t *s, const uint8_t *data, int len, float *out, int out_max);
