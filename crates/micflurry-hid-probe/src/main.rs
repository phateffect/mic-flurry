//! Root-only development probe for exclusive RC003 IOHID capture.

#[cfg(target_os = "macos")]
#[allow(unsafe_code)]
mod macos {
    use anyhow::{Context, Result, bail, ensure};
    use core_foundation::{
        base::{CFRelease, CFType, CFTypeRef, TCFType, kCFAllocatorDefault},
        number::CFNumber,
        runloop::{CFRunLoop, kCFRunLoopDefaultMode},
        set::{CFSet, CFSetGetValues, CFSetRef},
        string::{CFString, CFStringRef},
    };
    use std::{
        collections::HashMap,
        env,
        ffi::c_void,
        fmt::Write as _,
        sync::atomic::{AtomicU64, Ordering},
        time::{Duration, Instant},
    };

    type IOHIDManagerRef = *mut c_void;
    type IOHIDDeviceRef = *mut c_void;
    type IOHIDElementRef = *mut c_void;
    type IOHIDValueRef = *mut c_void;
    type IOOptionBits = u32;
    type IOReturn = i32;
    type CFIndex = isize;
    type IOHIDReportType = u32;

    const NO_OPTIONS: IOOptionBits = 0;
    const SEIZE_DEVICE: IOOptionBits = 1;
    const IO_SUCCESS: IOReturn = 0;
    const RC003_MANUFACTURER: &str = "MIOM";
    const RC003_VENDOR_ID: u32 = 0x2717;
    const RC003_PRODUCT_ID: u32 = 0x32b8;
    const DEFAULT_DURATION_SECONDS: u64 = 30;
    const DEFAULT_REPORT_BUFFER_SIZE: usize = 512;
    const DEFAULT_REPORT_BUFFER_LENGTH: isize = 512;
    const HID_REQUEST_LISTEN_EVENT: u32 = 1;
    const HID_ACCESS_GRANTED: u32 = 0;
    const HID_ACCESS_DENIED: u32 = 1;
    const HID_ACCESS_UNKNOWN: u32 = 2;

