#[cfg(not(target_os = "linux"))]
fn main() {
    eprintln!("ds4-bt-usb-probe is Linux-only because it talks to /dev/uhid.");
    std::process::exit(1);
}

#[cfg(target_os = "linux")]
fn main() {
    if let Err(err) = linux::run() {
        eprintln!("error: {err}");
        std::process::exit(1);
    }
}

#[cfg(target_os = "linux")]
mod linux {
    use std::env;
    use std::error::Error;
    use std::ffi::c_int;
    use std::fs::{self, File, OpenOptions};
    use std::io::{self, Read, Write};
    use std::path::{Path, PathBuf};
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::thread;
    use std::time::{Duration, Instant};

    type AnyError = Box<dyn Error + Send + Sync + 'static>;

    const HID_MAX_DESCRIPTOR_SIZE: usize = 4096;
    const UHID_DATA_MAX: usize = 4096;
    const EVENT_TYPE_LEN: usize = 4;
    const CREATE2_LEN: usize = 128 + 64 + 64 + 2 + 2 + 4 + 4 + 4 + 4 + HID_MAX_DESCRIPTOR_SIZE;
    const CREATE2_RD_OFFSET: usize = 128 + 64 + 64 + 2 + 2 + 4 + 4 + 4 + 4;

    const BUS_USB: u16 = 0x0003;

    const UHID_DESTROY: u32 = 1;
    const UHID_START: u32 = 2;
    const UHID_STOP: u32 = 3;
    const UHID_OPEN: u32 = 4;
    const UHID_CLOSE: u32 = 5;
    const UHID_OUTPUT: u32 = 6;
    const UHID_GET_REPORT: u32 = 9;
    const UHID_GET_REPORT_REPLY: u32 = 10;
    const UHID_CREATE2: u32 = 11;
    const UHID_INPUT2: u32 = 12;
    const UHID_SET_REPORT: u32 = 13;
    const UHID_SET_REPORT_REPLY: u32 = 14;

    const EIO: u16 = 5;
    const SIGINT: c_int = 2;
    const SIGTERM: c_int = 15;

    static RUNNING: AtomicBool = AtomicBool::new(true);

    extern "C" {
        fn signal(signum: c_int, handler: extern "C" fn(c_int)) -> usize;
    }

    extern "C" fn handle_shutdown_signal(_signum: c_int) {
        RUNNING.store(false, Ordering::Relaxed);
    }

    #[derive(Debug)]
    struct Config {
        descriptor: Option<PathBuf>,
        name: Option<String>,
        version: Option<u32>,
        vid: u32,
        pid: u32,
        interval_ms: u64,
        capture_root: PathBuf,
    }

    #[derive(Debug, Default)]
    struct CaptureDefaults {
        name: Option<String>,
        version: Option<u32>,
    }

    #[derive(Debug)]
    struct DescriptorChoice {
        bytes: Vec<u8>,
        label: String,
        is_fallback: bool,
    }

    struct UhidDevice {
        file: File,
        created: bool,
    }

