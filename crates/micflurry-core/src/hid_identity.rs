//! Read-only macOS IOHID identity lookup for BLE peripherals already connected by the system.

use anyhow::Result;
use std::collections::HashMap;
use uuid::Uuid;

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct HidIdentity {
    pub manufacturer: Option<String>,
    pub product: Option<String>,
    pub vendor_id: Option<u32>,
    pub product_id: Option<u32>,
}

#[cfg(target_os = "macos")]
pub fn identities() -> Result<HashMap<Uuid, HidIdentity>> {
    macos::identities()
}

#[cfg(not(target_os = "macos"))]
pub fn identities() -> Result<HashMap<Uuid, HidIdentity>> {
    Ok(HashMap::new())
}

#[cfg(target_os = "macos")]
#[allow(unsafe_code)]
mod macos {
    use super::{HashMap, HidIdentity, Result, Uuid};
    use core_foundation::{
        base::{CFRelease, CFType, CFTypeRef, TCFType, kCFAllocatorDefault},
        number::CFNumber,
        set::{CFSet, CFSetGetValues, CFSetRef},
        string::{CFString, CFStringRef},
    };
    use std::ffi::c_void;

    type IOHIDManagerRef = *mut c_void;
    type IOHIDDeviceRef = *mut c_void;
    type IOOptionBits = u32;

    const NO_OPTIONS: IOOptionBits = 0;

    #[link(name = "IOKit", kind = "framework")]
    unsafe extern "C" {
        fn IOHIDManagerCreate(
            allocator: core_foundation::base::CFAllocatorRef,
            options: IOOptionBits,
        ) -> IOHIDManagerRef;
        fn IOHIDManagerSetDeviceMatching(manager: IOHIDManagerRef, matching: *const c_void);
        fn IOHIDManagerCopyDevices(manager: IOHIDManagerRef) -> CFSetRef;
        fn IOHIDDeviceGetProperty(device: IOHIDDeviceRef, key: CFStringRef) -> CFTypeRef;
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
}
