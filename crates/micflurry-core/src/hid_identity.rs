//! macOS IOHID identity lookup and input monitoring for the attached BLE remote.

use anyhow::Result;
use micflurry_control::{HidInput, KeyboardAction};
use std::collections::HashMap;
use tokio::sync::mpsc;
use uuid::Uuid;

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct HidIdentity {
    pub manufacturer: Option<String>,
    pub product: Option<String>,
    pub vendor_id: Option<u32>,
    pub product_id: Option<u32>,
    pub transport: Option<String>,
    pub serial_number: Option<String>,
    pub version_number: Option<u32>,
    pub physical_device_id: Option<String>,
}

#[cfg(target_os = "macos")]
pub fn identities() -> Result<HashMap<Uuid, HidIdentity>> {
    macos::identities()
}

#[cfg(not(target_os = "macos"))]
pub fn identities() -> Result<HashMap<Uuid, HidIdentity>> {
    Ok(HashMap::new())
}

pub struct HidMonitor {
    platform: platform::Monitor,
}

impl HidMonitor {
    pub async fn start(
        identifier: &str,
        seize: bool,
        sender: mpsc::Sender<HidInput>,
    ) -> Result<Self> {
        Ok(Self {
            platform: platform::Monitor::start(identifier, seize, sender).await?,
        })
    }

    pub async fn stop(&mut self) {
        self.platform.stop().await;
    }
}

#[must_use]
pub const fn keyboard_action(usage_page: u32, usage: u32) -> Option<KeyboardAction> {
    match (usage_page, usage) {
        (0x07, 0x28) | (0x0c, 0x41) => Some(KeyboardAction::Select),
        (0x07, 0x29 | 0xf1) | (0x0c, 0x46 | 0x224) => Some(KeyboardAction::Back),
        (0x07, 0x4a) | (0x0c, 0x223) => Some(KeyboardAction::Home),
        (0x07, 0x4f) | (0x0c, 0x45) => Some(KeyboardAction::Right),
        (0x07, 0x50) | (0x0c, 0x44) => Some(KeyboardAction::Left),
        (0x07, 0x51) | (0x0c, 0x43) => Some(KeyboardAction::Down),
        (0x07, 0x52) | (0x0c, 0x42) => Some(KeyboardAction::Up),
        (0x07, 0x2c) | (0x0c, 0xb0 | 0xb1 | 0xcd) => Some(KeyboardAction::PlayPause),
        (0x0c, 0xb5) => Some(KeyboardAction::Next),
        (0x0c, 0xb6) => Some(KeyboardAction::Previous),
        (0x07, 0x7f) | (0x0c, 0xe2) => Some(KeyboardAction::Mute),
        (0x07, 0x80) | (0x0c, 0xe9) => Some(KeyboardAction::VolumeUp),
        (0x07, 0x81) | (0x0c, 0xea) => Some(KeyboardAction::VolumeDown),
        _ => None,
    }
}

#[must_use]
const fn is_reportable_input(usage_page: u32, usage: u32, value: i64) -> bool {
    // macOS exposes both the concrete key element and the backing keyboard-array element. The
    // latter has no HID usage and carries a packed key code, so reporting it would duplicate every
    // physical press. An idle ErrorRollOver element is likewise report metadata rather than a key.
    usage != u32::MAX && !(usage_page == 0x07 && usage == 0x01 && value == 0)
}