    pub fn run() -> Result<(), AnyError> {
        let Some(config) = Config::parse(env::args().skip(1))? else {
            print_help();
            return Ok(());
        };

        install_signal_handlers();

        let capture_defaults = read_capture_defaults(&config.capture_root);
        let descriptor = choose_descriptor(&config)?;
        let name = config
            .name
            .clone()
            .or(capture_defaults.name)
            .unwrap_or_else(|| "Wireless Controller".to_string());
        let version = config.version.or(capture_defaults.version).unwrap_or(0x0100);

        println!("[probe] opening /dev/uhid");
        let mut device = UhidDevice::open().map_err(|err| {
            io::Error::new(
                err.kind(),
                format!("could not open /dev/uhid: {err}. Try running with sudo and make sure the uhid kernel module is available"),
            )
        })?;
        println!("[probe] /dev/uhid opened");

        spawn_event_reader(device.file.try_clone()?);

        if descriptor.is_fallback {
            println!("[probe] WARNING: using built-in fallback DS4-like USB descriptor");
            println!("[probe] WARNING: captured USB report_descriptor.bin from the real controller is strongly preferred");
        }

        println!("[probe] descriptor source: {}", descriptor.label);
        println!("[probe] descriptor length: {} bytes", descriptor.bytes.len());
        println!(
            "[probe] virtual identity: bus=USB/0x{BUS_USB:04x} vid=0x{:04x} pid=0x{:04x} version=0x{version:04x} name=\"{name}\"",
            config.vid, config.pid
        );

        device.create(&name, config.vid, config.pid, version, &descriptor.bytes)?;
        println!("[probe] UHID_CREATE2 sent");

        thread::sleep(Duration::from_millis(800));
        discover_virtual_devices(config.vid, config.pid);

        let report = neutral_usb_ds4_report();
        println!(
            "[probe] sending neutral USB-style DS4 input reports: report_id=0x{:02x} len={} interval={}ms",
            report[0],
            report.len(),
            config.interval_ms
        );
        println!("[probe] leave this running while Steam/Diablo IV is tested; press Ctrl+C to stop");

        let interval = Duration::from_millis(config.interval_ms.max(1));
        let mut sent: u64 = 0;
        let mut last_status = Instant::now();

        while RUNNING.load(Ordering::Relaxed) {
            device.send_input_report(&report)?;
            sent += 1;

            if last_status.elapsed() >= Duration::from_secs(5) {
                println!("[probe] sent {sent} neutral reports");
                last_status = Instant::now();
            }

            thread::sleep(interval);
        }

        println!("[probe] stopping after Ctrl+C/SIGTERM; sending UHID_DESTROY");
        device.destroy()?;
        println!("[probe] stopped");
        Ok(())
    }

    impl Config {
        fn parse<I>(args: I) -> Result<Option<Self>, AnyError>
        where
            I: IntoIterator<Item = String>,
        {
            let mut config = Self {
                descriptor: None,
                name: None,
                version: None,
                vid: 0x054c,
                pid: 0x09cc,
                interval_ms: 8,
                capture_root: PathBuf::from("captures"),
            };

            let mut args = args.into_iter().peekable();
            while let Some(arg) = args.next() {
                if arg == "-h" || arg == "--help" {
                    return Ok(None);
                }

                let (key, inline_value) = match arg.split_once('=') {
                    Some((key, value)) => (key.to_string(), Some(value.to_string())),
                    None => (arg, None),
                };

                match key.as_str() {
                    "--descriptor" => {
                        config.descriptor = Some(PathBuf::from(value_for(
                            &mut args,
                            inline_value,
                            "--descriptor",
                        )?));
                    }
                    "--name" => {
                        config.name = Some(value_for(&mut args, inline_value, "--name")?);
                    }
                    "--version" => {
                        config.version = Some(parse_hex_or_dec(&value_for(
                            &mut args,
                            inline_value,
                            "--version",
                        )?)?);
                    }
                    "--vid" => {
                        config.vid =
                            parse_hex_or_dec(&value_for(&mut args, inline_value, "--vid")?)?;
                    }
                    "--pid" => {
                        config.pid =
                            parse_hex_or_dec(&value_for(&mut args, inline_value, "--pid")?)?;
                    }
                    "--interval-ms" => {
                        let value = value_for(&mut args, inline_value, "--interval-ms")?;
                        config.interval_ms = value.parse::<u64>().map_err(|err| {
                            io::Error::other(format!("invalid --interval-ms value {value:?}: {err}"))
                        })?;
                    }
                    "--capture-root" => {
                        config.capture_root = PathBuf::from(value_for(
                            &mut args,
                            inline_value,
                            "--capture-root",
                        )?);
                    }
                    _ => {
                        return Err(
                            io::Error::other(format!("unknown argument {key:?}; use --help"))
                                .into(),
                        );
                    }
                }
            }

            Ok(Some(config))
        }
    }

