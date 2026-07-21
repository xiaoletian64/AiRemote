/**
 * ble_central.c - BLE Central / GATT Client
 *
 * 协议数据来源：mi-remote-mapper 项目（github.com/81199000/mi-remote-mapper）
 * 该项目在 macOS 上对小米蓝牙语音遥控器 2Pro 跑通了完整 ATVV+HID 通路，
 * 这里把它的协议信息搬到 ESP32 上。
 *
 * 实现要点：
 *   1. Bluedroid（实测对小米遥控器比 NimBLE 兼容更稳）
 *   2. 扫描：按 name 关键字 + 厂商 ID 0x2717 兜底
 *   3. 连接后并行发现两类服务：
 *      HID Service  (0x1812)
 *        └─ Report Char (0x2A4D) → CCCD 启用 notify
 *      ATVV Service (AB5E0001-5A21-4F05-BC7D-AF01F617B664)
 *        ├─ TX  Char (AB5E0002) ← ESP32 写命令（如握手 GET_CAPS）
 *        ├─ RX  Char (AB5E0003) → 遥控器音频流 notify（ADPCM 帧）
 *        └─ CTL Char (AB5E0004) → 遥控器语音键状态 notify
 *                                  0x04=按下 / 0x00=松开
 *   4. 在 RX 通道收到 ADPCM 帧时，调用 adpcm_decode 把帧解码成 PCM 后投递到事件队列
 *   5. 在 CTL 通道收到 0x04/0x00 时，分别 post EVT_VOICE_START/STOP
 *   6. 在 HID Report 通道收到 Input Report 时，按 Report ID 路由到键盘/Consumer
 *
 * 握手字节（关键）：
 *   GET_CAPS = [0x0A, 0x00, 0x06, 0x00, 0x01]
 *   写到 TX char，遥控器回应 caps，然后开始打音频流
 *
 * ADPCM 协议：IMA ADPCM, 16kHz mono, 低 nibble 在前
 *   每字节包含两个采样，需要保存 pred/idx 状态跨帧
 */
#include "ble_central.h"
#include <string.h>
#include <stdbool.h>
#include "esp_log.h"
#include "esp_bt.h"
#include "esp_bt_main.h"
#include "esp_gap_ble_api.h"
#include "esp_gattc_api.h"
#include "esp_bt_device.h"

#include "app_events.h"
#include "adpcm.h"
#include "voice_dsp.h"

static const char *TAG = "blec";

/* ---- 常量 ---- */
#define REMOTE_BT_APP_ID        0
#define BLE_SCAN_DURATION_S     30

/* GATT 句柄缓存上限 */
#define GATTC_DB_HANDLE_MAX     32

/* HID Service: 0x1812 */
#define UUID_HID_SERVICE        0x1812
#define UUID_HID_REPORT         0x2A4D
#define UUID_HID_CCCD            0x2902

/* 小米厂商 ID（出现在 manufacturer specific data 前两字节） */
#define XIAOMI_COMPANY_ID       0x2717

/* ---- ATVV UUID（128-bit, 反过来填字节） ----
 * Service: AB5E0001-5A21-4F05-BC7D-AF01F617B664
 * TX     : AB5E0002-...
 * RX     : AB5E0003-...
 * CTL    : AB5E0004-...
 * 注意：BLE 是 little-endian 字节序，UUID 字节按低位先填
 */
static const uint8_t ATVV_SVC_UUID[16] = {
    0x64, 0xB6, 0x17, 0xF6, 0x01, 0xAF, 0x7D, 0xBC,
    0x05, 0x4F, 0x21, 0x5A, 0x01, 0x00, 0x5E, 0xAB
};
static const uint8_t ATVV_TX_UUID[16]  = {
    0x64, 0xB6, 0x17, 0xF6, 0x01, 0xAF, 0x7D, 0xBC,
    0x05, 0x4F, 0x21, 0x5A, 0x02, 0x00, 0x5E, 0xAB
};
static const uint8_t ATVV_RX_UUID[16]  = {
    0x64, 0xB6, 0x17, 0xF6, 0x01, 0xAF, 0x7D, 0xBC,
    0x05, 0x4F, 0x21, 0x5A, 0x03, 0x00, 0x5E, 0xAB
};
static const uint8_t ATVV_CTL_UUID[16] = {
    0x64, 0xB6, 0x17, 0xF6, 0x01, 0xAF, 0x7D, 0xBC,
    0x05, 0x4F, 0x21, 0x5A, 0x04, 0x00, 0x5E, 0xAB
};