#[must_use]
pub fn usage_name(usage_page: u32, usage: u32) -> String {
    let known = match (usage_page, usage) {
        (0x07, 0x28) => Some("keyboard enter"),
        (0x07, 0x29) => Some("keyboard escape"),
        (0x07, 0x2c) => Some("keyboard space"),
        (0x07, 0x35) => Some("keyboard grave"),
        (0x07, 0x3e) => Some("keyboard F5"),
        (0x07, 0x4a) => Some("keyboard home"),
        (0x07, 0x4f) => Some("keyboard right"),
        (0x07, 0x50) => Some("keyboard left"),
        (0x07, 0x51) => Some("keyboard down"),
        (0x07, 0x52) => Some("keyboard up"),
        (0x07, 0x65) => Some("keyboard application"),
        (0x07, 0x66) => Some("keyboard power"),
        (0x07, 0x7f) => Some("keyboard mute"),
        (0x07, 0x80) => Some("keyboard volume up"),
        (0x07, 0x81) => Some("keyboard volume down"),
        (0x07, 0xf1) => Some("remote back"),
        (0x0c, 0x41) => Some("consumer select"),
        (0x0c, 0x42) => Some("consumer up"),
        (0x0c, 0x43) => Some("consumer down"),
        (0x0c, 0x44) => Some("consumer left"),
        (0x0c, 0x45) => Some("consumer right"),
        (0x0c, 0x46 | 0x224) => Some("consumer back"),
        (0x0c, 0xb0) => Some("consumer play"),
        (0x0c, 0xb1) => Some("consumer pause"),
        (0x0c, 0xb5) => Some("consumer next track"),
        (0x0c, 0xb6) => Some("consumer previous track"),
        (0x0c, 0xcd) => Some("consumer play/pause"),
        (0x0c, 0xe2) => Some("consumer mute"),
        (0x0c, 0xe9) => Some("consumer volume up"),
        (0x0c, 0xea) => Some("consumer volume down"),
        (0x0c, 0x223) => Some("consumer home"),
        _ => None,
    };
    known.map_or_else(
        || format!("usage 0x{usage_page:04x}/0x{usage:04x}"),
        str::to_owned,
    )
}

#[cfg(target_os = "macos")]
#[allow(unsafe_code)]
mod macos {
    use super::{
        HashMap, HidIdentity, HidInput, Result, Uuid, is_reportable_input, keyboard_action, mpsc,
        usage_name,
    };
    use core_foundation::{
        base::{CFRelease, CFType, CFTypeRef, TCFType, kCFAllocatorDefault},
        number::CFNumber,
        runloop::{CFRunLoop, kCFRunLoopDefaultMode},
        set::{CFSet, CFSetGetValues, CFSetRef},
        string::{CFString, CFStringRef},
    };
    use std::{
        ffi::c_void,
        sync::{
            Arc,
            atomic::{AtomicBool, AtomicU64, Ordering},
        },
        thread::{self, JoinHandle},
        time::Duration,
    };

    type IOHIDManagerRef = *mut c_void;
    type IOHIDDeviceRef = *mut c_void;
    type IOHIDElementRef = *mut c_void;
    type IOHIDValueRef = *mut c_void;
    type IOOptionBits = u32;
    type IOReturn = i32;

    const NO_OPTIONS: IOOptionBits = 0;
    const SEIZE_DEVICE: IOOptionBits = 1;
    const IO_SUCCESS: IOReturn = 0;

    type IOHIDValueCallback = unsafe extern "C" fn(
        context: *mut c_void,
        result: IOReturn,
        sender: *mut c_void,
        value: IOHIDValueRef,
    );

    #[link(name = "IOKit", kind = "framework")]
    unsafe extern "C" {
        fn IOHIDManagerCreate(
            allocator: core_foundation::base::CFAllocatorRef,
            options: IOOptionBits,
        ) -> IOHIDManagerRef;
        fn IOHIDManagerSetDeviceMatching(manager: IOHIDManagerRef, matching: *const c_void);
        fn IOHIDManagerCopyDevices(manager: IOHIDManagerRef) -> CFSetRef;
        fn IOHIDDeviceGetProperty(device: IOHIDDeviceRef, key: CFStringRef) -> CFTypeRef;
        fn IOHIDDeviceOpen(device: IOHIDDeviceRef, options: IOOptionBits) -> IOReturn;
        fn IOHIDDeviceClose(device: IOHIDDeviceRef, options: IOOptionBits) -> IOReturn;
        fn IOHIDDeviceRegisterInputValueCallback(
            device: IOHIDDeviceRef,
            callback: Option<IOHIDValueCallback>,
            context: *mut c_void,
        );
        fn IOHIDDeviceScheduleWithRunLoop(
            device: IOHIDDeviceRef,
            run_loop: *mut c_void,
            mode: CFStringRef,
        );
        fn IOHIDDeviceUnscheduleFromRunLoop(
            device: IOHIDDeviceRef,
            run_loop: *mut c_void,
            mode: CFStringRef,
        );
        fn IOHIDValueGetElement(value: IOHIDValueRef) -> IOHIDElementRef;
        fn IOHIDValueGetIntegerValue(value: IOHIDValueRef) -> isize;
        fn IOHIDElementGetUsagePage(element: IOHIDElementRef) -> u32;
        fn IOHIDElementGetUsage(element: IOHIDElementRef) -> u32;
    }