    impl UhidDevice {
        fn open() -> io::Result<Self> {
            let file = OpenOptions::new().read(true).write(true).open("/dev/uhid")?;
            Ok(Self {
                file,
                created: false,
            })
        }

        fn create(
            &mut self,
            name: &str,
            vid: u32,
            pid: u32,
            version: u32,
            descriptor: &[u8],
        ) -> io::Result<()> {
            if descriptor.is_empty() {
                return Err(io::Error::other("HID report descriptor is empty"));
            }
            if descriptor.len() > HID_MAX_DESCRIPTOR_SIZE {
                return Err(io::Error::other(format!(
                    "HID report descriptor is {} bytes; max supported by UHID is {HID_MAX_DESCRIPTOR_SIZE}",
                    descriptor.len()
                )));
            }

            let mut event = vec![0_u8; EVENT_TYPE_LEN + CREATE2_LEN];
            write_u32(&mut event, 0, UHID_CREATE2);

            let payload = EVENT_TYPE_LEN;
            write_fixed_cstr(&mut event[payload..payload + 128], name);
            write_fixed_cstr(
                &mut event[payload + 128..payload + 128 + 64],
                "usb-ds4-bt-usb-probe",
            );
            write_fixed_cstr(
                &mut event[payload + 128 + 64..payload + 128 + 64 + 64],
                "ds4-bt-usb-probe",
            );

            write_u16(&mut event, payload + 256, descriptor.len() as u16);
            write_u16(&mut event, payload + 258, BUS_USB);
            write_u32(&mut event, payload + 260, vid);
            write_u32(&mut event, payload + 264, pid);
            write_u32(&mut event, payload + 268, version);
            write_u32(&mut event, payload + 272, 0);
            event[payload + CREATE2_RD_OFFSET..payload + CREATE2_RD_OFFSET + descriptor.len()]
                .copy_from_slice(descriptor);

            write_uhid_event(&mut self.file, &event)?;
            self.created = true;
            Ok(())
        }

        fn send_input_report(&mut self, report: &[u8]) -> io::Result<()> {
            if report.len() > UHID_DATA_MAX {
                return Err(io::Error::other(format!(
                    "input report is {} bytes; max supported by UHID is {UHID_DATA_MAX}",
                    report.len()
                )));
            }

            let mut event = vec![0_u8; EVENT_TYPE_LEN + 2 + report.len()];
            write_u32(&mut event, 0, UHID_INPUT2);
            write_u16(&mut event, EVENT_TYPE_LEN, report.len() as u16);
            event[EVENT_TYPE_LEN + 2..].copy_from_slice(report);
            write_uhid_event(&mut self.file, &event)
        }

        fn destroy(&mut self) -> io::Result<()> {
            if !self.created {
                return Ok(());
            }
            let mut event = [0_u8; EVENT_TYPE_LEN];
            write_u32(&mut event, 0, UHID_DESTROY);
            write_uhid_event(&mut self.file, &event)?;
            self.created = false;
            Ok(())
        }
    }

    impl Drop for UhidDevice {
        fn drop(&mut self) {
            let _ = self.destroy();
        }
    }

    fn install_signal_handlers() {
        // SAFETY: registering a simple C signal handler. The handler only flips an AtomicBool.
        unsafe {
            let _ = signal(SIGINT, handle_shutdown_signal);
            let _ = signal(SIGTERM, handle_shutdown_signal);
        }
    }

    fn spawn_event_reader(mut file: File) {
        thread::spawn(move || {
            let mut event = vec![0_u8; EVENT_TYPE_LEN + CREATE2_LEN];
            loop {
                event.fill(0);
                match file.read(&mut event) {
                    Ok(0) => {
                        println!("[uhid] read EOF");
                        break;
                    }
                    Ok(n) if n < EVENT_TYPE_LEN => {
                        println!("[uhid] short event read: {n} bytes");
                    }
                    Ok(n) => handle_uhid_event(&mut file, &event, n),
                    Err(err) if err.kind() == io::ErrorKind::Interrupted => {}
                    Err(err) => {
                        println!("[uhid] read error: {err}");
                        break;
                    }
                }
            }
        });
    }