/* GET_CAPS 握手包：[len=0x0A][reserved=0x00][msg_id=0x06 GET_CAPS][codecs=0x00][version=0x01] */
static const uint8_t ATVV_GET_CAPS[] = { 0x0A, 0x00, 0x06, 0x00, 0x01 };

/* 语音键 HID Usage 0x3E = F5（macOS 系统听写键，但我们不需要拦截，直接放过去） */
#define HID_USAGE_VOICE         0x3E

/* ---- 状态 ---- */
static bool s_is_connected    = false;
static bool s_is_connecting   = false;
static esp_bd_addr_t s_remote_addr;
static uint16_t s_conn_id     = 0;
static uint16_t s_gattc_if    = 0;

/* 在已连接设备上记录我们关心的 char handle */
typedef struct {
    bool      valid;
    uint16_t  val_handle;     /* char value handle */
} hid_char_info_t;

/* HID Report char 多个（小米遥控器有 3 个 HID 接口：keyboard/consumer/vendor） */
static hid_char_info_t s_hid_chars[GATTC_DB_HANDLE_MAX];
static int             s_hid_char_cnt = 0;

/* ATVV 三个特征句柄 */
static uint16_t s_atvv_tx_handle  = 0;   /* 双向：可写 */
static uint16_t s_atvv_rx_handle  = 0;   /* 通知音频流 */
static uint16_t s_atvv_ctl_handle = 0;   /* 通知语音键状态 */

/* ATVV 握手状态 */
static bool s_atvv_caps_sent = false;
static bool s_atvv_handshake_ready = false;
static bool s_voice_btn_down = false;

/* ADPCM 解码器实例 */
static adpcm_state_t s_adpcm;
/* 语音 DSP 实例 */
static voice_dsp_t s_dsp;

/* ---- 工具：UUID 比较 ---- */
static bool uuid_eq_128(const uint8_t *a, const uint8_t *b)
{
    return memcmp(a, b, 16) == 0;
}
static bool uuid_eq_16(const esp_bt_uuid_t *u, uint16_t v16)
{
    return u->len == ESP_UUID_LEN_16 && u->uuid.uuid16 == v16;
}

/* ---- 名字过滤：识别小米遥控器 ---- */
static bool name_looks_like_xiaomi_remote(const char *name)
{
    if (!name) return false;
    if (strstr(name, "小米蓝牙"))    return true;
    if (strstr(name, "遥控"))         return true;
    if (strstr(name, "电视遥控"))     return true;
    if (strstr(name, "Mi Bluetooth")) return true;
    if (strstr(name, "Mi Voice"))     return true;
    if (strstr(name, "Mi Remote"))    return true;
    return false;
}

/* ---- HID Report 解析 ---- */
static void parse_hid_report(const uint8_t *data, int len)
{
    if (len < 1) return;

    /* 取 Report ID（第一字节） */
    uint8_t report_id = data[0];

    switch (report_id) {
    case 1: {  /* Keyboard: [id][mod][rsv][k0..k5] */
        if (len < 3) return;
        uint8_t modifier = data[1];
        const uint8_t *keys = data + 3;
        int key_cnt = (len - 3) > 6 ? 6 : (len - 3);

        static uint8_t prev_keys[6] = {0};
        static uint8_t prev_cnt = 0;
        static uint8_t prev_mod = 0;

        /* 新按下的 key → down 事件 */
        for (int i = 0; i < key_cnt; i++) {
            uint8_t k = keys[i];
            if (k == 0) continue;
            bool was_pressed = false;
            for (int j = 0; j < prev_cnt; j++) {
                if (prev_keys[j] == k) { was_pressed = true; break; }
            }
            if (!was_pressed) {
                app_event_post_key(0x07, k, 1);
            }
        }
        /* 抬起的 key → up 事件 */
        for (int j = 0; j < prev_cnt; j++) {
            uint8_t k = prev_keys[j];
            if (k == 0) continue;
            bool still = false;
            for (int i = 0; i < key_cnt; i++) {
                if (keys[i] == k) { still = true; break; }
            }
            if (!still) {
                app_event_post_key(0x07, k, 0);
            }
        }
        /* 修饰键 modifier (224-231) */
        for (int m = 224; m <= 231; m++) {
            uint8_t mask = (uint8_t)(1 << (m - 224));
            int now = (modifier & mask) ? 1 : 0;
            int old = (prev_mod & mask) ? 1 : 0;
            if (now != old) {
                app_event_post_key(0x07, m, now);
            }
        }
        prev_mod = modifier;

        /* 保存本帧 */
        memset(prev_keys, 0, sizeof(prev_keys));
        for (int i = 0; i < key_cnt; i++) prev_keys[i] = keys[i];
        prev_cnt = (uint8_t)key_cnt;
        break;
    }
    case 2: {  /* Consumer: [id][usage_lo][usage_hi] */
        if (len < 3) return;
        uint16_t usage = (uint16_t)(data[1] | (data[2] << 8));
        static uint16_t prev_csm = 0;
        if (usage != prev_csm) {
            if (prev_csm != 0) {
                app_event_post_key(0x0C, prev_csm, 0);
            }
            if (usage != 0) {
                app_event_post_key(0x0C, usage, 1);
            }
            prev_csm = usage;
        }
        break;
    }
    default:
        /* Vendor-specific Report（小米 0xFF00 接口）：跳过，不是按键 */
        break;
    }
}

