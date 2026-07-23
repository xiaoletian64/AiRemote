/// 语音键支持的 Windows 热键模式。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum VoiceKeyMode {
    WinH,
    LeftCtrl,
    LeftWin,
    CtrlWin,
    WinShift,
    CtrlShift,
    AltShift,
    MicToggle,
}

/// 可测试的低层修饰键事件序列。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum VoiceKeyEvent {
    ControlDown,
    ControlUp,
    MetaDown,
    MetaUp,
    ShiftDown,
    ShiftUp,
    AltDown,
    AltUp,
    HDown,
    HUp,
}

/// 语音键按下/松开所对应的完整键盘事件序列。
/// Ctrl+Win 是合法的两修饰键热键：第二个修饰键按下即可被目标程序捕获，
/// 松开时必须反序释放，避免把 Ctrl 或 Win 遗留在系统中。
pub fn events(mode: VoiceKeyMode, is_down: bool) -> Vec<VoiceKeyEvent> {
    use VoiceKeyEvent::*;
    use VoiceKeyMode::*;
    match (mode, is_down) {
        (WinH, true) => vec![MetaDown, HDown, HUp, MetaUp],
        (LeftCtrl, true) => vec![ControlDown],
        (LeftCtrl, false) => vec![ControlUp],
        (LeftWin, true) => vec![MetaDown],
        (LeftWin, false) => vec![MetaUp],
        (CtrlWin, true) => vec![ControlDown, MetaDown],
        (CtrlWin, false) => vec![MetaUp, ControlUp],
        (WinShift, true) => vec![MetaDown, ShiftDown],
        (WinShift, false) => vec![ShiftUp, MetaUp],
        (CtrlShift, true) => vec![ControlDown, ShiftDown],
        (CtrlShift, false) => vec![ShiftUp, ControlUp],
        (AltShift, true) => vec![AltDown, ShiftDown, ShiftUp, AltUp],
        _ => vec![],
    }
}

#[cfg(test)]
mod tests {
    use super::{events, VoiceKeyEvent, VoiceKeyMode};

    #[test]
    fn ctrl_win_mode_emits_both_modifier_down_events() {
        assert_eq!(
            events(VoiceKeyMode::CtrlWin, true),
            vec![VoiceKeyEvent::ControlDown, VoiceKeyEvent::MetaDown]
        );
    }

    #[test]
    fn ctrl_win_mode_releases_both_modifiers_in_reverse_order() {
        assert_eq!(
            events(VoiceKeyMode::CtrlWin, false),
            vec![VoiceKeyEvent::MetaUp, VoiceKeyEvent::ControlUp]
        );
    }
}