    fn handle_uhid_event(file: &mut File, event: &[u8], bytes_read: usize) {
        let Some(event_type) = read_u32(event, 0) else {
            println!("[uhid] malformed event with {bytes_read} bytes");
            return;
        };

        match event_type {
            UHID_START => {
                let flags = read_u64(event, EVENT_TYPE_LEN).unwrap_or(0);
                println!("[uhid] event UHID_START dev_flags=0x{flags:016x}");
            }
            UHID_STOP => println!("[uhid] event UHID_STOP"),
            UHID_OPEN => println!("[uhid] event UHID_OPEN"),
            UHID_CLOSE => println!("[uhid] event UHID_CLOSE"),
            UHID_OUTPUT => {
                let size = read_u16(event, EVENT_TYPE_LEN + UHID_DATA_MAX).unwrap_or(0);
                let report_type = event
                    .get(EVENT_TYPE_LEN + UHID_DATA_MAX + 2)
                    .copied()
                    .unwrap_or(0);
                let first_byte = event.get(EVENT_TYPE_LEN).copied().unwrap_or(0);
                println!(
                    "[uhid] event UHID_OUTPUT bytes_read={bytes_read} size={size} rtype={report_type} first_byte=0x{first_byte:02x}"
                );
            }
            UHID_GET_REPORT => {
                let id = read_u32(event, EVENT_TYPE_LEN).unwrap_or(0);
                let report_number = event.get(EVENT_TYPE_LEN + 4).copied().unwrap_or(0);
                let report_type = event.get(EVENT_TYPE_LEN + 5).copied().unwrap_or(0);
                println!(
                    "[uhid] event UHID_GET_REPORT id={id} rnum=0x{report_number:02x} rtype={report_type}; replying EIO"
                );
                if let Err(err) = send_get_report_reply(file, id, EIO) {
                    println!("[uhid] failed to send UHID_GET_REPORT_REPLY: {err}");
                }
            }
            UHID_SET_REPORT => {
                let id = read_u32(event, EVENT_TYPE_LEN).unwrap_or(0);
                let report_number = event.get(EVENT_TYPE_LEN + 4).copied().unwrap_or(0);
                let report_type = event.get(EVENT_TYPE_LEN + 5).copied().unwrap_or(0);
                let size = read_u16(event, EVENT_TYPE_LEN + 6).unwrap_or(0);
                println!(
                    "[uhid] event UHID_SET_REPORT id={id} rnum=0x{report_number:02x} rtype={report_type} size={size}; replying EIO"
                );
                if let Err(err) = send_set_report_reply(file, id, EIO) {
                    println!("[uhid] failed to send UHID_SET_REPORT_REPLY: {err}");
                }
            }
            other => println!("[uhid] event type {other} bytes_read={bytes_read}"),
        }
    }

    fn send_get_report_reply(file: &mut File, id: u32, err: u16) -> io::Result<()> {
        let mut event = [0_u8; EVENT_TYPE_LEN + 8];
        write_u32(&mut event, 0, UHID_GET_REPORT_REPLY);
        write_u32(&mut event, EVENT_TYPE_LEN, id);
        write_u16(&mut event, EVENT_TYPE_LEN + 4, err);
        write_u16(&mut event, EVENT_TYPE_LEN + 6, 0);
        write_uhid_event(file, &event)
    }