    type IOHIDValueCallback = unsafe extern "C" fn(
        context: *mut c_void,
        result: IOReturn,
        sender: *mut c_void,
        value: IOHIDValueRef,
    );
    type IOHIDReportCallback = unsafe extern "C" fn(
        context: *mut c_void,
        result: IOReturn,
        sender: *mut c_void,
        report_type: IOHIDReportType,
        report_id: u32,
        report: *mut u8,
        report_length: CFIndex,
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
        fn IOHIDDeviceRegisterInputReportCallback(
            device: IOHIDDeviceRef,
            report: *mut u8,
            report_length: CFIndex,
            callback: Option<IOHIDReportCallback>,
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
        fn IOHIDCheckAccess(request_type: u32) -> u32;
        fn IOHIDRequestAccess(request_type: u32) -> bool;
        fn geteuid() -> u32;
    }

    struct CallbackContext {
        labels: HashMap<usize, String>,
        sequence: AtomicU64,
        started: Instant,
    }

    struct ProbeOptions {
        duration: Duration,
        request_access: bool,
    }

    impl ProbeOptions {
        fn parse() -> Result<Self> {
            let mut duration_seconds = DEFAULT_DURATION_SECONDS;
            let mut request_access = false;
            let mut arguments = env::args().skip(1);
            while let Some(argument) = arguments.next() {
                match argument.as_str() {
                    "--duration" => {
                        let value = arguments.next().context("--duration requires seconds")?;
                        duration_seconds = value
                            .parse::<u64>()
                            .with_context(|| format!("invalid --duration value: {value}"))?;
                        ensure!(duration_seconds > 0, "--duration must be greater than zero");
                    }
                    "--request-access" => request_access = true,
                    "-h" | "--help" => {
                        println!(
                            "Root-only RC003 IOHID seize probe\n\nUsage: micflurry-hid-probe [--duration SECONDS]\n       micflurry-hid-probe --request-access\n\n--request-access asks macOS for IOHID ListenEvent access without running the root probe.\n\nThe probe matches every MIOM 0x2717:0x32b8 IOHID interface, seizes all of them, and prints every raw input report and decoded HID value."
                        );
                        std::process::exit(0);
                    }
                    _ => bail!("unknown argument: {argument}"),
                }
            }
            Ok(Self {
                duration: Duration::from_secs(duration_seconds),
                request_access,
            })
        }
    }

    pub fn main() -> Result<()> {
        let options = ProbeOptions::parse()?;
        if options.request_access {
            request_listen_event_access();
            return Ok(());
        }
        // SAFETY: `geteuid` has no preconditions and only reads the current process credentials.
        ensure!(unsafe { geteuid() } == 0, "probe must run as root");
        run(&options)
    }

    fn run(options: &ProbeOptions) -> Result<()> {
        println!(
            "TCC ListenEvent={} (root process)",
            listen_event_access_name(check_listen_event_access())
        );
        // SAFETY: The manager is retained until every device and callback has been torn down.
        let manager = unsafe { IOHIDManagerCreate(kCFAllocatorDefault, NO_OPTIONS) };
        ensure!(!manager.is_null(), "IOHIDManagerCreate returned null");
        unsafe { IOHIDManagerSetDeviceMatching(manager, std::ptr::null()) };

        let Some((device_set, devices)) = find_rc003_devices(manager) else {
            // SAFETY: `manager` follows the create rule and is no longer used.
            unsafe { CFRelease(manager.cast()) };
            bail!(
                "no IOHID interfaces match {RC003_MANUFACTURER} {RC003_VENDOR_ID:04x}:{RC003_PRODUCT_ID:04x}"
            );
        };

        print_matches(&devices);
        let opened = match open_all(&devices) {
            Ok(opened) => opened,
            Err(error) => {
                drop(device_set);
                // SAFETY: No callbacks are registered and the manager is no longer used.
                unsafe { CFRelease(manager.cast()) };
                return Err(error);
            }
        };

        let labels = opened
            .iter()
            .enumerate()
            .map(|(index, &device)| (device as usize, format!("if{}", index + 1)))
            .collect();
        let mut context = Box::new(CallbackContext {
            labels,
            sequence: AtomicU64::new(0),
            started: Instant::now(),
        });
        let context_pointer = std::ptr::from_mut(context.as_mut()).cast();
        let run_loop = CFRunLoop::get_current();
        let report_buffers = register_callbacks(&opened, &run_loop, context_pointer);

        println!(
            "PROBE_READY seized_interfaces={} duration_s={} press every RC003 button now",
            opened.len(),
            options.duration.as_secs()
        );
        let deadline = Instant::now() + options.duration;
        while Instant::now() < deadline {
            CFRunLoop::run_in_mode(
                unsafe { kCFRunLoopDefaultMode },
                Duration::from_millis(100),
                false,
            );
        }

        unregister_callbacks(&opened, &run_loop);
        close_devices(&opened);
        println!(
            "PROBE_COMPLETE events={} released_interfaces={}",
            context.sequence.load(Ordering::Relaxed),
            opened.len()
        );

        drop(report_buffers);
        drop(context);
        drop(device_set);
        // SAFETY: All devices are closed and the manager is no longer used.
        unsafe { CFRelease(manager.cast()) };
        Ok(())
    }

    fn check_listen_event_access() -> u32 {
        // SAFETY: The documented access check has no pointer arguments or other preconditions.
        unsafe { IOHIDCheckAccess(HID_REQUEST_LISTEN_EVENT) }
    }

    fn request_listen_event_access() {
        let before = check_listen_event_access();
        // SAFETY: This documented call requests user consent for the current process.
        let granted = unsafe { IOHIDRequestAccess(HID_REQUEST_LISTEN_EVENT) };
        let after = check_listen_event_access();
        println!(
            "TCC_REQUEST ListenEvent before={} request_returned={} after={}",
            listen_event_access_name(before),
            granted,
            listen_event_access_name(after)
        );
    }

    fn listen_event_access_name(access: u32) -> &'static str {
        match access {
            HID_ACCESS_GRANTED => "granted",
            HID_ACCESS_DENIED => "denied",
            HID_ACCESS_UNKNOWN => "unknown",
            _ => "invalid",
        }
    }

    fn print_matches(devices: &[IOHIDDeviceRef]) {
        println!(
            "MATCH fingerprint={RC003_MANUFACTURER} VID:PID={RC003_VENDOR_ID:04x}:{RC003_PRODUCT_ID:04x} interfaces={}",
            devices.len()
        );
        for (index, &device) in devices.iter().enumerate() {
            println!("INTERFACE {} {}", index + 1, device_description(device));
        }
    }