    pub fn identities() -> Result<HashMap<Uuid, HidIdentity>> {
        // SAFETY: The manager is a Core Foundation object created with the documented IOHID API.
        let manager = unsafe { IOHIDManagerCreate(kCFAllocatorDefault, NO_OPTIONS) };
        anyhow::ensure!(!manager.is_null(), "IOHIDManagerCreate returned null");

        // A null match dictionary asks IOHIDManager to enumerate all HID devices.
        unsafe { IOHIDManagerSetDeviceMatching(manager, std::ptr::null()) };
        let result = collect(manager);
        // SAFETY: `manager` follows the create rule and is no longer used after this release.
        unsafe { CFRelease(manager.cast()) };
        Ok(result)
    }

    fn collect(manager: IOHIDManagerRef) -> HashMap<Uuid, HidIdentity> {
        // SAFETY: `manager` is valid for the duration of this read-only enumeration.
        let devices_ref = unsafe { IOHIDManagerCopyDevices(manager) };
        if devices_ref.is_null() {
            return HashMap::new();
        }
        // SAFETY: `devices_ref` is a valid CFSet returned under the create rule. Wrapping it here
        // ensures every exit path releases the set.
        let devices = unsafe { CFSet::<*const c_void>::wrap_under_create_rule(devices_ref) };
        let mut values = vec![std::ptr::null(); devices.len()];
        // SAFETY: `values` has capacity for exactly `CFSetGetCount` unretained pointers.
        unsafe { CFSetGetValues(devices.as_concrete_TypeRef(), values.as_mut_ptr()) };

        let mut result = HashMap::new();
        for value in values {
            let device = value.cast_mut();
            let Some(identifier) = string_property(device, "PhysicalDeviceUniqueID")
                .and_then(|value| Uuid::parse_str(&value).ok())
            else {
                continue;
            };
            result.insert(
                identifier,
                HidIdentity {
                    manufacturer: string_property(device, "Manufacturer"),
                    product: string_property(device, "Product"),
                    vendor_id: number_property(device, "VendorID"),
                    product_id: number_property(device, "ProductID"),
                    transport: string_property(device, "Transport"),
                    serial_number: string_property(device, "SerialNumber"),
                    version_number: number_property(device, "VersionNumber"),
                    physical_device_id: string_property(device, "PhysicalDeviceUniqueID"),
                },
            );
        }
        result
    }

    fn property(device: IOHIDDeviceRef, key: &str) -> Option<CFType> {
        let key = CFString::new(key);
        // SAFETY: Both references are valid for the call. IOHID owns the returned property.
        let value = unsafe { IOHIDDeviceGetProperty(device, key.as_concrete_TypeRef()) };
        if value.is_null() {
            None
        } else {
            // SAFETY: Get-rule wrapping retains the valid Core Foundation property.
            Some(unsafe { CFType::wrap_under_get_rule(value) })
        }
    }

    fn string_property(device: IOHIDDeviceRef, key: &str) -> Option<String> {
        property(device, key)?
            .downcast::<CFString>()
            .map(|value| value.to_string())
    }

    fn number_property(device: IOHIDDeviceRef, key: &str) -> Option<u32> {
        let value = property(device, key)?.downcast::<CFNumber>()?.to_i64()?;
        u32::try_from(value).ok()
    }

    pub struct Monitor {
        stop: Arc<AtomicBool>,
        thread: Option<JoinHandle<()>>,
    }

    impl Monitor {
        pub async fn start(
            identifier: &str,
            seize: bool,
            sender: mpsc::Sender<HidInput>,
        ) -> Result<Self> {
            let identifier = Uuid::parse_str(identifier)?;
            let stop = Arc::new(AtomicBool::new(false));
            let thread_stop = Arc::clone(&stop);
            let (startup_sender, startup_receiver) = tokio::sync::oneshot::channel();
            let thread = thread::Builder::new()
                .name("micflurry-iohid".into())
                .spawn(move || {
                    run_monitor(identifier, seize, sender, &thread_stop, startup_sender);
                })?;
            startup_receiver
                .await
                .map_err(|_| anyhow::anyhow!("IOHID monitor stopped during startup"))?
                .map_err(anyhow::Error::msg)?;
            Ok(Self {
                stop,
                thread: Some(thread),
            })
        }