    fn send_set_report_reply(file: &mut File, id: u32, err: u16) -> io::Result<()> {
        let mut event = [0_u8; EVENT_TYPE_LEN + 6];
        write_u32(&mut event, 0, UHID_SET_REPORT_REPLY);
        write_u32(&mut event, EVENT_TYPE_LEN, id);
        write_u16(&mut event, EVENT_TYPE_LEN + 4, err);
        write_uhid_event(file, &event)
    }

    fn write_uhid_event(file: &mut File, event: &[u8]) -> io::Result<()> {
        loop {
            match file.write(event) {
                Ok(bytes) if bytes == event.len() => return Ok(()),
                Ok(bytes) => {
                    return Err(io::Error::other(format!(
                        "short write to /dev/uhid: wrote {bytes} of {} bytes",
                        event.len()
                    )));
                }
                Err(err) if err.kind() == io::ErrorKind::Interrupted => continue,
                Err(err) => return Err(err),
            }
        }
    }

    fn choose_descriptor(config: &Config) -> Result<DescriptorChoice, AnyError> {
        if let Some(path) = &config.descriptor {
            return read_descriptor(
                path,
                format!("explicit --descriptor {}", path.display()),
                false,
            );
        }

        if let Some(path) = latest_usb_descriptor(&config.capture_root) {
            return read_descriptor(
                &path,
                format!("latest USB capture {}", path.display()),
                false,
            );
        }

        Ok(DescriptorChoice {
            bytes: fallback_ds4_usb_descriptor().to_vec(),
            label: "built-in fallback DS4-like USB descriptor".to_string(),
            is_fallback: true,
        })
    }

    fn read_descriptor(
        path: &Path,
        label: String,
        is_fallback: bool,
    ) -> Result<DescriptorChoice, AnyError> {
        let bytes = fs::read(path).map_err(|err| {
            io::Error::new(
                err.kind(),
                format!("could not read HID report descriptor {}: {err}", path.display()),
            )
        })?;
        if bytes.is_empty() {
            return Err(io::Error::other(format!(
                "HID report descriptor {} is empty",
                path.display()
            ))
            .into());
        }
        if bytes.len() > HID_MAX_DESCRIPTOR_SIZE {
            return Err(io::Error::other(format!(
                "HID report descriptor {} is {} bytes; max supported by UHID is {HID_MAX_DESCRIPTOR_SIZE}",
                path.display(),
                bytes.len()
            ))
            .into());
        }
        Ok(DescriptorChoice {
            bytes,
            label,
            is_fallback,
        })
    }

    fn read_capture_defaults(capture_root: &Path) -> CaptureDefaults {
        let Some(usb_dir) = latest_usb_capture_dir(capture_root) else {
            return CaptureDefaults::default();
        };

        let name = read_trimmed(usb_dir.join("identity/name.txt"));
        let version = read_trimmed(usb_dir.join("identity/version.txt"))
            .and_then(|value| parse_hex_or_dec(&value).ok());

        CaptureDefaults { name, version }
    }

    fn latest_usb_descriptor(capture_root: &Path) -> Option<PathBuf> {
        let mut candidates = Vec::new();
        for capture in fs::read_dir(capture_root).ok()?.flatten() {
            let timestamp = capture.file_name().to_string_lossy().into_owned();
            let usb_dir = capture.path().join("usb");
            for relative in ["report_descriptor.bin", "hidraw/report_descriptor.bin"] {
                let path = usb_dir.join(relative);
                if path.is_file() {
                    candidates.push((timestamp.clone(), path));
                }
            }
        }

        candidates.sort_by(|a, b| a.0.cmp(&b.0));
        candidates.pop().map(|(_, path)| path)
    }

    fn latest_usb_capture_dir(capture_root: &Path) -> Option<PathBuf> {
        let mut dirs = Vec::new();
        for capture in fs::read_dir(capture_root).ok()?.flatten() {
            let timestamp = capture.file_name().to_string_lossy().into_owned();
            let usb_dir = capture.path().join("usb");
            if usb_dir.is_dir() {
                dirs.push((timestamp, usb_dir));
            }
        }

        dirs.sort_by(|a, b| a.0.cmp(&b.0));
        dirs.pop().map(|(_, path)| path)
    }