/* ---- ATVV CTL 通道：语音键状态 ---- */
static void atvv_ctl_handle_value(const uint8_t *data, int len)
{
    if (len < 1) return;
    uint8_t cmd = data[0];
    ESP_LOGI(TAG, "[ATVV CTL] cmd=0x%02X", cmd);
    switch (cmd) {
    case 0x04:   /* 语音键按下 */
        if (!s_voice_btn_down) {
            s_voice_btn_down = true;
            adpcm_reset(&s_adpcm);
            voice_dsp_reset(&s_dsp);
            app_event_post_ble_state(2);   /* 用 2 表示语音开始 */
            ESP_LOGI(TAG, "🎤 语音键按下");
        }
        break;
    case 0x00:   /* 语音键松开 */
        if (s_voice_btn_down) {
            s_voice_btn_down = false;
            app_event_post_ble_state(3);   /* 用 3 表示语音结束 */
            ESP_LOGI(TAG, "语音键松开");
        }
        break;
    default:
        break;
    }
}

/* ---- ATVV RX 通道：音频帧 ---- */
static void atvv_rx_handle_value(const uint8_t *data, int len)
{
    if (!s_voice_btn_down) return;
    if (len <= 0) return;

    /* ADPCM 帧解码成 PCM Float (-1.0~+1.0) */
    float pcm[256];
    int   pcm_cnt = adpcm_decode(&s_adpcm, data, len, pcm, sizeof(pcm) / sizeof(pcm[0]));

    /* DSP 增强：高通+EQ+噪声门+AGC+软限幅 */
    voice_dsp_process(&s_dsp, pcm, pcm_cnt);

    /* 投到事件队列让 FSM 转 USB UAC */
    if (pcm_cnt > PCM_FRAME_MAX) pcm_cnt = PCM_FRAME_MAX;
    app_event_post_pcm(pcm, pcm_cnt);
}