    fn open_all(devices: &[IOHIDDeviceRef]) -> Result<Vec<IOHIDDeviceRef>> {
        let mut opened = Vec::with_capacity(devices.len());
        for &device in devices {
            // SAFETY: Every device comes from a retained IOHID manager device set.
            let result = unsafe { IOHIDDeviceOpen(device, SEIZE_DEVICE) };
            if result != IO_SUCCESS {
                close_devices(&opened);
                bail!(
                    "SEIZE_FAILED interface={} result=0x{:08x}",
                    device_description(device),
                    result.cast_unsigned()
                );
            }
            opened.push(device);
        }
        Ok(opened)
    }

    fn register_callbacks(
        devices: &[IOHIDDeviceRef],
        run_loop: &CFRunLoop,
        context: *mut c_void,
    ) -> Vec<Box<[u8]>> {
        let mut report_buffers = Vec::with_capacity(devices.len());
        for &device in devices {
            let report_size = number_property(device, "MaxInputReportSize")
                .and_then(|value| usize::try_from(value).ok())
                .filter(|&value| value > 0 && isize::try_from(value).is_ok())
                .unwrap_or(DEFAULT_REPORT_BUFFER_SIZE);
            let mut buffer = vec![0_u8; report_size].into_boxed_slice();
            let report_length =
                isize::try_from(buffer.len()).unwrap_or(DEFAULT_REPORT_BUFFER_LENGTH);
            unsafe {
                IOHIDDeviceRegisterInputValueCallback(device, Some(input_value_callback), context);
                IOHIDDeviceRegisterInputReportCallback(
                    device,
                    buffer.as_mut_ptr(),
                    report_length,
                    Some(input_report_callback),
                    context,
                );
                IOHIDDeviceScheduleWithRunLoop(
                    device,
                    run_loop.as_concrete_TypeRef().cast(),
                    kCFRunLoopDefaultMode,
                );
            }
            report_buffers.push(buffer);
        }
        report_buffers
    }

    fn unregister_callbacks(devices: &[IOHIDDeviceRef], run_loop: &CFRunLoop) {
        for &device in devices {
            unsafe {
                IOHIDDeviceUnscheduleFromRunLoop(
                    device,
                    run_loop.as_concrete_TypeRef().cast(),
                    kCFRunLoopDefaultMode,
                );
                IOHIDDeviceRegisterInputValueCallback(device, None, std::ptr::null_mut());
                IOHIDDeviceRegisterInputReportCallback(
                    device,
                    std::ptr::null_mut(),
                    0,
                    None,
                    std::ptr::null_mut(),
                );
            }
        }
    }

    fn find_rc003_devices(
        manager: IOHIDManagerRef,
    ) -> Option<(CFSet<*const c_void>, Vec<IOHIDDeviceRef>)> {
        // SAFETY: `manager` remains alive for the returned set's lifetime.
        let set_ref = unsafe { IOHIDManagerCopyDevices(manager) };
        if set_ref.is_null() {
            return None;
        }
        // SAFETY: The copy result follows the create rule.
        let set = unsafe { CFSet::<*const c_void>::wrap_under_create_rule(set_ref) };
        let mut values = vec![std::ptr::null(); set.len()];
        // SAFETY: `values` has room for every pointer in the set.
        unsafe { CFSetGetValues(set.as_concrete_TypeRef(), values.as_mut_ptr()) };
        let devices = values
            .into_iter()
            .map(<*const c_void>::cast_mut)
            .filter(|&device| {
                string_property(device, "Manufacturer").as_deref() == Some(RC003_MANUFACTURER)
                    && number_property(device, "VendorID") == Some(RC003_VENDOR_ID.into())
                    && number_property(device, "ProductID") == Some(RC003_PRODUCT_ID.into())
            })
            .collect::<Vec<_>>();
        (!devices.is_empty()).then_some((set, devices))
    }

    fn property(device: IOHIDDeviceRef, key: &str) -> Option<CFType> {
        let key = CFString::new(key);
        // SAFETY: `device` and the temporary CFString are valid for this call.
        let value = unsafe { IOHIDDeviceGetProperty(device, key.as_concrete_TypeRef()) };
        (!value.is_null()).then(|| unsafe { CFType::wrap_under_get_rule(value) })
    }