    fn neutral_usb_ds4_report() -> [u8; 64] {
        let mut report = [0_u8; 64];
        report[0] = 0x01;
        report[1] = 0x80;
        report[2] = 0x80;
        report[3] = 0x80;
        report[4] = 0x80;
        report[5] = 0x08;
        report[8] = 0x00;
        report[9] = 0x00;
        report
    }

    fn discover_virtual_devices(vid: u32, pid: u32) {
        let hidraw = discover_hidraw_devices(vid, pid);
        if hidraw.is_empty() {
            println!("[probe] matching hidraw device not found yet under /sys/class/hidraw");
        } else {
            for item in hidraw {
                println!("[probe] matching hidraw device: {item}");
            }
        }

        let input = discover_input_events(vid, pid);
        if input.is_empty() {
            println!("[probe] matching input event device not found yet under /sys/class/input");
        } else {
            for item in input {
                println!("[probe] matching input event device: {item}");
            }
        }
    }

    fn discover_hidraw_devices(vid: u32, pid: u32) -> Vec<String> {
        let mut matches = Vec::new();
        let Ok(entries) = fs::read_dir("/sys/class/hidraw") else {
            return matches;
        };
        let needle = format!("0003:{vid:08X}:{pid:08X}");

        for entry in entries.flatten() {
            let path = entry.path();
            let uevent = read_trimmed(path.join("device/uevent")).unwrap_or_default();
            if uevent.to_ascii_uppercase().contains(&needle) {
                let dev = format!("/dev/{}", entry.file_name().to_string_lossy());
                matches.push(format!("{dev} sysfs={}", path.join("device").display()));
            }
        }

        matches
    }

    fn discover_input_events(vid: u32, pid: u32) -> Vec<String> {
        let mut matches = Vec::new();
        let Ok(entries) = fs::read_dir("/sys/class/input") else {
            return matches;
        };

        for entry in entries.flatten() {
            let event_name = entry.file_name().to_string_lossy().into_owned();
            if !event_name.starts_with("event") {
                continue;
            }

            let device = entry.path().join("device");
            let Some(bus) = read_sysfs_hex(device.join("id/bustype")) else {
                continue;
            };
            let Some(vendor) = read_sysfs_hex(device.join("id/vendor")) else {
                continue;
            };
            let Some(product) = read_sysfs_hex(device.join("id/product")) else {
                continue;
            };

            if bus == u32::from(BUS_USB) && vendor == vid && product == pid {
                let name =
                    read_trimmed(device.join("name")).unwrap_or_else(|| "unknown".to_string());
                matches.push(format!(
                    "/dev/input/{event_name} name=\"{name}\" sysfs={}",
                    device.display()
                ));
            }
        }

        matches
    }