        pub async fn stop(&mut self) {
            self.stop.store(true, Ordering::Release);
            if let Some(thread) = self.thread.take() {
                let _ = tokio::task::spawn_blocking(move || thread.join()).await;
            }
        }
    }

    impl Drop for Monitor {
        fn drop(&mut self) {
            self.stop.store(true, Ordering::Release);
        }
    }

    struct CallbackContext {
        sender: mpsc::Sender<HidInput>,
        sequence: AtomicU64,
    }

    fn run_monitor(
        identifier: Uuid,
        seize: bool,
        sender: mpsc::Sender<HidInput>,
        stop: &AtomicBool,
        startup: tokio::sync::oneshot::Sender<std::result::Result<(), String>>,
    ) {
        let result = prepare_monitor(identifier, seize, sender, stop, startup);
        if let Err(error) = result {
            tracing::error!(event = "hid_monitor_failed", error = %format!("{error:#}"), "IOHID monitor failed");
        }
    }

    fn prepare_monitor(
        identifier: Uuid,
        seize: bool,
        sender: mpsc::Sender<HidInput>,
        stop: &AtomicBool,
        startup: tokio::sync::oneshot::Sender<std::result::Result<(), String>>,
    ) -> Result<()> {
        // SAFETY: The manager and device are used only on this thread and released below.
        let manager = unsafe { IOHIDManagerCreate(kCFAllocatorDefault, NO_OPTIONS) };
        anyhow::ensure!(!manager.is_null(), "IOHIDManagerCreate returned null");
        // A null match dictionary enumerates all HID devices so the exact physical UUID can be
        // correlated with the CoreBluetooth peripheral.
        unsafe { IOHIDManagerSetDeviceMatching(manager, std::ptr::null()) };
        let Some((devices, matching_devices)) = find_devices(manager, identifier) else {
            unsafe { CFRelease(manager.cast()) };
            let message = format!("no IOHID device matches Bluetooth UUID {identifier}");
            let _ = startup.send(Err(message));
            return Ok(());
        };
        let options = if seize { SEIZE_DEVICE } else { NO_OPTIONS };
        let mut opened_devices = Vec::with_capacity(matching_devices.len());
        for device in matching_devices {
            let open_result = unsafe { IOHIDDeviceOpen(device, options) };
            if open_result != IO_SUCCESS {
                close_devices(&opened_devices);
                drop(devices);
                unsafe { CFRelease(manager.cast()) };
                let message = format!("IOHIDDeviceOpen failed with 0x{open_result:08x}");
                let _ = startup.send(Err(message));
                return Ok(());
            }
            opened_devices.push(device);
        }

        let mut context = Box::new(CallbackContext {
            sender,
            sequence: AtomicU64::new(0),
        });
        let context_pointer = std::ptr::from_mut(context.as_mut()).cast();
        let run_loop = CFRunLoop::get_current();
        for &device in &opened_devices {
            unsafe {
                IOHIDDeviceRegisterInputValueCallback(
                    device,
                    Some(input_value_callback),
                    context_pointer,
                );
                IOHIDDeviceScheduleWithRunLoop(
                    device,
                    run_loop.as_concrete_TypeRef().cast(),
                    kCFRunLoopDefaultMode,
                );
            }
        }
        if startup.send(Ok(())).is_err() {
            stop.store(true, Ordering::Release);
        }
        while !stop.load(Ordering::Acquire) {
            CFRunLoop::run_in_mode(
                unsafe { kCFRunLoopDefaultMode },
                Duration::from_millis(100),
                false,
            );
        }
        for &device in &opened_devices {
            unsafe {
                IOHIDDeviceRegisterInputValueCallback(device, None, std::ptr::null_mut());
                IOHIDDeviceUnscheduleFromRunLoop(
                    device,
                    run_loop.as_concrete_TypeRef().cast(),
                    kCFRunLoopDefaultMode,
                );
            }
        }
        close_devices(&opened_devices);
        drop(context);
        drop(devices);
        unsafe { CFRelease(manager.cast()) };
        Ok(())
    }

