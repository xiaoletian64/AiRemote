/**
 * main.c - remote_bridge 入口
 *
 * 启动顺序：
 *   1. 事件队列
 *   2. USB HID（对PC暴露成键盘+Consumer Control）
 *   3. BLE Central（扫描+连接小米遥控器，订阅 HID/ATVV）
 *   4. FSM 任务（消费事件，转发到 USB）
 */
#include <stdio.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "esp_log.h"

#include "app_events.h"
#include "app_fsm.h"
#include "ble_central.h"
#include "usb_hid.h"

static const char *TAG = "main";

void app_main(void)
{
    ESP_LOGI(TAG, "========================================");
    ESP_LOGI(TAG, "  remote_bridge 启动");
    ESP_LOGI(TAG, "  BLE Central: 小米蓝牙语音遥控器");
    ESP_LOGI(TAG, "  USB  Out    : HID 键盘+Consumer");
    ESP_LOGI(TAG, "========================================");

    app_event_queue_get();

    if (usb_hid_init() == 0) {
        ESP_LOGI(TAG, "USB HID 初始化完成（PC 可见）");
    } else {
        ESP_LOGW(TAG, "USB HID 初始化失败（继续，无USB模式）");
    }

    if (ble_central_init() == 0) {
        ESP_LOGI(TAG, "BLE Central 初始化完成");
        ble_central_start_scanning();
    } else {
        ESP_LOGE(TAG, "BLE Central 初始化失败");
    }

    if (app_fsm_start() != 0) {
        ESP_LOGE(TAG, "FSM 启动失败");
        return;
    }

    ESP_LOGI(TAG, "启动完成。等待遥控器配对...");
}
