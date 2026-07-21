/**
 * app_events.h - 全局事件队列
 */
#pragma once
#include <stdint.h>
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"

#ifdef __cplusplus
extern "C" {
#endif

/* 事件类型 */
typedef enum {
    EVT_HID_KEY_DOWN      = 1,
    EVT_HID_KEY_UP        = 2,
    EVT_PCM_AUDIO         = 3,
    EVT_BLE_CONNECTED     = 4,
    EVT_BLE_DISCONNECTED  = 5,
    EVT_VOICE_START       = 6,
    EVT_VOICE_STOP        = 7,
} app_event_type_t;

#define PCM_FRAME_MAX  192

typedef struct {
    app_event_type_t type;
    union {
        struct {
            uint16_t usage;
            uint8_t  page;
            uint8_t  is_down;
        } hid;
        struct {
            float   samples[PCM_FRAME_MAX];
            int     count;
        } pcm;
    } payload;
} app_event_t;

QueueHandle_t app_event_queue_get(void);
void app_event_post_key(uint8_t page, uint16_t usage, uint8_t is_down);
void app_event_post_pcm(const float *samples, int count);
void app_event_post_ble_state(int state);

#ifdef __cplusplus
}
#endif
