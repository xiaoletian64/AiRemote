/**
 * usb_hid.h - USB 复合设备输出（PC 方向）
 *
 *   Interface 0: HID Keyboard
 *   Interface 1: HID Consumer Control
 *   Interface 2: UAC Audio Input (16kHz mono Float32)
 */
#pragma once
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

int usb_hid_init(void);

void usb_hid_send_key(uint8_t page, uint16_t usage, uint8_t is_down);

/* 把 PCM Float32 (-1.0~+1.0) 单声道 16kHz 帧转成 USB UAC 上行 */
void usb_hid_send_audio(const float *samples, int count);

#ifdef __cplusplus
}
#endif
