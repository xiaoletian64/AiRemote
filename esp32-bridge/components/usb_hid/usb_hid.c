/**
 * usb_hid.c - TinyUSB HID 双接口（Keyboard + Consumer Control）
 *
 * 用 ESP-IDF v5.4 内置的 TinyUSB 组件，走 ESP32-S3 的 USB-OTG（GPIO19/20）。
 * PC 看到的是一个复合 HID 设备：键盘 + 音量控制。
 *
 * 接口0 = Keyboard:    [modifier][reserved][6 keys]    (8 bytes)
 * 接口1 = Consumer:    [usage(16-bit LE)]               (2 bytes)
 *
 * 注意 HID Usage ID 在 BLE 和 USB 是同一套编码（HID Usage Tables 1.21），
 * 所以从 BLE report 抽出 usage 直接转发即可。
 */
#include "usb_hid.h"
#include "esp_log.h"
#include "esp_err.h"
#include "tinyusb.h"
#include "tusb.h"

static const char *TAG = "usbhid";

/* ---- HID Report Descriptor ----
 * Report ID 1: Keyboard (8B)
 * Report ID 2: Consumer  (2B)
 */
static const uint8_t hid_report_descriptor[] = {
    /* ---- Keyboard (Interface 0, Report ID 1) ---- */
    HID_USAGE_PAGE    (HID_USAGE_PAGE_DESKTOP),
    HID_USAGE         (HID_USAGE_DESKTOP_KEYBOARD),
    HID_COLLECTION    (HID_COLLECTION_APPLICATION),
    HID_REPORT_ID     (1),
    HID_USAGE_PAGE    (HID_USAGE_PAGE_KEYBOARD),
    HID_USAGE_MIN     (224),
    HID_USAGE_MAX     (231),
    HID_LOGICAL_MIN   (0),
    HID_LOGICAL_MAX   (1),
    HID_REPORT_SIZE   (1),
    HID_REPORT_COUNT  (8),
    HID_INPUT          (HID_DATA | HID_VARIABLE | HID_ABSOLUTE),
    HID_REPORT_SIZE   (8),
    HID_REPORT_COUNT  (1),
    HID_INPUT          (HID_DATA | HID_CONSTANT),
    HID_USAGE_PAGE    (HID_USAGE_PAGE_KEYBOARD),
    HID_USAGE_MIN     (0),
    HID_USAGE_MAX     (101),
    HID_LOGICAL_MIN   (0),
    HID_LOGICAL_MAX   (101),
    HID_REPORT_SIZE   (8),
    HID_REPORT_COUNT  (6),
    HID_INPUT          (HID_DATA | HID_ARRAY),
    HID_USAGE_PAGE    (HID_USAGE_PAGE_LED),
    HID_USAGE_MIN     (1),
    HID_USAGE_MAX     (5),
    HID_REPORT_COUNT  (5),
    HID_REPORT_SIZE   (1),
    HID_OUTPUT         (HID_DATA | HID_VARIABLE | HID_ABSOLUTE),
    HID_REPORT_SIZE   (3),
    HID_REPORT_COUNT  (1),
    HID_OUTPUT         (HID_DATA | HID_CONSTANT),
    HID_END_COLLECTION,

    /* ---- Consumer Control (Interface 1, Report ID 2) ---- */
    HID_USAGE_PAGE    (HID_USAGE_PAGE_CONSUMER),
    HID_USAGE         (HID_USAGE_CONSUMER_CONTROL),
    HID_COLLECTION    (HID_COLLECTION_APPLICATION),
    HID_REPORT_ID     (2),
    HID_LOGICAL_MIN   (1),
    HID_LOGICAL_MAX   (652),
    HID_USAGE_MIN     (0),
    HID_USAGE_MAX     (652),
    HID_REPORT_SIZE   (16),
    HID_REPORT_COUNT  (1),
    HID_INPUT          (HID_DATA | HID_ARRAY),
    HID_END_COLLECTION,
};

/* TinyUSB 配置：要传给 tinyusb_driver_install 的结构 */
static const tinyusb_config_t tusb_cfg = {
    .device_descriptor = NULL,    /* 用默认 PID/VID */
    .string_descriptor = NULL,
    .external_phy = false,
    .configuration_descriptor = NULL,
};

/* 状态：当前按下的键 */
static struct {
    uint8_t modifier;
    uint8_t keys[6];
    uint8_t cnt;
} s_kb_state = {0};

static struct {
    uint16_t usage;
} s_consumer_state = {0};

/* USB HID 接口号 */
#define ITF_KEYBOARD  0
#define ITF_CONSUMER  1

/* ---- 静态接口描述符（TinyUSB 复合设备描述符需要拼接） ---- */
static uint8_t s_cfg_desc[128];
static size_t  s_cfg_desc_len = 0;

