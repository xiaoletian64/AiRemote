//! Windows Raw Input 旁路监听。
//!
//! Windows 会把 RC003 的键盘类 HID 独占，hidapi 因而无法 ReadFile。Raw Input
//! 仍然能收到系统分发的键盘报告；这里仅筛选小米 VID_2717 的 F5（HID usage
//! 0x3E，遥控器语音键），不会劫持电脑实体键盘。

#![cfg(windows)]

use std::ffi::c_void;
use std::mem::size_of;
use std::sync::{Arc, OnceLock};
use std::thread;
use windows::core::PCWSTR;
use windows::Win32::Foundation::{HANDLE, HINSTANCE, HWND, LPARAM, LRESULT, WPARAM};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::UI::Input::KeyboardAndMouse::VK_F5;
use windows::Win32::UI::Input::{
    GetRawInputData, GetRawInputDeviceInfoW, RegisterRawInputDevices, RAWINPUT, RAWINPUTDEVICE,
    RIDEV_INPUTSINK, RIDI_DEVICENAME, RID_INPUT,
};
use windows::Win32::UI::WindowsAndMessaging::{
    CreateWindowExW, DefWindowProcW, DispatchMessageW, GetMessageW, RegisterClassW,
    TranslateMessage, CS_HREDRAW, CS_VREDRAW, HWND_MESSAGE, MSG, WM_INPUT, WNDCLASSW,
    WS_OVERLAPPED,
};

type KeyCallback = Arc<dyn Fn(u16, bool) + Send + Sync + 'static>;
static CALLBACK: OnceLock<KeyCallback> = OnceLock::new();

pub struct RawInputListener {
    thread_handle: Option<thread::JoinHandle<()>>,
}

impl RawInputListener {
    pub fn start(callback: KeyCallback) -> Self {
        let thread_handle = thread::spawn(move || unsafe {
            let _ = CALLBACK.set(callback);
            let instance = GetModuleHandleW(None).unwrap_or_default();
            let class_name: Vec<u16> = "AiRemoteRawInput"
                .encode_utf16()
                .chain(std::iter::once(0))
                .collect();
            let class = WNDCLASSW {
                hInstance: HINSTANCE(instance.0),
                lpszClassName: PCWSTR(class_name.as_ptr()),
                lpfnWndProc: Some(window_proc),
                style: CS_HREDRAW | CS_VREDRAW,
                ..Default::default()
            };
            if RegisterClassW(&class) == 0 {
                return;
            }
            let hwnd = CreateWindowExW(
                Default::default(),
                PCWSTR(class_name.as_ptr()),
                PCWSTR(class_name.as_ptr()),
                WS_OVERLAPPED,
                0,
                0,
                0,
                0,
                HWND_MESSAGE,
                None,
                instance,
                None,
            );
            let Ok(hwnd) = hwnd else { return };
            let devices = [RAWINPUTDEVICE {
                usUsagePage: 0x01,
                usUsage: 0x06,
                dwFlags: RIDEV_INPUTSINK,
                hwndTarget: hwnd,
            }];
            if RegisterRawInputDevices(&devices, size_of::<RAWINPUTDEVICE>() as u32).is_err() {
                return;
            }
            let mut msg = MSG::default();
            while GetMessageW(&mut msg, None, 0, 0).as_bool() {
                TranslateMessage(&msg);
                DispatchMessageW(&msg);
            }
        });
        Self {
            thread_handle: Some(thread_handle),
        }
    }
}

impl Drop for RawInputListener {
    fn drop(&mut self) {
        // The listener is tied to the process lifetime. The thread exits with the
        // message loop when Windows tears down the hidden window.
        let _ = self.thread_handle.take();
    }
}

unsafe extern "system" fn window_proc(
    hwnd: HWND,
    msg: u32,
    wparam: WPARAM,
    lparam: LPARAM,
) -> LRESULT {
    if msg == WM_INPUT {
        handle_raw_input(lparam);
    }
    DefWindowProcW(hwnd, msg, wparam, lparam)
}

unsafe fn handle_raw_input(lparam: LPARAM) {
    let mut size = 0u32;
    if GetRawInputData(
        windows::Win32::UI::Input::HRAWINPUT(lparam.0 as _),
        RID_INPUT,
        None,
        &mut size,
        size_of::<windows::Win32::UI::Input::RAWINPUTHEADER>() as u32,
    ) == u32::MAX
        || size < size_of::<RAWINPUT>() as u32
    {
        return;
    }
    let mut bytes = vec![0u8; size as usize];
    if GetRawInputData(
        windows::Win32::UI::Input::HRAWINPUT(lparam.0 as _),
        RID_INPUT,
        Some(bytes.as_mut_ptr() as *mut c_void),
        &mut size,
        size_of::<windows::Win32::UI::Input::RAWINPUTHEADER>() as u32,
    ) == u32::MAX
    {
        return;
    }
    let raw = &*(bytes.as_ptr() as *const RAWINPUT);
    if raw.header.dwType != 1 || !is_xiaomi_device(raw.header.hDevice) {
        return;
    }
    let keyboard = raw.data.keyboard;
    if keyboard.VKey != VK_F5.0 {
        return;
    }
    let is_down = (keyboard.Flags & 1) == 0;
    if let Some(callback) = CALLBACK.get() {
        callback(0x3E, is_down);
    }
}

unsafe fn is_xiaomi_device(device: HANDLE) -> bool {
    let mut chars = 0u32;
    if GetRawInputDeviceInfoW(device, RIDI_DEVICENAME, None, &mut chars) == u32::MAX {
        return false;
    }
    let mut name = vec![0u16; chars as usize + 1];
    if GetRawInputDeviceInfoW(
        device,
        RIDI_DEVICENAME,
        Some(name.as_mut_ptr() as *mut c_void),
        &mut chars,
    ) == u32::MAX
    {
        return false;
    }
    String::from_utf16_lossy(&name[..chars as usize])
        .to_ascii_uppercase()
        .contains("VID_2717")
}
