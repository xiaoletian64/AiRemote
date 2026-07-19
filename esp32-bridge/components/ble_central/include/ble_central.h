/**
 * ble_central.h - BLE Central，连接小米蓝牙语音遥控器
 */
#pragma once
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

int ble_central_init(void);
int ble_central_start_scanning(void);
int ble_central_is_connected(void);
int ble_central_atvv_ready(void);

#ifdef __cplusplus
}
#endif
