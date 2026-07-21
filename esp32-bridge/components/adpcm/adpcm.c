#include "adpcm.h"
#include <string.h>

static const int32_t STEP[89] = {
    7,8,9,10,11,12,13,14,16,17,19,21,23,25,28,31,34,37,41,45,
    50,55,60,66,73,80,88,97,107,118,130,143,157,173,190,209,230,253,279,307,
    337,371,408,449,494,544,598,658,724,796,876,963,1060,1166,1282,1411,1552,1707,1878,2066,
    2272,2499,2749,3024,3327,3660,4026,4428,4871,5358,5894,6484,7132,7845,8630,9493,10442,11487,12635,13899,
    15289,16818,18500,20350,22385,24623,27086,29794,32767
};
static const int32_t IDXT[16] = {-1,-1,-1,-1,2,4,6,8,-1,-1,-1,-1,2,4,6,8};

void adpcm_reset(adpcm_state_t *s) { s->pred = 0; s->idx = 0; }

static float nib(adpcm_state_t *s, uint8_t n) {
    int32_t st = STEP[s->idx], d = st >> 3;
    if (n & 4) d += st; if (n & 2) d += st >> 1; if (n & 1) d += st >> 2;
    s->pred += (n & 8) ? -d : d;
    if (s->pred < -32768) s->pred = -32768; if (s->pred > 32767) s->pred = 32767;
    s->idx += IDXT[n & 15];
    if (s->idx < 0) s->idx = 0; if (s->idx > 88) s->idx = 88;
    return (float)s->pred / 32768.0f;
}

int adpcm_decode(adpcm_state_t *s, const uint8_t *data, int len, float *out, int out_max) {
    int n = 0;
    for (int i = 0; i < len && n < out_max; i++) {
        out[n++] = nib(s, data[i] & 0x0F);
        if (n < out_max) out[n++] = nib(s, (data[i] >> 4) & 0x0F);
    }
    return n;
}
