/**
 * app_events.c - 全局事件队列实现
 */
#include "app_events.h"
#include <string.h>
#include "esp_log.h"

static const char *TAG = "events";
static QueueHandle_t s_evt_queue = NULL;

QueueHandle_t app_event_queue_get(void)
{
    if (s_evt_queue == NULL) {
        s_evt_queue = xQueueCreate(32, sizeof(app_event_t));
    }
    return s_evt_queue;
}

void app_event_post_key(uint8_t page, uint16_t usage, uint8_t is_down)
{
    QueueHandle_t q = app_event_queue_get();
    app_event_t ev = {0};
    ev.type = is_down ? EVT_HID_KEY_DOWN : EVT_HID_KEY_UP;
    ev.payload.hid.page    = page;
    ev.payload.hid.usage   = usage;
    ev.payload.hid.is_down = is_down;
    xQueueSend(q, &ev, 0);
}

void app_event_post_pcm(const float *samples, int count)
{
    if (count > PCM_FRAME_MAX) count = PCM_FRAME_MAX;
    QueueHandle_t q = app_event_queue_get();
    app_event_t ev = {0};
    ev.type = EVT_PCM_AUDIO;
    ev.payload.pcm.count = count;
    memcpy(ev.payload.pcm.samples, samples, count * sizeof(float));
    xQueueSend(q, &ev, 0);
}

void app_event_post_ble_state(int state)
{
    QueueHandle_t q = app_event_queue_get();
    app_event_t ev = {0};
    /* 0=disconnected, 1=connected, 2=voice_start, 3=voice_stop */
    switch (state) {
        case 0: ev.type = EVT_BLE_DISCONNECTED; break;
        case 1: ev.type = EVT_BLE_CONNECTED;    break;
        case 2: ev.type = EVT_VOICE_START;      break;
        case 3: ev.type = EVT_VOICE_STOP;       break;
        default: return;
    }
    xQueueSend(q, &ev, 0);
}
