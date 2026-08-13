use anyhow::Result;
use micflurry_control::KeyboardAction;

pub fn post(action: KeyboardAction) -> Result<()> {
    platform::post(action)
}

#[cfg(target_os = "macos")]
mod platform {
    use anyhow::{Result, anyhow};
    use core_graphics::event::{CGEvent, CGEventTapLocation};
    use core_graphics::event_source::{CGEventSource, CGEventSourceStateID};
    use micflurry_control::KeyboardAction;

    #[allow(unsafe_code)]
    pub fn post(action: KeyboardAction) -> Result<()> {
        let key_code = match action {
            KeyboardAction::Up => 0x7e,
            KeyboardAction::Down => 0x7d,
            KeyboardAction::Left | KeyboardAction::Previous => 0x7b,
            KeyboardAction::Right | KeyboardAction::Next => 0x7c,
            KeyboardAction::Select => 0x24, // Return
            KeyboardAction::Back => 0x35,   // Escape
            KeyboardAction::Home => 0x73,
            KeyboardAction::PlayPause => 0x31, // Space
            KeyboardAction::VolumeDown => 0x49,
            KeyboardAction::VolumeUp => 0x48,
            KeyboardAction::Mute => 0x4a,
        };
        // System-defined media keys use NX_SUBTYPE_AUX_CONTROL_BUTTONS rather than ordinary
        // keyboard scan codes. CGEventCreateKeyboardEvent covers the required keyboard actions
        // and prompts for Accessibility permission on first use.
        let source = CGEventSource::new(CGEventSourceStateID::HIDSystemState)
            .map_err(|()| anyhow!("create CGEvent source"))?;
        let down = CGEvent::new_keyboard_event(source.clone(), key_code, true)
            .map_err(|()| anyhow!("create key-down CGEvent"))?;
        let up = CGEvent::new_keyboard_event(source, key_code, false)
            .map_err(|()| anyhow!("create key-up CGEvent"))?;
        down.post(CGEventTapLocation::HID);
        up.post(CGEventTapLocation::HID);
        Ok(())
    }
}

#[cfg(not(target_os = "macos"))]
mod platform {
    use anyhow::{Result, bail};
    use micflurry_control::KeyboardAction;
    pub fn post(_action: KeyboardAction) -> Result<()> {
        bail!("CGEvent actions are only available on macOS")
    }
}