    fn find_devices(
        manager: IOHIDManagerRef,
        identifier: Uuid,
    ) -> Option<(CFSet<*const c_void>, Vec<IOHIDDeviceRef>)> {
        let devices_ref = unsafe { IOHIDManagerCopyDevices(manager) };
        if devices_ref.is_null() {
            return None;
        }
        let devices = unsafe { CFSet::<*const c_void>::wrap_under_create_rule(devices_ref) };
        let mut values = vec![std::ptr::null(); devices.len()];
        unsafe { CFSetGetValues(devices.as_concrete_TypeRef(), values.as_mut_ptr()) };
        let matching_devices = values
            .into_iter()
            .map(<*const c_void>::cast_mut)
            .filter(|device| {
                string_property(*device, "PhysicalDeviceUniqueID")
                    .and_then(|value| Uuid::parse_str(&value).ok())
                    == Some(identifier)
            })
            .collect::<Vec<_>>();
        (!matching_devices.is_empty()).then_some((devices, matching_devices))
    }

    fn close_devices(devices: &[IOHIDDeviceRef]) {
        for &device in devices {
            // Seizure is an open-time option. Closing with the documented default releases either
            // a shared or exclusive handle without carrying an opening policy into teardown.
            let close_result = unsafe { IOHIDDeviceClose(device, NO_OPTIONS) };
            if close_result != IO_SUCCESS {
                tracing::warn!(
                    event = "hid_close_failed",
                    result = close_result,
                    "could not close IOHID device cleanly"
                );
            }
        }
    }

    unsafe extern "C" fn input_value_callback(
        context: *mut c_void,
        result: IOReturn,
        _sender: *mut c_void,
        value: IOHIDValueRef,
    ) {
        if result != IO_SUCCESS || context.is_null() || value.is_null() {
            return;
        }
        let callback = unsafe { &*context.cast::<CallbackContext>() };
        let element = unsafe { IOHIDValueGetElement(value) };
        if element.is_null() {
            return;
        }
        let usage_page = unsafe { IOHIDElementGetUsagePage(element) };
        let usage = unsafe { IOHIDElementGetUsage(element) };
        let value = unsafe { IOHIDValueGetIntegerValue(value) } as i64;
        if !is_reportable_input(usage_page, usage, value) {
            return;
        }
        let sequence = callback.sequence.fetch_add(1, Ordering::Relaxed) + 1;
        let _ = callback.sender.try_send(HidInput {
            sequence,
            usage_page,
            usage,
            usage_name: usage_name(usage_page, usage),
            value,
            pressed: value != 0,
            mapped_action: keyboard_action(usage_page, usage),
        });
    }
}

#[cfg(target_os = "macos")]
mod platform {
    pub use super::macos::Monitor;
}

#[cfg(not(target_os = "macos"))]
mod platform {
    use super::{HidInput, Result, mpsc};

    pub struct Monitor;

    impl Monitor {
        pub async fn start(
            _identifier: &str,
            _seize: bool,
            _sender: mpsc::Sender<HidInput>,
        ) -> Result<Self> {
            anyhow::bail!("IOHID monitoring is only available on macOS")
        }

        pub async fn stop(&mut self) {}
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn maps_keyboard_and_consumer_remote_usages() {
        assert_eq!(keyboard_action(0x07, 0x52), Some(KeyboardAction::Up));
        assert_eq!(keyboard_action(0x07, 0x80), Some(KeyboardAction::VolumeUp));
        assert_eq!(keyboard_action(0x07, 0x4a), Some(KeyboardAction::Home));
        assert_eq!(keyboard_action(0x07, 0xf1), Some(KeyboardAction::Back));
        assert_eq!(keyboard_action(0x0c, 0xe9), Some(KeyboardAction::VolumeUp));
        assert_eq!(keyboard_action(0xff00, 1), None);
    }

    #[test]
    fn hides_keyboard_array_metadata_but_keeps_real_keys() {
        assert!(!is_reportable_input(0x07, u32::MAX, 5_373_952));
        assert!(!is_reportable_input(0x07, 0x01, 0));
        assert!(is_reportable_input(0x07, 0x52, 1));
        assert!(is_reportable_input(0x07, 0x52, 0));
    }
}