/* ---- GAP 回调 ---- */
static void gap_event_handler(esp_gap_ble_cb_event_t event,
                              esp_ble_gap_cb_param_t *param)
{
    switch (event) {
    case ESP_GAP_BLE_SCAN_PARAM_SET_COMPLETE_EVT:
        esp_ble_gap_start_scanning(BLE_SCAN_DURATION_S);
        ESP_LOGI(TAG, "扫描已启动");
        break;

    case ESP_GAP_BLE_SCAN_RESULT_EVT: {
        esp_ble_gap_cb_param_t *r = param;
        if (r->scan_rst.search_evt != ESP_BLE_SEARCH_RESULT_EVT) break;
        if (s_is_connected || s_is_connecting) break;

        char name[64] = {0};
        uint8_t *adv = r->scan_rst.ble_adv;
        uint8_t  alen = r->scan_rst.adv_data_len;
        for (int i = 0; i + 1 < alen; ) {
            uint8_t l = adv[i];
            uint8_t t = adv[i + 1];
            if (l == 0 || i + l > alen) break;
            if (t == 0x09 || t == 0x08) {
                int cl = l - 1;
                if (cl > (int)sizeof(name) - 1) cl = (int)sizeof(name) - 1;
                memcpy(name, &adv[i + 2], cl);
                name[cl] = 0;
                break;
            }
            i += l + 1;
        }

        ESP_LOGI(TAG, "BLE: %s  %02x:%02x:%02x:%02x:%02x:%02x  rssi=%d",
                 name[0] ? name : "(无名)",
                 r->scan_rst.bda[0], r->scan_rst.bda[1], r->scan_rst.bda[2],
                 r->scan_rst.bda[3], r->scan_rst.bda[4], r->scan_rst.bda[5],
                 r->scan_rst.rssi);

        if (name_looks_like_xiaomi_remote(name)) {
            ESP_LOGI(TAG, "★ 找到小米遥控器 → 停扫，开始连接");
            memcpy(s_remote_addr, r->scan_rst.bda, 6);
            esp_ble_gap_stop_scanning();
            s_is_connecting = true;
            esp_ble_gattc_open(s_gattc_if, s_remote_addr, true);
        }
        break;
    }

    case ESP_GAP_BLE_SCAN_COMPLETE_EVT:
        ESP_LOGI(TAG, "扫描完成");
        s_is_connecting = false;
        break;

    case ESP_GAP_BLE_SEC_REQ_EVT:
        esp_ble_gap_security_rsp(param->sec_req.bd_addr, true);
        break;

    case ESP_GAP_BLE_PASSKEY_REQ_EVT:
        /* 多数 Mi Remote 走 Just Works，不会到这一分支 */
        esp_ble_passkey_reply(param->ble_security.key_req.bd_addr, true, 0);
        break;

    case ESP_GAP_BLE_AUTH_CMPL_EVT: {
        if (param->ble_security.auth_cmpl.success) {
            ESP_LOGI(TAG, "配对成功");
        } else {
            ESP_LOGE(TAG, "配对失败 err=%d", param->ble_security.auth_cmpl.fail_reason);
        }
        break;
    }

    default:
        break;
    }
}

/* ---- 服务发现后启用一个 char 的 notify ---- */
static void enable_notify(uint16_t val_handle)
{
    if (val_handle == 0) return;
    uint16_t cccd = (uint16_t)(val_handle + 1);   /* CCCD 通常紧跟 char value */
    uint16_t val = 0x0001;                         /* enable notify */
    esp_ble_gattc_write_char_descr(
        s_gattc_if, s_conn_id, cccd,
        sizeof(val), (uint8_t *)&val,
        ESP_GATT_WRITE_TYPE_RSP, ESP_AUTH_REQ_NONE);
}

