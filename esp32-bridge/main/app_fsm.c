/**
 * app_fsm.c - 中央状态机
 *
 * 消费事件队列。
 *   HID 按键 → usb_hid 发到 PC
 *   PCM 语音 → usb_hid 发到 PC（USB UAC）
 *   BLE 连接状态 → 日志
 */
#include "app_fsm.h"
#include "app_events.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/task.h"
#include "esp_log.h"

#include "ble_central.h"
#include "usb_hid.h"

static const char *TAG = "fsm";

static void fsm_task(void *arg)
{
    QueueHandle_t q = (QueueHandle_t)arg;
    app_event_t ev;

    ESP_LOGI(TAG, "FSM 已启动");

    while (1) {
        if (xQueueReceive(q, &ev, portMAX_DELAY) != pdPASS) continue;

        switch (ev.type) {
        case EVT_HID_KEY_DOWN:
            usb_hid_send_key(ev.payload.hid.page, ev.payload.hid.usage, 1);
            break;

        case EVT_HID_KEY_UP:
            usb_hid_send_key(ev.payload.hid.page, ev.payload.hid.usage, 0);
            break;

        case EVT_PCM_AUDIO:
            usb_hid_send_audio(ev.payload.pcm.samples, ev.payload.pcm.count);
            break;

        case EVT_BLE_CONNECTED:
            ESP_LOGI(TAG, "遥控器已连接");
            break;

        case EVT_BLE_DISCONNECTED:
            ESP_LOGI(TAG, "遥控器已断开");
            break;

        case EVT_VOICE_START:
            ESP_LOGI(TAG, "🎤 语音开始");
            break;

        case EVT_VOICE_STOP:
            ESP_LOGI(TAG, "语音结束");
            break;
        }
    }
}

int app_fsm_start(void)
{
    QueueHandle_t q = app_event_queue_get();
    BaseType_t ok = xTaskCreate(fsm_task, "fsm", 4096, q, 5, NULL);
    return ok == pdPASS ? 0 : -1;
}