    fn fallback_ds4_usb_descriptor() -> &'static [u8] {
        &[
            0x05, 0x01, 0x09, 0x05, 0xa1, 0x01, 0x85, 0x01, 0x09, 0x30, 0x09, 0x31, 0x09,
            0x32, 0x09, 0x35, 0x15, 0x00, 0x26, 0xff, 0x00, 0x75, 0x08, 0x95, 0x04, 0x81,
            0x02, 0x09, 0x39, 0x15, 0x00, 0x25, 0x08, 0x35, 0x00, 0x46, 0x3b, 0x01, 0x65,
            0x14, 0x75, 0x04, 0x95, 0x01, 0x81, 0x42, 0x65, 0x00, 0x05, 0x09, 0x19, 0x01,
            0x29, 0x0e, 0x15, 0x00, 0x25, 0x01, 0x75, 0x01, 0x95, 0x0e, 0x81, 0x02, 0x75,
            0x01, 0x95, 0x02, 0x81, 0x03, 0x05, 0x01, 0x09, 0x33, 0x09, 0x34, 0x15, 0x00,
            0x26, 0xff, 0x00, 0x75, 0x08, 0x95, 0x02, 0x81, 0x02, 0x06, 0x00, 0xff, 0x09,
            0x20, 0x15, 0x00, 0x26, 0xff, 0x00, 0x75, 0x08, 0x95, 0x36, 0x81, 0x02, 0xc0,
        ]
    }

    fn write_fixed_cstr(target: &mut [u8], value: &str) {
        target.fill(0);
        let max = target.len().saturating_sub(1);
        let bytes = value.as_bytes();
        let len = bytes.len().min(max);
        target[..len].copy_from_slice(&bytes[..len]);
    }

    fn write_u16(buf: &mut [u8], offset: usize, value: u16) {
        buf[offset..offset + 2].copy_from_slice(&value.to_ne_bytes());
    }

    fn write_u32(buf: &mut [u8], offset: usize, value: u32) {
        buf[offset..offset + 4].copy_from_slice(&value.to_ne_bytes());
    }

    fn read_u16(buf: &[u8], offset: usize) -> Option<u16> {
        let bytes = buf.get(offset..offset + 2)?;
        Some(u16::from_ne_bytes([bytes[0], bytes[1]]))
    }

    fn read_u32(buf: &[u8], offset: usize) -> Option<u32> {
        let bytes = buf.get(offset..offset + 4)?;
        Some(u32::from_ne_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]))
    }

    fn read_u64(buf: &[u8], offset: usize) -> Option<u64> {
        let bytes = buf.get(offset..offset + 8)?;
        Some(u64::from_ne_bytes([
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
        ]))
    }

    fn value_for<I>(
        args: &mut std::iter::Peekable<I>,
        inline_value: Option<String>,
        option: &str,
    ) -> Result<String, AnyError>
    where
        I: Iterator<Item = String>,
    {
        if let Some(value) = inline_value {
            return Ok(value);
        }
        args.next()
            .ok_or_else(|| io::Error::other(format!("missing value for {option}")).into())
    }

    fn parse_hex_or_dec(value: &str) -> Result<u32, AnyError> {
        let raw = value.trim();
        if raw.is_empty() {
            return Err(io::Error::other("empty numeric value").into());
        }

        let (digits, radix) = if let Some(hex) = raw
            .strip_prefix("0x")
            .or_else(|| raw.strip_prefix("0X"))
        {
            (hex, 16)
        } else if raw.chars().any(|ch| ch.is_ascii_hexdigit() && !ch.is_ascii_digit())
            || (raw.len() > 1 && raw.starts_with('0'))
        {
            (raw, 16)
        } else {
            (raw, 10)
        };

        u32::from_str_radix(digits, radix).map_err(|err| {
            io::Error::other(format!("invalid numeric value {value:?}: {err}")).into()
        })
    }

    fn read_trimmed(path: impl AsRef<Path>) -> Option<String> {
        fs::read_to_string(path)
            .ok()
            .map(|value| value.trim().to_string())
            .filter(|value| !value.is_empty())
    }

    fn read_sysfs_hex(path: impl AsRef<Path>) -> Option<u32> {
        let value = read_trimmed(path)?;
        u32::from_str_radix(value.trim_start_matches("0x"), 16).ok()
    }

    fn print_help() {
        println!(
            "ds4-bt-usb-probe

Creates a temporary UHID virtual USB-style DS4/PS4-compatible controller.

Options:
  --descriptor <path>     HID report descriptor binary to use
  --name <string>         Virtual HID device name
  --version <hex|dec>     Virtual HID version, default from USB capture or 0x0100
  --vid <hex|dec>         Vendor ID, default 0x054c
  --pid <hex|dec>         Product ID, default 0x09cc
  --interval-ms <n>       Neutral input report interval, default 8
  --capture-root <path>   Capture root, default captures
  -h, --help              Show this help
"
        );
    }
}