/* ---- GATTC 回调 ---- */
static void gattc_event_handler(esp_gattc_cb_event_t event,
                                 esp_gatt_if_t gattc_if,
                                 esp_ble_gattc_cb_param_t *param)
{
    switch (event) {
    case ESP_GATTC_REG_EVT:
        s_gattc_if = gattc_if;
        ESP_LOGI(TAG, "GATTC 注册 if=%d", gattc_if);
        break;

    case ESP_GATTC_CONNECT_EVT:
        s_conn_id = param->connect.conn_id;
        ESP_LOGI(TAG, "已连接 conn_id=%d", s_conn_id);
        esp_ble_gattc_send_mtu(gattc_if, s_conn_id, 200);
        esp_ble_gattc_search_service(gattc_if, s_conn_id, NULL);
        break;

    case ESP_GATTC_OPEN_EVT:
        if (param->open.status != ESP_GATT_OK) {
            ESP_LOGE(TAG, "连接失败 status=%d", param->open.status);
            s_is_connecting = false;
            ble_central_start_scanning();
        }
        break;

    case ESP_GATTC_SEARCH_RES_EVT: {
        esp_bt_uuid_t *u = &param->search_res.srvc_id.uuid;

        /* HID Service 0x1812 */
        if (uuid_eq_16(u, UUID_HID_SERVICE)) {
            ESP_LOGI(TAG, "找到 HID Service (0x1812) start=%d end=%d",
                     param->search_res.start_handle, param->search_res.end_handle);
            esp_ble_gattc_get_characteristic(gattc_if, s_conn_id,
                                              &param->search_res.srvc_id,
                                              NULL);
            /* 把 service 范围也记下来，下面 GET_CHAR 时用 */
            s_atvv_caps_sent = s_atvv_caps_sent;   /* nop */
        }
        /* ATVV Service（128-bit） */
        else if (u->len == ESP_UUID_LEN_128 &&
                 uuid_eq_128(u->uuid.uuid128, ATVV_SVC_UUID)) {
            ESP_LOGI(TAG, "找到 ATVV Service (Start+end=%d..%d)",
                     param->search_res.start_handle, param->search_res.end_handle);
            esp_ble_gattc_get_characteristic(gattc_if, s_conn_id,
                                              &param->search_res.srvc_id,
                                              NULL);
        }
        break;
    }

    case ESP_GATTC_SEARCH_CMPL_EVT:
        ESP_LOGI(TAG, "服务搜索完成");
        /* 对每个 HID Report char 启用 notify */
        for (int i = 0; i < s_hid_char_cnt; i++) {
            enable_notify(s_hid_chars[i].val_handle);
        }
        /* 启用 ATVV RX / CTL 的 notify */
        enable_notify(s_atvv_rx_handle);
        enable_notify(s_atvv_ctl_handle);
        s_is_connected = true;
        s_is_connecting = false;
        app_event_post_ble_state(1);
        break;

    case ESP_GATTC_GET_CHAR_EVT: {
        if (param->get_char.status != ESP_GATT_OK) {
            /* 该 service 下 char 读完 */
            break;
        }
        esp_bt_uuid_t *u = &param->get_char.char_uuid;

        if (uuid_eq_16(u, UUID_HID_REPORT)) {
            if (s_hid_char_cnt < GATTC_DB_HANDLE_MAX) {
                s_hid_chars[s_hid_char_cnt].valid = true;
                s_hid_chars[s_hid_char_cnt].val_handle = param->get_char.handle_val;
                ESP_LOGI(TAG, "HID Report char handle=%d", param->get_char.handle_val);
                s_hid_char_cnt++;
            }
            /* 找下一个 */
            esp_ble_gattc_get_characteristic(gattc_if, s_conn_id,
                                              &param->get_char.srvc_id,
                                              &param->get_char.char_id);
        }
        else if (u->len == ESP_UUID_LEN_128) {
            if (uuid_eq_128(u->uuid.uuid128, ATVV_TX_UUID)) {
                s_atvv_tx_handle = param->get_char.handle_val;
                ESP_LOGI(TAG, "ATVV TX handle=%d", s_atvv_tx_handle);
                esp_ble_gattc_get_characteristic(gattc_if, s_conn_id,
                                                  &param->get_char.srvc_id,
                                                  &param->get_char.char_id);
            }
            else if (uuid_eq_128(u->uuid.uuid128, ATVV_RX_UUID)) {
                s_atvv_rx_handle = param->get_char.handle_val;
                ESP_LOGI(TAG, "ATVV RX handle=%d", s_atvv_rx_handle);
                esp_ble_gattc_get_characteristic(gattc_if, s_conn_id,
                                                  &param->get_char.srvc_id,
                                                  &param->get_char.char_id);
            }
            else if (uuid_eq_128(u->uuid.uuid128, ATVV_CTL_UUID)) {
                s_atvv_ctl_handle = param->get_char.handle_val;
                ESP_LOGI(TAG, "ATVV CTL handle=%d", s_atvv_ctl_handle);
                esp_ble_gattc_get_characteristic(gattc_if, s_conn_id,
                                                  &param->get_char.srvc_id,
                                                  &param->get_char.char_id);
            }
            else {
                esp_ble_gattc_get_characteristic(gattc_if, s_conn_id,
                                                  &param->get_char.srvc_id,
                                                  &param->get_char.char_id);
            }
        }
        else {
            esp_ble_gattc_get_characteristic(gattc_if, s_conn_id,
                                              &param->get_char.srvc_id,
                                              &param->get_char.char_id);
        }
        break;
    }

    case ESP_GATTC_NOTIFY_EVT: {
        uint16_t h = param->notify.handle;
        const uint8_t *v = param->notify.value;
        int vlen = param->notify.value_len;

        if (h == s_atvv_rx_handle) {
            atvv_rx_handle_value(v, vlen);
        }
        else if (h == s_atvv_ctl_handle) {
            atvv_ctl_handle_value(v, vlen);
            /* 第一次 CTL notify 到达 = 语音握手就绪 → 立即写 GET_CAPS */
            if (!s_atvv_caps_sent && s_atvv_tx_handle != 0) {
                esp_ble_gattc_write_char(
                    s_gattc_if, s_conn_id, s_atvv_tx_handle,
                    sizeof(ATVV_GET_CAPS), (uint8_t *)ATVV_GET_CAPS,
                    ESP_GATT_WRITE_TYPE_RSP, ESP_AUTH_REQ_NONE);
                s_atvv_caps_sent = true;
                s_atvv_handshake_ready = true;
                ESP_LOGI(TAG, "✓ ATVV 握手已发送 (GET_CAPS)");
            }
        }
        else {
            /* HID Report */
            parse_hid_report(v, vlen);
        }
        break;
    }

    case ESP_GATTC_DISCONNECT_EVT:
        ESP_LOGI(TAG, "断开");
        s_is_connected = false;
        s_is_connecting = false;
        s_atvv_caps_sent = false;
        s_atvv_handshake_ready = false;
        s_voice_btn_down = false;
        s_atvv_tx_handle = s_atvv_rx_handle = s_atvv_ctl_handle = 0;
        s_hid_char_cnt = 0;
        memset(s_hid_chars, 0, sizeof(s_hid_chars));
        app_event_post_ble_state(0);
        ble_central_start_scanning();
        break;

    default:
        break;
    }
}