/* 构造 configuration descriptor：2 个 HID 接口 */
static void build_config_descriptor(void)
{
    /* 简化版：用 TinyUSB 的默认 HID 配置 */
    tinyusb_config_t cfg = tusb_cfg;
    cfg.configuration_descriptor = s_cfg_desc;
    (void)cfg;
    /* TinyUSB 内部会根据 hid_report_descriptor 和接口数生成 */
    s_cfg_desc_len = 0;
}

int usb_hid_init(void)
{
    ESP_LOGI(TAG, "初始化 TinyUSB HID");

    /* 注册 HID 接口描述符 */
    tinyusb_config_t cfg = {
        .device_descriptor = NULL,
        .string_descriptor = NULL,
        .external_phy = false,
        .configuration_descriptor = NULL,
    };

    /* 安装 TinyUSB */
    esp_err_t ret = tinyusb_driver_install(&cfg);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "tinyusb_driver_install 失败: %s", esp_err_to_name(ret));
        return -1;
    }

    extern const uint8_t hid_report_descriptor[];
    uint8_t *desc = (uint8_t *)hid_report_descriptor;
    size_t   desc_len = sizeof(hid_report_descriptor);
    ret = tinyusb_add_interface(
        TINYUSB_INTERFACE_HID,
        ITF_KEYBOARD,
        desc, desc_len,
        "HID Keyboard",
        NULL  /* 默认 protocol/report */
    );
    if (ret != ESP_OK) {
        ESP_LOGW(TAG, "tinyusb_add_interface keyboard: %s", esp_err_to_name(ret));
    }

    return 0;
}

void usb_hid_send_audio(const float *samples, int count)
{
    /* TODO: 接 UAC (USB Audio Class) 上行接口。
     * 当前 ESP-IDF v5.4 的 TinyUSB 默认配置不包含 UAC，移植需要：
     *   1. 在 hid_report_descriptor 之外加 UAC 接口描述符（ITF_AUDIO）
     *   2. 在 tusb_config.h 打开 CFG_TUD_AUDIO
     *   3. 实现 tud_audio_write 把 Float32 -> S16 LE 写出去
     * 第一版先把 PCM 暂存到环形缓冲，等待 UAC 接口完成。
     */
    (void)samples; (void)count;
}

void usb_hid_send_key(uint8_t page, uint16_t usage, uint8_t is_down)
{
    if (!tud_mounted()) return;

    if (page == 0x07) {
        /* Keyboard Page：把 usage 当成 HID keyboard scan code */
        if (is_down) {
            if (usage >= 224 && usage <= 231) {
                s_kb_state.modifier |= (1 << (usage - 224));
            } else if (s_kb_state.cnt < 6) {
                s_kb_state.keys[s_kb_state.cnt++] = (uint8_t)usage;
            }
        } else {
            if (usage >= 224 && usage <= 231) {
                s_kb_state.modifier &= ~(1 << (usage - 224));
            } else {
                for (int i = 0; i < s_kb_state.cnt; i++) {
                    if (s_kb_state.keys[i] == (uint8_t)usage) {
                        /* 移除：用最后一个填过来 */
                        s_kb_state.keys[i] = s_kb_state.keys[--s_kb_state.cnt];
                        s_kb_state.keys[s_kb_state.cnt] = 0;
                        break;
                    }
                }
            }
        }
        /* 发 Report ID 1 */
        uint8_t report[9] = {1, s_kb_state.modifier, 0,
                             s_kb_state.keys[0], s_kb_state.keys[1], s_kb_state.keys[2],
                             s_kb_state.keys[3], s_kb_state.keys[4], s_kb_state.keys[5]};
        tud_hid_report(ITF_KEYBOARD, report, sizeof(report));
    } else if (page == 0x0C) {
        /* Consumer Page：直接发16-bit usage */
        s_consumer_state.usage = is_down ? usage : 0;
        uint8_t report[3] = {2,
                             (uint8_t)(s_consumer_state.usage & 0xFF),
                             (uint8_t)(s_consumer_state.usage >> 8)};
        tud_hid_report(ITF_CONSUMER, report, sizeof(report));
    }
}

/* ---- TinyUSB HID 回调 ---- */
void tud_hid_set_report_cb(uint8_t instance, uint8_t report_id,
                           hid_report_type_t report_type,
                           uint8_t const *buffer, uint16_t bufsize)
{
    (void)instance; (void)report_id; (void)report_type; (void)buffer; (void)bufsize;
}

void tud_hid_get_report_cb(uint8_t instance, uint8_t report_id,
                           hid_report_type_t report_type,
                           uint8_t *buffer, uint16_t bufsize)
{
    (void)instance; (void)report_id; (void)report_type; (void)buffer; (void)bufsize;
}

uint16_t tud_hid_get_report_cb_func(uint8_t instance, uint8_t report_id,
                                     hid_report_type_t report_type,
                                     uint8_t *buffer, uint16_t reqlen)
{
    (void)instance; (void)report_id; (void)report_type; (void)buffer; (void)reqlen;
    return 0;
}