    fn string_property(device: IOHIDDeviceRef, key: &str) -> Option<String> {
        property(device, key)?
            .downcast::<CFString>()
            .map(|value| value.to_string())
    }

    fn number_property(device: IOHIDDeviceRef, key: &str) -> Option<i64> {
        property(device, key)?.downcast::<CFNumber>()?.to_i64()
    }

    fn device_description(device: IOHIDDeviceRef) -> String {
        let product = string_property(device, "Product").unwrap_or_else(|| "-".into());
        let physical_id =
            string_property(device, "PhysicalDeviceUniqueID").unwrap_or_else(|| "-".into());
        let location = number_property(device, "LocationID").unwrap_or_default();
        let usage_page = number_property(device, "PrimaryUsagePage").unwrap_or_default();
        let usage = number_property(device, "PrimaryUsage").unwrap_or_default();
        format!(
            "product={product:?} physical_id={physical_id} location=0x{location:x} primary=0x{usage_page:04x}/0x{usage:04x}"
        )
    }

    fn close_devices(devices: &[IOHIDDeviceRef]) {
        for &device in devices.iter().rev() {
            // SAFETY: Each device in this list was successfully opened by this process.
            let result = unsafe { IOHIDDeviceClose(device, NO_OPTIONS) };
            if result != IO_SUCCESS {
                eprintln!(
                    "RELEASE_FAILED interface={} result=0x{:08x}",
                    device_description(device),
                    result.cast_unsigned()
                );
            }
        }
    }

    unsafe extern "C" fn input_report_callback(
        context: *mut c_void,
        result: IOReturn,
        sender: *mut c_void,
        report_type: IOHIDReportType,
        report_id: u32,
        report: *mut u8,
        report_length: CFIndex,
    ) {
        if result != IO_SUCCESS
            || context.is_null()
            || report.is_null()
            || report_length.is_negative()
        {
            return;
        }
        let Ok(report_length) = usize::try_from(report_length) else {
            return;
        };
        let callback = unsafe { &*context.cast::<CallbackContext>() };
        let sequence = callback.sequence.fetch_add(1, Ordering::Relaxed) + 1;
        let label = callback
            .labels
            .get(&(sender as usize))
            .map_or("unknown", String::as_str);
        let bytes = unsafe { std::slice::from_raw_parts(report, report_length) };
        let mut hex = String::with_capacity(bytes.len().saturating_mul(3));
        for (index, byte) in bytes.iter().enumerate() {
            if index > 0 {
                hex.push(' ');
            }
            let _ = write!(hex, "{byte:02x}");
        }
        println!(
            "REPORT seq={sequence} t_ms={} interface={label} type={report_type} id=0x{report_id:02x} len={} data=[{hex}]",
            callback.started.elapsed().as_millis(),
            bytes.len()
        );
    }

    unsafe extern "C" fn input_value_callback(
        context: *mut c_void,
        result: IOReturn,
        sender: *mut c_void,
        value: IOHIDValueRef,
    ) {
        if result != IO_SUCCESS || context.is_null() || value.is_null() {
            return;
        }
        let element = unsafe { IOHIDValueGetElement(value) };
        if element.is_null() {
            return;
        }
        let callback = unsafe { &*context.cast::<CallbackContext>() };
        let sequence = callback.sequence.fetch_add(1, Ordering::Relaxed) + 1;
        let label = callback
            .labels
            .get(&(sender as usize))
            .map_or("unknown", String::as_str);
        let usage_page = unsafe { IOHIDElementGetUsagePage(element) };
        let usage = unsafe { IOHIDElementGetUsage(element) };
        let integer = unsafe { IOHIDValueGetIntegerValue(value) };
        println!(
            "VALUE seq={sequence} t_ms={} interface={label} usage=0x{usage_page:04x}/0x{usage:08x} value={integer}",
            callback.started.elapsed().as_millis()
        );
    }
}

#[cfg(target_os = "macos")]
fn main() -> anyhow::Result<()> {
    macos::main()
}

#[cfg(not(target_os = "macos"))]
fn main() {
    eprintln!("micflurry-hid-probe is only available on macOS");
    std::process::exit(1);
}