/* ---- 对外接口 ---- */
int ble_central_init(void)
{
    ESP_ERROR_CHECK(esp_bt_controller_mem_release(ESP_BT_MODE_CLASSIC_BT));

    esp_bt_controller_config_t cfg = BT_CONTROLLER_INIT_CONFIG_DEFAULT();
    esp_err_t ret = esp_bt_controller_init(&cfg);
    if (ret) { ESP_LOGE(TAG, "controller init: %s", esp_err_to_name(ret)); return -1; }
    ret = esp_bt_controller_enable(ESP_BT_MODE_BLE);
    if (ret) { ESP_LOGE(TAG, "controller enable: %s", esp_err_to_name(ret)); return -1; }

    ret = esp_bluedroid_init();
    if (ret) { ESP_LOGE(TAG, "bluedroid init: %s", esp_err_to_name(ret)); return -1; }
    ret = esp_bluedroid_enable();
    if (ret) { ESP_LOGE(TAG, "bluedroid enable: %s", esp_err_to_name(ret)); return -1; }

    ret = esp_ble_gattc_register_callback(gattc_event_handler);
    if (ret) { ESP_LOGE(TAG, "gattc cb: %s", esp_err_to_name(ret)); return -1; }

    ret = esp_ble_gap_register_callback(gap_event_handler);
    if (ret) { ESP_LOGE(TAG, "gap cb: %s", esp_err_to_name(ret)); return -1; }

    ret = esp_ble_gattc_app_register(REMOTE_BT_APP_ID);
    if (ret) { ESP_LOGE(TAG, "gattc app register: %s", esp_err_to_name(ret)); return -1; }

    /* 配对：Just Works + SC + Bond */
    esp_ble_io_cap_t cap = ESP_IO_CAP_NONE;
    esp_ble_gap_set_security_param(ESP_BLE_SM_IO_CAP_MODE, &cap, sizeof(cap));
    uint8_t auth_req = ESP_LE_AUTH_REQ_SC_BOND;
    esp_ble_gap_set_security_param(ESP_BLE_SM_AUTHEN_REQ_MODE, &auth_req, sizeof(auth_req));

    /* 初始化解码器和 DSP */
    adpcm_reset(&s_adpcm);
    voice_dsp_reset(&s_dsp);

    return 0;
}

int ble_central_start_scanning(void)
{
    if (s_is_connected || s_is_connecting) return 0;

    esp_ble_scan_params_t params = {
        .scan_type          = BLE_SCAN_TYPE_ACTIVE,
        .own_addr_type      = BLE_ADDR_TYPE_PUBLIC,
        .scan_filter_policy = BLE_SCAN_FILTER_ALLOW_ALL,
        .scan_interval      = 0x50,
        .scan_window        = 0x30,
        .scan_duplicate     = BLE_SCAN_DUPLICATE_DISABLE,
    };
    esp_err_t ret = esp_ble_gap_set_scan_params(&params);
    if (ret) { ESP_LOGE(TAG, "set_scan_params: %s", esp_err_to_name(ret)); return -1; }
    return 0;
}

int ble_central_is_connected(void)
{
    return s_is_connected ? 1 : 0;
}

int ble_central_atvv_ready(void)
{
    return s_atvv_handshake_ready ? 1 : 0;
}
