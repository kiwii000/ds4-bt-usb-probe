#[cfg(not(target_os = "linux"))]
fn main() {
    eprintln!("ds4-bt-usb-probe is Linux-only.");
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
    use std::collections::{BTreeMap, HashMap};
    use std::env;
    use std::error::Error;
    use std::ffi::c_int;
    use std::fs::{self, File, OpenOptions};
    use std::io::{self, Read, Write};
    use std::mem::size_of;
    use std::os::fd::AsRawFd;
    use std::os::unix::fs::OpenOptionsExt;
    use std::path::{Path, PathBuf};
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::{Arc, Mutex};
    use std::thread;
    use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

    type AnyError = Box<dyn Error + Send + Sync + 'static>;

    const HID_MAX_DESCRIPTOR_SIZE: usize = 4096;
    const UHID_DATA_MAX: usize = 4096;
    const EVENT_TYPE_LEN: usize = 4;
    const CREATE2_LEN: usize = 128 + 64 + 64 + 2 + 2 + 4 + 4 + 4 + 4 + HID_MAX_DESCRIPTOR_SIZE;
    const CREATE2_RD_OFFSET: usize = 128 + 64 + 64 + 2 + 2 + 4 + 4 + 4 + 4;
    const BUS_USB: u16 = 0x0003;
    const SONY_VID: u32 = 0x054c;
    const DS4_PID: u32 = 0x09cc;
    const SONY_DS4_NAME: &str = "Sony Interactive Entertainment Wireless Controller";

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

    const UHID_FEATURE_REPORT: u8 = 0;
    const EIO: u16 = 5;
    const DS4_FEATURES: [(u8, usize); 4] = [(0x02, 37), (0x12, 16), (0x81, 7), (0xa3, 49)];

    const EV_SYN: u16 = 0x00;
    const EV_KEY: u16 = 0x01;
    const EV_ABS: u16 = 0x03;
    const SYN_REPORT: u16 = 0;
    const ABS_X: u16 = 0x00;
    const ABS_Y: u16 = 0x01;
    const ABS_Z: u16 = 0x02;
    const ABS_RX: u16 = 0x03;
    const ABS_RY: u16 = 0x04;
    const ABS_RZ: u16 = 0x05;
    const ABS_HAT0X: u16 = 0x10;
    const ABS_HAT0Y: u16 = 0x11;
    const BTN_SOUTH: u16 = 0x130;
    const BTN_EAST: u16 = 0x131;
    const BTN_NORTH: u16 = 0x133;
    const BTN_WEST: u16 = 0x134;
    const BTN_TL: u16 = 0x136;
    const BTN_TR: u16 = 0x137;
    const BTN_TL2: u16 = 0x138;
    const BTN_TR2: u16 = 0x139;
    const BTN_SELECT: u16 = 0x13a;
    const BTN_START: u16 = 0x13b;
    const BTN_MODE: u16 = 0x13c;
    const BTN_THUMBL: u16 = 0x13d;
    const BTN_THUMBR: u16 = 0x13e;
    const UINPUT_MAX_NAME_SIZE: usize = 80;

    static RUNNING: AtomicBool = AtomicBool::new(true);

    extern "C" fn handle_shutdown_signal(_signum: c_int) {
        RUNNING.store(false, Ordering::Relaxed);
    }

    #[derive(Debug)]
    enum Command {
        Run(Config),
        CaptureFeatures { hidraw: PathBuf, output_dir: PathBuf },
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
        bridge: bool,
        output_mode: OutputMode,
        feature_root: Option<PathBuf>,
        raw_capture_dir: Option<PathBuf>,
        status_file: Option<PathBuf>,
        uinput_version: Option<u32>,
    }

    #[derive(Clone, Copy, Debug, Eq, PartialEq)]
    enum OutputMode {
        Both,
        UhidOnly,
    }

    impl OutputMode {
        fn as_str(self) -> &'static str {
            match self {
                Self::Both => "both",
                Self::UhidOnly => "uhid",
            }
        }
    }

    #[derive(Debug, Default)]
    struct CaptureDefaults {
        uhid_version: Option<u32>,
        input_version: Option<u32>,
    }

    #[derive(Debug)]
    struct DescriptorChoice {
        bytes: Vec<u8>,
        label: String,
        is_fallback: bool,
    }

    #[derive(Debug, Default)]
    struct InitState {
        started: bool,
        opened: bool,
        stopped: bool,
        closed: bool,
        known_feature_replies: usize,
        virtual_hidraw: usize,
        virtual_input: usize,
    }

    struct UhidDevice {
        file: File,
        created: bool,
    }

    struct FeatureReports {
        reports: HashMap<u8, Vec<u8>>,
    }

    #[derive(Clone)]
    struct StatusTracker {
        path: Option<PathBuf>,
        values: Arc<Mutex<BTreeMap<String, String>>>,
    }

    #[derive(Clone, Debug, Default, Eq, PartialEq)]
    struct GamepadState {
        lx: u8,
        ly: u8,
        rx: u8,
        ry: u8,
        l2: u8,
        r2: u8,
        dpad_x: i32,
        dpad_y: i32,
        square: bool,
        cross: bool,
        circle: bool,
        triangle: bool,
        l1: bool,
        r1: bool,
        l2_button: bool,
        r2_button: bool,
        share: bool,
        options: bool,
        ps: bool,
        thumb_l: bool,
        thumb_r: bool,
    }

    #[repr(C)]
    struct InputId {
        bustype: u16,
        vendor: u16,
        product: u16,
        version: u16,
    }

    #[repr(C)]
    struct UinputSetup {
        id: InputId,
        name: [u8; UINPUT_MAX_NAME_SIZE],
        ff_effects_max: u32,
    }

    #[repr(C)]
    struct InputAbsInfo {
        value: i32,
        minimum: i32,
        maximum: i32,
        fuzz: i32,
        flat: i32,
        resolution: i32,
    }

    #[repr(C)]
    struct UinputAbsSetup {
        code: u16,
        padding: u16,
        absinfo: InputAbsInfo,
    }

    #[repr(C)]
    struct InputEvent {
        time: libc::timeval,
        event_type: u16,
        code: u16,
        value: i32,
    }

    struct UinputDevice {
        file: File,
        created: bool,
        sysname: Option<String>,
        event_node: Option<String>,
    }

    struct TranslatedInput {
        usb_report: [u8; 64],
        gamepad: GamepadState,
    }

    pub fn run() -> Result<(), AnyError> {
        let Some(command) = parse_command(env::args().skip(1))? else {
            print_help();
            return Ok(());
        };
        match command {
            Command::CaptureFeatures { hidraw, output_dir } => {
                capture_features(&hidraw, &output_dir)
            }
            Command::Run(config) => run_device(config),
        }
    }

    fn run_device(config: Config) -> Result<(), AnyError> {
        install_signal_handlers();
        let capture_defaults = read_capture_defaults(&config.capture_root);
        let descriptor = choose_descriptor(&config)?;
        let name = config.name.clone().unwrap_or_else(|| SONY_DS4_NAME.to_string());
        let uhid_version = choose_uhid_version(config.version, capture_defaults.uhid_version);
        let uinput_version =
            choose_uinput_version(config.uinput_version, capture_defaults.input_version);
        let uhid_version_source = version_source(config.version, capture_defaults.uhid_version);
        let uinput_version_source =
            version_source(config.uinput_version, capture_defaults.input_version);
        let status = Arc::new(StatusTracker::new(config.status_file.clone()));
        status.set("probe_version", "0.4.0");
        status.set("output_mode", config.output_mode.as_str());
        status.set("uhid_ready", "false");
        status.set("uinput_required", (config.output_mode == OutputMode::Both).to_string());
        status.set("uinput_enabled", (config.output_mode == OutputMode::Both).to_string());
        status.set("uinput_ready", "false");
        status.set("bluetooth_ready", "false");
        status.set("bluetooth_reports_read", "0");
        status.set("bluetooth_reports_forwarded", "0");
        status.set("uhid_reports_emitted", "0");
        status.set("uinput_events_emitted", "0");
        status.set("get_report_eio", "0");
        status.set("running", "true");
        status.set("uhid_version", format!("0x{uhid_version:04x}"));
        status.set("uhid_version_source", uhid_version_source);
        status.set("uinput_version", format!("0x{uinput_version:04x}"));
        status.set("uinput_version_source", uinput_version_source);
        status.set("uhid_bus", "0x0003");
        status.set("uhid_vid", format!("0x{:04x}", config.vid));
        status.set("uhid_pid", format!("0x{:04x}", config.pid));
        status.set("uinput_bus", "0x0003");
        status.set("uinput_vid", format!("0x{:04x}", config.vid));
        status.set("uinput_pid", format!("0x{:04x}", config.pid));
        status.set("virtual_name", &name);
        status.set("descriptor_source", &descriptor.label);
        let features = Arc::new(FeatureReports::load(
            config.feature_root.as_deref(),
            config.bridge,
            &descriptor.bytes,
            &status,
        ));
        let state = Arc::new(Mutex::new(InitState::default()));

        println!("[probe] opening /dev/uhid");
        let mut device = UhidDevice::open().map_err(|err| {
            status.set("uhid_error", format!("could not open /dev/uhid: {err}"));
            io::Error::new(
                err.kind(),
                format!("could not open /dev/uhid: {err}. Run this as root on the Bazzite host"),
            )
        })?;
        println!("[probe] /dev/uhid opened");
        spawn_event_reader(
            device.file.try_clone()?,
            features,
            Arc::clone(&state),
            Arc::clone(&status),
        );

        if descriptor.is_fallback {
            println!("[probe] WARNING: using built-in fallback DS4-like USB descriptor");
        }
        println!("[probe] descriptor source: {}", descriptor.label);
        println!(
            "[probe] virtual identity: bus=USB/0x{BUS_USB:04x} vid=0x{:04x} pid=0x{:04x} version=0x{uhid_version:04x} name=\"{name}\"",
            config.vid, config.pid
        );
        println!("[probe] UHID version source: {uhid_version_source}");
        device
            .create(&name, config.vid, config.pid, uhid_version, &descriptor.bytes)
            .map_err(|err| {
                status.set("uhid_error", format!("UHID_CREATE2 failed: {err}"));
                err
            })?;
        println!("[probe] UHID_CREATE2 sent");

        let report = neutral_usb_ds4_report();
        device.send_input_report(&report)?;
        wait_for_virtual_device(
            &mut device,
            &state,
            config.vid,
            config.pid,
            &report,
            &status,
        )
        .map_err(|err| {
            status.set("uhid_error", err.to_string());
            err
        })?;
        println!("[probe] READY: virtual DS4 initialized");
        status.set("uhid_ready", "true");

        let result = if config.bridge {
            run_bridge(
                &mut device,
                &config,
                report,
                uinput_version,
                uinput_version_source,
                &name,
                &status,
            )
        } else {
            run_neutral_loop(&mut device, &config, report)
        };
        if let Err(err) = &result {
            status.set("fatal_error", err.to_string());
        }
        status.set("running", "false");
        result
    }

    fn run_neutral_loop(
        device: &mut UhidDevice,
        config: &Config,
        report: [u8; 64],
    ) -> Result<(), AnyError> {
        println!(
            "[probe] sending neutral USB-style DS4 reports every {}ms",
            config.interval_ms
        );
        let interval = Duration::from_millis(config.interval_ms.max(1));
        while RUNNING.load(Ordering::Relaxed) {
            device.send_input_report(&report)?;
            thread::sleep(interval);
        }
        device.destroy()?;
        Ok(())
    }

    fn run_bridge(
        device: &mut UhidDevice,
        config: &Config,
        neutral: [u8; 64],
        uinput_version: u32,
        uinput_version_source: &str,
        name: &str,
        status: &Arc<StatusTracker>,
    ) -> Result<(), AnyError> {
        if config.output_mode == OutputMode::Both {
            println!(
                "[uinput] requested identity: bus=USB/0x{BUS_USB:04x} vid=0x{:04x} pid=0x{:04x} version=0x{uinput_version:04x} name=\"{name}\"",
                config.vid, config.pid
            );
            println!("[uinput] version source: {uinput_version_source}");
        }
        let mut uinput = if config.output_mode == OutputMode::Both {
            match UinputDevice::create(name, config.vid, config.pid, uinput_version) {
                Ok(created) => {
                    status.set(
                        "uinput_sysname",
                        created.sysname.as_deref().unwrap_or("unknown"),
                    );
                    status.set(
                        "uinput_event_node",
                        created.event_node.as_deref().unwrap_or("not discovered"),
                    );
                    if let Some(sysname) = &created.sysname {
                        status.set(
                            "uinput_syspath",
                            format!("/sys/devices/virtual/input/{sysname}"),
                        );
                    }
                    if created.event_node.is_some() {
                        println!(
                            "[uinput] READY: fallback gamepad created sysname={} event={}",
                            created.sysname.as_deref().unwrap_or("unknown"),
                            created.event_node.as_deref().unwrap_or("not discovered")
                        );
                        status.set("uinput_ready", "true");
                    } else {
                        status.set("uinput_error", "created but event node was not discovered");
                    }
                    Some(created)
                }
                Err(err) => {
                    println!("[uinput] ERROR: fallback gamepad creation failed: {err}");
                    status.set("uinput_error", err.to_string());
                    None
                }
            }
        } else {
            println!("[uinput] disabled by output mode");
            status.set("uinput_error", "disabled by output mode");
            None
        };
        let hidraw = discover_bluetooth_hidraw(config.vid, config.pid).ok_or_else(|| {
            let message = "no physical Bluetooth hidraw device found for BUS_BLUETOOTH 054c:09cc";
            status.set("bluetooth_error", message);
            io::Error::other(message)
        })?;
        println!("[bridge] physical Bluetooth hidraw: {}", hidraw.display());
        status.set("bluetooth_hidraw", hidraw.display().to_string());
        let mut input = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NONBLOCK)
            .open(&hidraw)
            .map_err(|err| {
                status.set("bluetooth_error", format!("could not open {}: {err}", hidraw.display()));
                io::Error::new(err.kind(), format!("could not open {}: {err}", hidraw.display()))
            })?;
        let raw_dir = config
            .raw_capture_dir
            .clone()
            .unwrap_or_else(|| config.capture_root.join("bridge-raw"));
        fs::create_dir_all(&raw_dir)?;
        let mut buffer = [0_u8; 256];
        let mut unexpected_count = 0_u32;
        let mut last_keepalive = Instant::now();
        let mut forwarded = 0_u64;
        let mut pollfd = libc::pollfd {
            fd: input.as_raw_fd(),
            events: libc::POLLIN,
            revents: 0,
        };
        println!("[bridge] forwarding basic Bluetooth controls to virtual USB DS4");
        println!("[bridge] READY: Bluetooth input stream opened");
        status.set("bluetooth_ready", "true");

        while RUNNING.load(Ordering::Relaxed) {
            pollfd.revents = 0;
            // SAFETY: pollfd points to one valid pollfd for the duration of the call.
            let poll_result = unsafe { libc::poll(&mut pollfd, 1, 2) };
            if poll_result < 0 {
                let err = io::Error::last_os_error();
                if err.kind() == io::ErrorKind::Interrupted {
                    continue;
                }
                return Err(err.into());
            }
            if pollfd.revents & (libc::POLLERR | libc::POLLHUP | libc::POLLNVAL) != 0 {
                return Err(io::Error::other(format!(
                    "Bluetooth hidraw poll failure: revents=0x{:x}",
                    pollfd.revents
                ))
                .into());
            }
            if poll_result == 0 || pollfd.revents & libc::POLLIN == 0 {
                if last_keepalive.elapsed() >= Duration::from_millis(config.interval_ms.max(4)) {
                    device.send_input_report(&neutral)?;
                    status.increment("uhid_reports_emitted", 1);
                    last_keepalive = Instant::now();
                }
                continue;
            }
            match input.read(&mut buffer) {
                Ok(0) => {}
                Ok(size) => {
                    status.increment("bluetooth_reports_read", 1);
                    match translate_bluetooth_report(&buffer[..size]) {
                        Ok(translated) => {
                            device.send_input_report(&translated.usb_report)?;
                            status.increment("uhid_reports_emitted", 1);
                            if let Some(output) = uinput.as_mut() {
                                let emitted =
                                    output.emit_state(&translated.gamepad).map_err(|err| {
                                        status.set(
                                            "uinput_error",
                                            format!("event emission failed: {err}"),
                                        );
                                        err
                                    })?;
                                status.increment("uinput_events_emitted", emitted);
                            }
                            forwarded += 1;
                            status.increment("bluetooth_reports_forwarded", 1);
                            if forwarded == 1 || forwarded.is_multiple_of(1000) {
                                println!("[bridge] forwarded {forwarded} Bluetooth input reports");
                            }
                            last_keepalive = Instant::now();
                        }
                        Err(reason) => {
                            println!(
                                "[bridge] unexpected input report id=0x{:02x} len={size}: {reason}",
                                buffer[0]
                            );
                            if unexpected_count < 20 {
                                save_raw_sample(&raw_dir, unexpected_count, &buffer[..size])?;
                                unexpected_count += 1;
                            }
                        }
                    }
                }
                Err(err) if err.kind() == io::ErrorKind::WouldBlock => {}
                Err(err) if err.kind() == io::ErrorKind::Interrupted => {}
                Err(err) => return Err(err.into()),
            }
        }
        device.destroy()?;
        Ok(())
    }

    fn wait_for_virtual_device(
        device: &mut UhidDevice,
        state: &Arc<Mutex<InitState>>,
        vid: u32,
        pid: u32,
        neutral: &[u8],
        status: &StatusTracker,
    ) -> Result<(), AnyError> {
        let deadline = Instant::now() + Duration::from_secs(10);
        while Instant::now() < deadline {
            device.send_input_report(neutral)?;
            let current = state.lock().map_err(|_| io::Error::other("init state lock poisoned"))?;
            if current.stopped || current.closed {
                return Err(io::Error::other(format!(
                    "virtual DS4 stopped during initialization: {current:?}"
                ))
                .into());
            }
            let lifecycle_ready = current.started;
            let opened = current.opened;
            let known_feature_replies = current.known_feature_replies;
            drop(current);
            let (virtual_hidraw_nodes, virtual_input_nodes) = discover_virtual_devices(vid, pid);
            let virtual_hidraw = virtual_hidraw_nodes.len();
            let virtual_input = virtual_input_nodes.len();
            update_state(state, |s| {
                s.virtual_hidraw = virtual_hidraw;
                s.virtual_input = virtual_input;
            });
            if lifecycle_ready && virtual_hidraw + virtual_input > 0 {
                println!(
                    "[probe] initialization lifecycle ready; opened={opened} known feature replies={known_feature_replies} virtual_hidraw={virtual_hidraw} virtual_input={virtual_input}"
                );
                status.set("uhid_hidraw_count", virtual_hidraw.to_string());
                status.set("uhid_input_count", virtual_input.to_string());
                status.set(
                    "uhid_hidraw_nodes",
                    virtual_hidraw_nodes
                        .iter()
                        .map(|path| path.display().to_string())
                        .collect::<Vec<_>>()
                        .join(","),
                );
                status.set("uhid_input_nodes", virtual_input_nodes.join(","));
                return Ok(());
            }
            thread::sleep(Duration::from_millis(200));
        }
        Err(io::Error::other("virtual DS4 did not appear as hidraw/input device within 10 seconds").into())
    }

    impl FeatureReports {
        fn load(
            root: Option<&Path>,
            bridge: bool,
            descriptor: &[u8],
            status: &StatusTracker,
        ) -> Self {
            let mut reports = HashMap::new();
            let mut sizes = feature_report_sizes(descriptor);
            for (id, size) in DS4_FEATURES {
                sizes.insert(id, size);
            }
            for (id, size) in sizes {
                if size == 0 || size > UHID_DATA_MAX {
                    println!(
                        "[feature] report 0x{id:02x} has unusable descriptor size={size}; requests will receive EIO"
                    );
                    continue;
                }
                let path = root.map(|dir| dir.join(format!("0x{id:02x}.bin")));
                let captured = path
                    .as_ref()
                    .and_then(|path| fs::read(path).ok())
                    .filter(|data| valid_feature_report(data, id, size));
                let source = if captured.is_some() {
                    "captured"
                } else {
                    "synthetic fallback"
                };
                let mut report = captured.unwrap_or_else(|| synthetic_feature_report(id, size));
                if bridge && id == 0x12 {
                    rewrite_pairing_mac(&mut report);
                    println!("[feature] report 0x12 source={source}, virtual MAC rewritten");
                    status.set("feature_0x12_virtual_mac_rewritten", "true");
                } else {
                    println!("[feature] report 0x{id:02x} source={source} size={size}");
                }
                status.set(format!("feature_0x{id:02x}_source"), source);
                status.set(format!("feature_0x{id:02x}_size"), size.to_string());
                let _ = reports.insert(id, report);
            }
            Self { reports }
        }
    }

    impl StatusTracker {
        fn new(path: Option<PathBuf>) -> Self {
            Self {
                path,
                values: Arc::new(Mutex::new(BTreeMap::new())),
            }
        }

        fn set(&self, key: impl Into<String>, value: impl ToString) {
            if let Ok(mut values) = self.values.lock() {
                values.insert(key.into(), value.to_string());
                self.flush_locked(&values);
            }
        }

        fn increment(&self, key: &str, amount: u64) {
            if let Ok(mut values) = self.values.lock() {
                let previous = values
                    .get(key)
                    .and_then(|value| value.parse::<u64>().ok())
                    .unwrap_or(0);
                let next = previous.saturating_add(amount);
                values.insert(key.to_string(), next.to_string());
                if previous == 0 || next.is_multiple_of(100) {
                    self.flush_locked(&values);
                }
            }
        }

        fn flush_locked(&self, values: &BTreeMap<String, String>) {
            let Some(path) = &self.path else {
                return;
            };
            if let Some(parent) = path.parent() {
                if let Err(err) = fs::create_dir_all(parent) {
                    println!("[status] could not create {}: {err}", parent.display());
                    return;
                }
            }
            let body = values
                .iter()
                .map(|(key, value)| format!("{key}={value}\n"))
                .collect::<String>();
            let temporary = path.with_extension("tmp");
            if let Err(err) = fs::write(&temporary, body).and_then(|_| fs::rename(&temporary, path)) {
                println!("[status] could not update {}: {err}", path.display());
            }
        }
    }

    fn feature_report_sizes(descriptor: &[u8]) -> BTreeMap<u8, usize> {
        let mut report_size = 0_u32;
        let mut report_count = 0_u32;
        let mut report_id = 0_u8;
        let mut stack = Vec::new();
        let mut feature_bits = BTreeMap::<u8, usize>::new();
        let mut index = 0;
        while index < descriptor.len() {
            let prefix = descriptor[index];
            if prefix == 0xfe {
                if index + 2 >= descriptor.len() {
                    break;
                }
                index += 3 + usize::from(descriptor[index + 1]);
                continue;
            }
            let data_len = match prefix & 0x03 {
                0 => 0,
                1 => 1,
                2 => 2,
                _ => 4,
            };
            if index + 1 + data_len > descriptor.len() {
                break;
            }
            let data = &descriptor[index + 1..index + 1 + data_len];
            let value = data
                .iter()
                .enumerate()
                .fold(0_u32, |acc, (shift, byte)| acc | (u32::from(*byte) << (shift * 8)));
            let item_type = (prefix >> 2) & 0x03;
            let tag = (prefix >> 4) & 0x0f;
            match (item_type, tag) {
                (1, 7) => report_size = value,
                (1, 8) => report_id = value as u8,
                (1, 9) => report_count = value,
                (1, 10) => stack.push((report_size, report_count, report_id)),
                (1, 11) => {
                    if let Some(saved) = stack.pop() {
                        (report_size, report_count, report_id) = saved;
                    }
                }
                (0, 11) => {
                    let bits = usize::try_from(report_size.saturating_mul(report_count)).unwrap_or(0);
                    *feature_bits.entry(report_id).or_default() += bits;
                }
                _ => {}
            }
            index += 1 + data_len;
        }
        feature_bits
            .into_iter()
            .map(|(id, bits)| (id, bits.div_ceil(8) + if id == 0 { 0 } else { 1 }))
            .collect()
    }

    impl UhidDevice {
        fn open() -> io::Result<Self> {
            Ok(Self {
                file: OpenOptions::new().read(true).write(true).open("/dev/uhid")?,
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
            if descriptor.is_empty() || descriptor.len() > HID_MAX_DESCRIPTOR_SIZE {
                return Err(io::Error::other("invalid HID report descriptor size"));
            }
            let mut event = vec![0_u8; EVENT_TYPE_LEN + CREATE2_LEN];
            write_u32(&mut event, 0, UHID_CREATE2);
            let payload = EVENT_TYPE_LEN;
            write_fixed_cstr(&mut event[payload..payload + 128], name);
            write_fixed_cstr(&mut event[payload + 128..payload + 192], "usb-ds4-bt-usb-probe");
            write_fixed_cstr(&mut event[payload + 192..payload + 256], "ds4-bt-usb-probe");
            write_u16(&mut event, payload + 256, descriptor.len() as u16);
            write_u16(&mut event, payload + 258, BUS_USB);
            write_u32(&mut event, payload + 260, vid);
            write_u32(&mut event, payload + 264, pid);
            write_u32(&mut event, payload + 268, version);
            event[payload + CREATE2_RD_OFFSET..payload + CREATE2_RD_OFFSET + descriptor.len()]
                .copy_from_slice(descriptor);
            write_uhid_event(&mut self.file, &event)?;
            self.created = true;
            Ok(())
        }

        fn send_input_report(&mut self, report: &[u8]) -> io::Result<()> {
            let mut event = vec![0_u8; EVENT_TYPE_LEN + 2 + report.len()];
            write_u32(&mut event, 0, UHID_INPUT2);
            write_u16(&mut event, EVENT_TYPE_LEN, report.len() as u16);
            event[EVENT_TYPE_LEN + 2..].copy_from_slice(report);
            write_uhid_event(&mut self.file, &event)
        }

        fn destroy(&mut self) -> io::Result<()> {
            if self.created {
                let mut event = [0_u8; EVENT_TYPE_LEN];
                write_u32(&mut event, 0, UHID_DESTROY);
                write_uhid_event(&mut self.file, &event)?;
                self.created = false;
            }
            Ok(())
        }
    }

    impl Drop for UhidDevice {
        fn drop(&mut self) {
            let _ = self.destroy();
        }
    }

    impl UinputDevice {
        fn create(name: &str, vid: u32, pid: u32, version: u32) -> io::Result<Self> {
            let mut last_error = None;
            let mut file = None;
            for path in ["/dev/uinput", "/dev/input/uinput"] {
                match OpenOptions::new()
                    .write(true)
                    .custom_flags(libc::O_NONBLOCK)
                    .open(path)
                {
                    Ok(opened) => {
                        println!("[uinput] opened {path}");
                        file = Some(opened);
                        break;
                    }
                    Err(err) => last_error = Some(io::Error::new(err.kind(), format!("{path}: {err}"))),
                }
            }
            let file = file.ok_or_else(|| {
                last_error.unwrap_or_else(|| io::Error::other("no uinput device path available"))
            })?;
            let mut device = Self {
                file,
                created: false,
                sysname: None,
                event_node: None,
            };
            device.enable_event_type(EV_KEY)?;
            device.enable_event_type(EV_ABS)?;
            for code in [
                BTN_SOUTH, BTN_EAST, BTN_NORTH, BTN_WEST, BTN_TL, BTN_TR, BTN_TL2, BTN_TR2,
                BTN_SELECT, BTN_START, BTN_MODE, BTN_THUMBL, BTN_THUMBR,
            ] {
                device.enable_key(code)?;
            }
            for code in [ABS_X, ABS_Y, ABS_RX, ABS_RY, ABS_Z, ABS_RZ] {
                device.setup_axis(code, 0, 255)?;
            }
            device.setup_axis(ABS_HAT0X, -1, 1)?;
            device.setup_axis(ABS_HAT0Y, -1, 1)?;

            let mut setup = UinputSetup {
                id: InputId {
                    bustype: BUS_USB,
                    vendor: vid as u16,
                    product: pid as u16,
                    version: version as u16,
                },
                name: [0; UINPUT_MAX_NAME_SIZE],
                ff_effects_max: 0,
            };
            write_fixed_cstr(&mut setup.name, name);
            ioctl_ptr(
                device.file.as_raw_fd(),
                ioc_write(b'U', 3, size_of::<UinputSetup>()),
                &setup,
            )?;
            ioctl_none(device.file.as_raw_fd(), ioc_none(b'U', 1))?;
            device.created = true;
            thread::sleep(Duration::from_millis(300));
            device.sysname = device.read_sysname();
            if let Some(sysname) = &device.sysname {
                println!("[uinput] sysname={sysname}");
                println!("[uinput] syspath=/sys/devices/virtual/input/{sysname}");
                device.event_node = wait_for_uinput_event_node(sysname, Duration::from_secs(5));
                if let Some(event) = &device.event_node {
                    println!("[uinput] event node={event}");
                } else {
                    println!("[uinput] WARNING: event node was not discovered");
                }
            } else {
                println!("[uinput] WARNING: UI_GET_SYSNAME did not return a sysname");
            }
            Ok(device)
        }

        fn enable_event_type(&self, event_type: u16) -> io::Result<()> {
            ioctl_int(
                self.file.as_raw_fd(),
                ioc_write(b'U', 100, size_of::<libc::c_int>()),
                i32::from(event_type),
            )
        }

        fn enable_key(&self, code: u16) -> io::Result<()> {
            ioctl_int(
                self.file.as_raw_fd(),
                ioc_write(b'U', 101, size_of::<libc::c_int>()),
                i32::from(code),
            )
        }

        fn setup_axis(&self, code: u16, minimum: i32, maximum: i32) -> io::Result<()> {
            let setup = UinputAbsSetup {
                code,
                padding: 0,
                absinfo: InputAbsInfo {
                    value: 0,
                    minimum,
                    maximum,
                    fuzz: 0,
                    flat: 0,
                    resolution: 0,
                },
            };
            ioctl_ptr(
                self.file.as_raw_fd(),
                ioc_write(b'U', 4, size_of::<UinputAbsSetup>()),
                &setup,
            )
        }

        fn read_sysname(&self) -> Option<String> {
            let mut buffer = [0_u8; UINPUT_MAX_NAME_SIZE];
            let result = unsafe {
                libc::ioctl(
                    self.file.as_raw_fd(),
                    ioc_read(b'U', 44, buffer.len()),
                    buffer.as_mut_ptr(),
                )
            };
            if result < 0 {
                println!("[uinput] UI_GET_SYSNAME failed: {}", io::Error::last_os_error());
                return None;
            }
            let end = buffer.iter().position(|byte| *byte == 0).unwrap_or(buffer.len());
            String::from_utf8(buffer[..end].to_vec()).ok().filter(|s| !s.is_empty())
        }

        fn emit_state(&mut self, state: &GamepadState) -> io::Result<u64> {
            let events = gamepad_events(state);
            for event in &events {
                write_struct(&mut self.file, event)?;
            }
            Ok(events.len() as u64)
        }

        fn destroy(&mut self) -> io::Result<()> {
            if self.created {
                ioctl_none(self.file.as_raw_fd(), ioc_none(b'U', 2))?;
                self.created = false;
            }
            Ok(())
        }
    }

    impl Drop for UinputDevice {
        fn drop(&mut self) {
            let _ = self.destroy();
        }
    }

    fn spawn_event_reader(
        mut file: File,
        features: Arc<FeatureReports>,
        state: Arc<Mutex<InitState>>,
        status: Arc<StatusTracker>,
    ) {
        let _ = thread::spawn(move || {
            let mut event = vec![0_u8; EVENT_TYPE_LEN + CREATE2_LEN];
            loop {
                event.fill(0);
                match file.read(&mut event) {
                    Ok(0) => break,
                    Ok(n) if n >= EVENT_TYPE_LEN => {
                        handle_uhid_event(&mut file, &event[..n], &features, &state, &status)
                    }
                    Ok(_) => {}
                    Err(err) if err.kind() == io::ErrorKind::Interrupted => {}
                    Err(err) => {
                        println!("[uhid] read error: {err}");
                        break;
                    }
                }
            }
        });
    }

    fn handle_uhid_event(
        file: &mut File,
        event: &[u8],
        features: &FeatureReports,
        state: &Arc<Mutex<InitState>>,
        status: &StatusTracker,
    ) {
        let Some(event_type) = read_u32(event, 0) else {
            return;
        };
        match event_type {
            UHID_START => {
                println!("[uhid] event UHID_START");
                update_state(state, |s| s.started = true);
            }
            UHID_STOP => {
                println!("[uhid] event UHID_STOP");
                update_state(state, |s| s.stopped = true);
            }
            UHID_OPEN => {
                println!("[uhid] event UHID_OPEN");
                update_state(state, |s| s.opened = true);
            }
            UHID_CLOSE => {
                println!("[uhid] event UHID_CLOSE");
                update_state(state, |s| s.closed = true);
            }
            UHID_OUTPUT => log_output_event(event),
            UHID_GET_REPORT => {
                let id = read_u32(event, EVENT_TYPE_LEN).unwrap_or(0);
                let rnum = event.get(EVENT_TYPE_LEN + 4).copied().unwrap_or(0);
                let rtype = event.get(EVENT_TYPE_LEN + 5).copied().unwrap_or(0);
                if rtype == UHID_FEATURE_REPORT {
                    if let Some(data) = features.reports.get(&rnum) {
                        println!(
                            "[uhid] GET_REPORT id={id} rnum=0x{rnum:02x} rtype={rtype} reply=success size={} data={}",
                            data.len(),
                            hex_prefix(data)
                        );
                        if let Err(err) = send_get_report_reply(file, id, 0, data) {
                            println!("[uhid] GET_REPORT_REPLY failed: {err}");
                        } else {
                            update_state(state, |s| s.known_feature_replies += 1);
                        }
                        return;
                    }
                }
                println!("[uhid] GET_REPORT id={id} rnum=0x{rnum:02x} rtype={rtype} reply=EIO");
                status.increment("get_report_eio", 1);
                let _ = send_get_report_reply(file, id, EIO, &[]);
            }
            UHID_SET_REPORT => {
                let id = read_u32(event, EVENT_TYPE_LEN).unwrap_or(0);
                let rnum = event.get(EVENT_TYPE_LEN + 4).copied().unwrap_or(0);
                let rtype = event.get(EVENT_TYPE_LEN + 5).copied().unwrap_or(0);
                let size = read_u16(event, EVENT_TYPE_LEN + 6).unwrap_or(0) as usize;
                let data = event.get(EVENT_TYPE_LEN + 8..EVENT_TYPE_LEN + 8 + size).unwrap_or(&[]);
                println!(
                    "[uhid] SET_REPORT id={id} rnum=0x{rnum:02x} rtype={rtype} size={size} data={}",
                    hex_prefix(data)
                );
                let _ = send_set_report_reply(file, id, 0);
            }
            other => println!("[uhid] event type {other}"),
        }
    }

    fn log_output_event(event: &[u8]) {
        let size = read_u16(event, EVENT_TYPE_LEN + UHID_DATA_MAX).unwrap_or(0) as usize;
        let rtype = event.get(EVENT_TYPE_LEN + UHID_DATA_MAX + 2).copied().unwrap_or(0);
        let data = event.get(EVENT_TYPE_LEN..EVENT_TYPE_LEN + size).unwrap_or(&[]);
        println!(
            "[uhid] OUTPUT rtype={rtype} size={size} data={}",
            hex_prefix(data)
        );
    }

    fn send_get_report_reply(file: &mut File, id: u32, err: u16, data: &[u8]) -> io::Result<()> {
        let event = build_get_report_reply(id, err, data);
        write_uhid_event(file, &event)
    }

    fn build_get_report_reply(id: u32, err: u16, data: &[u8]) -> Vec<u8> {
        let mut event = vec![0_u8; EVENT_TYPE_LEN + 8 + data.len()];
        write_u32(&mut event, 0, UHID_GET_REPORT_REPLY);
        write_u32(&mut event, EVENT_TYPE_LEN, id);
        write_u16(&mut event, EVENT_TYPE_LEN + 4, err);
        write_u16(&mut event, EVENT_TYPE_LEN + 6, data.len() as u16);
        event[EVENT_TYPE_LEN + 8..].copy_from_slice(data);
        event
    }

    fn send_set_report_reply(file: &mut File, id: u32, err: u16) -> io::Result<()> {
        let mut event = [0_u8; EVENT_TYPE_LEN + 6];
        write_u32(&mut event, 0, UHID_SET_REPORT_REPLY);
        write_u32(&mut event, EVENT_TYPE_LEN, id);
        write_u16(&mut event, EVENT_TYPE_LEN + 4, err);
        write_uhid_event(file, &event)
    }

    fn capture_features(hidraw: &Path, output_dir: &Path) -> Result<(), AnyError> {
        fs::create_dir_all(output_dir)?;
        let file = OpenOptions::new().read(true).write(true).open(hidraw)?;
        println!("[feature-capture] hidraw={}", hidraw.display());
        let mut feature_sizes = hidraw
            .file_name()
            .and_then(|name| fs::read(PathBuf::from("/sys/class/hidraw").join(name).join("device/report_descriptor")).ok())
            .map(|descriptor| feature_report_sizes(&descriptor))
            .unwrap_or_default();
        for (id, size) in DS4_FEATURES {
            feature_sizes.insert(id, size);
        }
        for (id, size) in feature_sizes {
            if size == 0 || size > UHID_DATA_MAX {
                println!("[feature-capture] report 0x{id:02x} skipped: invalid size={size}");
                continue;
            }
            let mut captured = None;
            for attempt in 1..=3 {
                let mut data = vec![0_u8; size];
                data[0] = id;
                let request = hidiocgfeature(size);
                // SAFETY: ioctl receives a valid file descriptor and writable buffer of the encoded size.
                let result = unsafe { libc::ioctl(file.as_raw_fd(), request, data.as_mut_ptr()) };
                if result < 0 {
                    println!(
                        "[feature-capture] report 0x{id:02x} attempt {attempt}/3 failed: {}",
                        io::Error::last_os_error()
                    );
                    continue;
                }
                let received = usize::try_from(result).unwrap_or(0);
                if received != size || data[0] != id {
                    println!(
                        "[feature-capture] report 0x{id:02x} attempt {attempt}/3 invalid: expected={size} received={received} first=0x{:02x}",
                        data[0]
                    );
                    continue;
                }
                captured = Some(data);
                break;
            }
            let Some(data) = captured else {
                println!("[feature-capture] report 0x{id:02x} unavailable after 3 attempts");
                continue;
            };
            fs::write(output_dir.join(format!("0x{id:02x}.bin")), &data)?;
            fs::write(
                output_dir.join(format!("0x{id:02x}.hex")),
                format!("{}\n", hex_all(&data)),
            )?;
            println!("[feature-capture] saved report 0x{id:02x} size={size}");
        }
        Ok(())
    }

    fn hidiocgfeature(size: usize) -> libc::c_ulong {
        const IOC_READ: libc::c_ulong = 2;
        const IOC_WRITE: libc::c_ulong = 1;
        ((IOC_READ | IOC_WRITE) << 30)
            | ((b'H' as libc::c_ulong) << 8)
            | 0x07
            | ((size as libc::c_ulong) << 16)
    }

    fn parse_command<I>(args: I) -> Result<Option<Command>, AnyError>
    where
        I: IntoIterator<Item = String>,
    {
        let mut args = args.into_iter().peekable();
        let mut bridge = false;
        if args.peek().is_some_and(|arg| arg == "capture-features") {
            let _ = args.next();
            let mut hidraw = None;
            let mut output_dir = None;
            while let Some(arg) = args.next() {
                match arg.as_str() {
                    "--hidraw" => hidraw = Some(PathBuf::from(next_value(&mut args, "--hidraw")?)),
                    "--output-dir" => {
                        output_dir = Some(PathBuf::from(next_value(&mut args, "--output-dir")?))
                    }
                    _ => return Err(io::Error::other(format!("unknown capture-features argument {arg}")).into()),
                }
            }
            return Ok(Some(Command::CaptureFeatures {
                hidraw: hidraw.ok_or_else(|| io::Error::other("--hidraw is required"))?,
                output_dir: output_dir.ok_or_else(|| io::Error::other("--output-dir is required"))?,
            }));
        }
        if args.peek().is_some_and(|arg| arg == "bridge") {
            let _ = args.next();
            bridge = true;
        }
        let mut config = Config {
            descriptor: None,
            name: None,
            version: None,
            vid: SONY_VID,
            pid: DS4_PID,
            interval_ms: 8,
            capture_root: PathBuf::from("captures"),
            bridge,
            output_mode: if bridge {
                OutputMode::Both
            } else {
                OutputMode::UhidOnly
            },
            feature_root: None,
            raw_capture_dir: None,
            status_file: None,
            uinput_version: None,
        };
        while let Some(arg) = args.next() {
            if arg == "-h" || arg == "--help" {
                return Ok(None);
            }
            match arg.as_str() {
                "--descriptor" => config.descriptor = Some(PathBuf::from(next_value(&mut args, &arg)?)),
                "--name" => config.name = Some(next_value(&mut args, &arg)?),
                "--version" => config.version = Some(parse_hex_or_dec(&next_value(&mut args, &arg)?)?),
                "--vid" => config.vid = parse_hex_or_dec(&next_value(&mut args, &arg)?)?,
                "--pid" => config.pid = parse_hex_or_dec(&next_value(&mut args, &arg)?)?,
                "--interval-ms" => config.interval_ms = next_value(&mut args, &arg)?.parse()?,
                "--capture-root" => config.capture_root = PathBuf::from(next_value(&mut args, &arg)?),
                "--feature-root" => config.feature_root = Some(PathBuf::from(next_value(&mut args, &arg)?)),
                "--raw-capture-dir" => {
                    config.raw_capture_dir = Some(PathBuf::from(next_value(&mut args, &arg)?))
                }
                "--status-file" => {
                    config.status_file = Some(PathBuf::from(next_value(&mut args, &arg)?))
                }
                "--uinput-version" => {
                    config.uinput_version = Some(parse_hex_or_dec(&next_value(&mut args, &arg)?)?)
                }
                "--output-mode" => {
                    config.output_mode = match next_value(&mut args, &arg)?.as_str() {
                        "both" => OutputMode::Both,
                        "uhid" | "uhid-only" => OutputMode::UhidOnly,
                        value => {
                            return Err(io::Error::other(format!(
                                "invalid --output-mode {value}; expected both or uhid"
                            ))
                            .into())
                        }
                    }
                }
                _ => return Err(io::Error::other(format!("unknown argument {arg}")).into()),
            }
        }
        Ok(Some(Command::Run(config)))
    }

    fn next_value<I>(args: &mut std::iter::Peekable<I>, option: &str) -> Result<String, AnyError>
    where
        I: Iterator<Item = String>,
    {
        args.next()
            .ok_or_else(|| io::Error::other(format!("missing value for {option}")).into())
    }

    fn synthetic_feature_report(id: u8, size: usize) -> Vec<u8> {
        let mut data = vec![0_u8; size];
        data[0] = id;
        match id {
            0x02 => {
                for offset in [7, 11, 15] {
                    write_i16_le(&mut data, offset, 1000);
                }
                for offset in [9, 13, 17] {
                    write_i16_le(&mut data, offset, -1000);
                }
                write_i16_le(&mut data, 19, 1000);
                write_i16_le(&mut data, 21, 1000);
                for offset in [23, 27, 31] {
                    write_i16_le(&mut data, offset, 8192);
                }
                for offset in [25, 29, 33] {
                    write_i16_le(&mut data, offset, -8192);
                }
            }
            0x12 => rewrite_pairing_mac(&mut data),
            0x81 => {}
            0xa3 => {
                let label = b"ds4-bt-usb-probe synthetic firmware";
                let len = label.len().min(data.len().saturating_sub(1));
                data[1..1 + len].copy_from_slice(&label[..len]);
            }
            _ => {}
        }
        data
    }

    fn valid_feature_report(data: &[u8], id: u8, size: usize) -> bool {
        data.len() == size && data.first() == Some(&id)
    }

    fn rewrite_pairing_mac(report: &mut [u8]) {
        if report.len() >= 7 {
            report[1..7].copy_from_slice(&[0x02, 0x54, 0x4c, 0x09, 0xcc, 0x02]);
        }
    }

    fn write_i16_le(data: &mut [u8], offset: usize, value: i16) {
        if let Some(target) = data.get_mut(offset..offset + 2) {
            target.copy_from_slice(&value.to_le_bytes());
        }
    }

    fn translate_bluetooth_report(input: &[u8]) -> Result<TranslatedInput, &'static str> {
        let mut output = neutral_usb_ds4_report();
        match input.first().copied() {
            Some(0x11) if input.len() == 78 => {
                output[1..10].copy_from_slice(&input[3..12]);
            }
            Some(0x01) if input.len() == 10 => {
                output[1..10].copy_from_slice(&input[1..10]);
            }
            Some(0x11) => return Err("Bluetooth 0x11 report is not exactly 78 bytes"),
            Some(0x01) => return Err("minimal Bluetooth 0x01 report is not exactly 10 bytes"),
            Some(_) => return Err("unsupported Bluetooth report id"),
            None => return Err("empty Bluetooth report"),
        }
        Ok(TranslatedInput {
            gamepad: gamepad_state_from_usb_report(&output),
            usb_report: output,
        })
    }

    fn gamepad_state_from_usb_report(report: &[u8; 64]) -> GamepadState {
        let buttons1 = report[5];
        let buttons2 = report[6];
        let buttons3 = report[7];
        let (dpad_x, dpad_y) = dpad_axes(buttons1 & 0x0f);
        GamepadState {
            lx: report[1],
            ly: report[2],
            rx: report[3],
            ry: report[4],
            l2: report[8],
            r2: report[9],
            dpad_x,
            dpad_y,
            square: buttons1 & 0x10 != 0,
            cross: buttons1 & 0x20 != 0,
            circle: buttons1 & 0x40 != 0,
            triangle: buttons1 & 0x80 != 0,
            l1: buttons2 & 0x01 != 0,
            r1: buttons2 & 0x02 != 0,
            l2_button: buttons2 & 0x04 != 0,
            r2_button: buttons2 & 0x08 != 0,
            share: buttons2 & 0x10 != 0,
            options: buttons2 & 0x20 != 0,
            thumb_l: buttons2 & 0x40 != 0,
            thumb_r: buttons2 & 0x80 != 0,
            ps: buttons3 & 0x01 != 0,
        }
    }

    fn dpad_axes(value: u8) -> (i32, i32) {
        match value {
            0 => (0, -1),
            1 => (1, -1),
            2 => (1, 0),
            3 => (1, 1),
            4 => (0, 1),
            5 => (-1, 1),
            6 => (-1, 0),
            7 => (-1, -1),
            _ => (0, 0),
        }
    }

    fn gamepad_events(state: &GamepadState) -> Vec<InputEvent> {
        let mut events = vec![
            input_event(EV_ABS, ABS_X, i32::from(state.lx)),
            input_event(EV_ABS, ABS_Y, i32::from(state.ly)),
            input_event(EV_ABS, ABS_RX, i32::from(state.rx)),
            input_event(EV_ABS, ABS_RY, i32::from(state.ry)),
            input_event(EV_ABS, ABS_Z, i32::from(state.l2)),
            input_event(EV_ABS, ABS_RZ, i32::from(state.r2)),
            input_event(EV_ABS, ABS_HAT0X, state.dpad_x),
            input_event(EV_ABS, ABS_HAT0Y, state.dpad_y),
        ];
        for (code, pressed) in [
            (BTN_WEST, state.square),
            (BTN_SOUTH, state.cross),
            (BTN_EAST, state.circle),
            (BTN_NORTH, state.triangle),
            (BTN_TL, state.l1),
            (BTN_TR, state.r1),
            (BTN_TL2, state.l2_button),
            (BTN_TR2, state.r2_button),
            (BTN_SELECT, state.share),
            (BTN_START, state.options),
            (BTN_MODE, state.ps),
            (BTN_THUMBL, state.thumb_l),
            (BTN_THUMBR, state.thumb_r),
        ] {
            events.push(input_event(EV_KEY, code, if pressed { 1 } else { 0 }));
        }
        events.push(input_event(EV_SYN, SYN_REPORT, 0));
        events
    }

    fn input_event(event_type: u16, code: u16, value: i32) -> InputEvent {
        InputEvent {
            time: libc::timeval {
                tv_sec: 0,
                tv_usec: 0,
            },
            event_type,
            code,
            value,
        }
    }

    fn save_raw_sample(dir: &Path, index: u32, data: &[u8]) -> io::Result<()> {
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis();
        fs::write(dir.join(format!("{now}-{index:02}.bin")), data)?;
        fs::write(
            dir.join(format!("{now}-{index:02}.hex")),
            format!("{}\n", hex_all(data)),
        )
    }

    fn discover_bluetooth_hidraw(vid: u32, pid: u32) -> Option<PathBuf> {
        discover_hidraw_by_id(0x0005, vid, pid, false).into_iter().next()
    }

    fn discover_virtual_devices(vid: u32, pid: u32) -> (Vec<PathBuf>, Vec<String>) {
        let hidraw = discover_hidraw_by_id(BUS_USB, vid, pid, true);
        for path in &hidraw {
            println!("[probe] matching virtual hidraw device: {}", path.display());
        }
        let input = discover_input_events(vid, pid);
        for path in &input {
            println!("[probe] matching virtual input device: {path}");
        }
        (hidraw, input)
    }

    fn discover_hidraw_by_id(bus: u16, vid: u32, pid: u32, require_probe_phys: bool) -> Vec<PathBuf> {
        let mut matches = Vec::new();
        let Ok(entries) = fs::read_dir("/sys/class/hidraw") else {
            return matches;
        };
        let needle = format!("{bus:04X}:{vid:08X}:{pid:08X}");
        for entry in entries.flatten() {
            let uevent = read_trimmed(entry.path().join("device/uevent")).unwrap_or_default();
            if uevent.to_ascii_uppercase().contains(&needle)
                && (!require_probe_phys || uevent.contains("usb-ds4-bt-usb-probe"))
            {
                matches.push(PathBuf::from("/dev").join(entry.file_name()));
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
            let name = entry.file_name().to_string_lossy().into_owned();
            if !name.starts_with("event") {
                continue;
            }
            let device = entry.path().join("device");
            if read_sysfs_hex(device.join("id/bustype")) == Some(u32::from(BUS_USB))
                && read_sysfs_hex(device.join("id/vendor")) == Some(vid)
                && read_sysfs_hex(device.join("id/product")) == Some(pid)
                && read_trimmed(device.join("phys"))
                    .is_some_and(|phys| phys.contains("usb-ds4-bt-usb-probe"))
            {
                matches.push(format!("/dev/input/{name}"));
            }
        }
        matches
    }

    fn choose_descriptor(config: &Config) -> Result<DescriptorChoice, AnyError> {
        if let Some(path) = &config.descriptor {
            return read_descriptor(path, format!("explicit {}", path.display()), false);
        }
        if let Some(path) = latest_usb_descriptor(&config.capture_root) {
            return read_descriptor(&path, format!("latest USB capture {}", path.display()), false);
        }
        Ok(DescriptorChoice {
            bytes: fallback_ds4_usb_descriptor().to_vec(),
            label: "built-in fallback DS4-like USB descriptor".to_string(),
            is_fallback: true,
        })
    }

    fn read_descriptor(path: &Path, label: String, is_fallback: bool) -> Result<DescriptorChoice, AnyError> {
        let bytes = fs::read(path)?;
        if bytes.is_empty() || bytes.len() > HID_MAX_DESCRIPTOR_SIZE {
            return Err(io::Error::other(format!("invalid descriptor {}", path.display())).into());
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
        CaptureDefaults {
            uhid_version: read_trimmed(usb_dir.join("identity/usb_version.txt"))
                .and_then(|value| parse_hex_or_dec(&value).ok()),
            input_version: read_trimmed(usb_dir.join("identity/input_version.txt"))
                .and_then(|value| parse_hex_or_dec(&value).ok()),
        }
    }

    fn choose_uhid_version(explicit: Option<u32>, captured_usb: Option<u32>) -> u32 {
        explicit.or(captured_usb).unwrap_or(0x0100)
    }

    fn choose_uinput_version(explicit: Option<u32>, captured_input: Option<u32>) -> u32 {
        explicit.or(captured_input).unwrap_or(0x8111)
    }

    fn version_source(explicit: Option<u32>, captured: Option<u32>) -> &'static str {
        if explicit.is_some() {
            "explicit CLI"
        } else if captured.is_some() {
            "captured real USB"
        } else {
            "built-in fallback"
        }
    }

    fn latest_usb_descriptor(capture_root: &Path) -> Option<PathBuf> {
        latest_usb_capture_dir(capture_root).and_then(|usb| {
            ["report_descriptor.bin", "hidraw/report_descriptor.bin"]
                .into_iter()
                .map(|relative| usb.join(relative))
                .find(|path| path.is_file())
        })
    }

    fn latest_usb_capture_dir(capture_root: &Path) -> Option<PathBuf> {
        let mut dirs = fs::read_dir(capture_root)
            .ok()?
            .flatten()
            .map(|entry| entry.path().join("usb"))
            .filter(|path| path.is_dir())
            .collect::<Vec<_>>();
        dirs.sort();
        dirs.pop()
    }

    fn neutral_usb_ds4_report() -> [u8; 64] {
        let mut report = [0_u8; 64];
        report[0] = 0x01;
        report[1..5].fill(0x80);
        report[5] = 0x08;
        report
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

    #[allow(clippy::fn_to_numeric_cast)]
    fn install_signal_handlers() {
        // SAFETY: the handler only updates an AtomicBool.
        unsafe {
            let _ = libc::signal(
                libc::SIGINT,
                handle_shutdown_signal as libc::sighandler_t,
            );
            let _ = libc::signal(
                libc::SIGTERM,
                handle_shutdown_signal as libc::sighandler_t,
            );
        }
    }

    fn update_state(state: &Arc<Mutex<InitState>>, update: impl FnOnce(&mut InitState)) {
        if let Ok(mut state) = state.lock() {
            update(&mut state);
        }
    }

    fn write_uhid_event(file: &mut File, event: &[u8]) -> io::Result<()> {
        loop {
            match file.write(event) {
                Ok(size) if size == event.len() => return Ok(()),
                Ok(size) => return Err(io::Error::other(format!("short UHID write: {size}/{}", event.len()))),
                Err(err) if err.kind() == io::ErrorKind::Interrupted => {}
                Err(err) => return Err(err),
            }
        }
    }

    fn wait_for_uinput_event_node(sysname: &str, timeout: Duration) -> Option<String> {
        let directory = PathBuf::from("/sys/devices/virtual/input").join(sysname);
        let deadline = Instant::now() + timeout;
        while Instant::now() < deadline {
            if let Ok(entries) = fs::read_dir(&directory) {
                for entry in entries.flatten() {
                    let name = entry.file_name().to_string_lossy().into_owned();
                    if name.starts_with("event") {
                        return Some(format!("/dev/input/{name}"));
                    }
                }
            }
            thread::sleep(Duration::from_millis(100));
        }
        None
    }

    fn ioc(direction: libc::c_ulong, ioctl_type: u8, number: u8, size: usize) -> libc::c_ulong {
        (direction << 30)
            | ((ioctl_type as libc::c_ulong) << 8)
            | libc::c_ulong::from(number)
            | ((size as libc::c_ulong) << 16)
    }

    fn ioc_none(ioctl_type: u8, number: u8) -> libc::c_ulong {
        ioc(0, ioctl_type, number, 0)
    }

    fn ioc_write(ioctl_type: u8, number: u8, size: usize) -> libc::c_ulong {
        ioc(1, ioctl_type, number, size)
    }

    fn ioc_read(ioctl_type: u8, number: u8, size: usize) -> libc::c_ulong {
        ioc(2, ioctl_type, number, size)
    }

    fn ioctl_none(fd: libc::c_int, request: libc::c_ulong) -> io::Result<()> {
        let result = unsafe { libc::ioctl(fd, request) };
        if result < 0 {
            Err(io::Error::last_os_error())
        } else {
            Ok(())
        }
    }

    fn ioctl_int(fd: libc::c_int, request: libc::c_ulong, value: libc::c_int) -> io::Result<()> {
        let result = unsafe { libc::ioctl(fd, request, value) };
        if result < 0 {
            Err(io::Error::last_os_error())
        } else {
            Ok(())
        }
    }

    fn ioctl_ptr<T>(fd: libc::c_int, request: libc::c_ulong, value: &T) -> io::Result<()> {
        let result = unsafe { libc::ioctl(fd, request, value as *const T) };
        if result < 0 {
            Err(io::Error::last_os_error())
        } else {
            Ok(())
        }
    }

    fn write_struct<T>(file: &mut File, value: &T) -> io::Result<()> {
        let bytes = unsafe {
            std::slice::from_raw_parts((value as *const T).cast::<u8>(), size_of::<T>())
        };
        file.write_all(bytes)
    }

    fn write_fixed_cstr(target: &mut [u8], value: &str) {
        target.fill(0);
        let len = value.len().min(target.len().saturating_sub(1));
        target[..len].copy_from_slice(&value.as_bytes()[..len]);
    }

    fn write_u16(buf: &mut [u8], offset: usize, value: u16) {
        buf[offset..offset + 2].copy_from_slice(&value.to_ne_bytes());
    }

    fn write_u32(buf: &mut [u8], offset: usize, value: u32) {
        buf[offset..offset + 4].copy_from_slice(&value.to_ne_bytes());
    }

    fn read_u16(buf: &[u8], offset: usize) -> Option<u16> {
        let data = buf.get(offset..offset + 2)?;
        Some(u16::from_ne_bytes([data[0], data[1]]))
    }

    fn read_u32(buf: &[u8], offset: usize) -> Option<u32> {
        let data = buf.get(offset..offset + 4)?;
        Some(u32::from_ne_bytes([data[0], data[1], data[2], data[3]]))
    }

    fn parse_hex_or_dec(value: &str) -> Result<u32, AnyError> {
        let raw = value.trim();
        let (digits, radix) = if let Some(hex) = raw.strip_prefix("0x") {
            (hex, 16)
        } else if raw.chars().any(|ch| ch.is_ascii_alphabetic()) || raw.starts_with('0') {
            (raw, 16)
        } else {
            (raw, 10)
        };
        Ok(u32::from_str_radix(digits, radix)?)
    }

    fn read_trimmed(path: impl AsRef<Path>) -> Option<String> {
        fs::read_to_string(path).ok().map(|s| s.trim().to_string()).filter(|s| !s.is_empty())
    }

    fn read_sysfs_hex(path: impl AsRef<Path>) -> Option<u32> {
        u32::from_str_radix(read_trimmed(path)?.trim_start_matches("0x"), 16).ok()
    }

    fn hex_prefix(data: &[u8]) -> String {
        hex_all(&data[..data.len().min(24)])
    }

    fn hex_all(data: &[u8]) -> String {
        data.iter().map(|byte| format!("{byte:02x}")).collect::<Vec<_>>().join(" ")
    }

    fn print_help() {
        println!(
            "ds4-bt-usb-probe 0.4

Commands:
  ds4-bt-usb-probe [options]
  ds4-bt-usb-probe bridge --output-mode <both|uhid> --status-file <path>
  ds4-bt-usb-probe capture-features --hidraw <path> --output-dir <dir>
"
        );
    }

    #[cfg(test)]
    mod tests {
        use super::*;

        #[test]
        fn synthetic_features_have_expected_ids_and_sizes() {
            for (id, size) in DS4_FEATURES {
                let report = synthetic_feature_report(id, size);
                assert_eq!(report.len(), size);
                assert_eq!(report[0], id);
            }
        }

        #[test]
        fn synthetic_calibration_has_nonzero_divisors() {
            let report = synthetic_feature_report(0x02, 37);
            let value = |offset| i16::from_le_bytes([report[offset], report[offset + 1]]);
            assert_ne!(value(7), value(9));
            assert_ne!(value(11), value(13));
            assert_ne!(value(15), value(17));
            assert_ne!(value(19) + value(21), 0);
            assert_ne!(value(23), value(25));
            assert_ne!(value(27), value(29));
            assert_ne!(value(31), value(33));
        }

        #[test]
        fn captured_feature_validation_checks_id_and_size() {
            assert!(valid_feature_report(&synthetic_feature_report(0x02, 37), 0x02, 37));
            assert!(!valid_feature_report(&synthetic_feature_report(0x02, 37), 0x12, 37));
            assert!(!valid_feature_report(&synthetic_feature_report(0x02, 37), 0x02, 16));
        }

        #[test]
        fn get_report_reply_contains_payload_and_size() {
            for (id, size) in DS4_FEATURES {
                let payload = synthetic_feature_report(id, size);
                let event = build_get_report_reply(42, 0, &payload);
                assert_eq!(read_u32(&event, 0), Some(UHID_GET_REPORT_REPLY));
                assert_eq!(read_u32(&event, EVENT_TYPE_LEN), Some(42));
                assert_eq!(read_u16(&event, EVENT_TYPE_LEN + 4), Some(0));
                assert_eq!(read_u16(&event, EVENT_TYPE_LEN + 6), Some(size as u16));
                assert_eq!(&event[EVENT_TYPE_LEN + 8..], payload.as_slice());
            }
        }

        #[test]
        fn bridge_pairing_mac_is_distinct_and_stable() {
            let mut report = vec![0x12; 16];
            let physical_mac = report[1..7].to_vec();
            rewrite_pairing_mac(&mut report);
            assert_eq!(&report[1..7], &[0x02, 0x54, 0x4c, 0x09, 0xcc, 0x02]);
            assert_ne!(&report[1..7], physical_mac.as_slice());
        }

        #[test]
        fn full_bluetooth_report_maps_common_controls() {
            let mut bt = [0_u8; 78];
            bt[0] = 0x11;
            for (index, byte) in bt[3..35].iter_mut().enumerate() {
                *byte = index as u8;
            }
            let translated = translate_bluetooth_report(&bt).unwrap();
            assert_eq!(translated.usb_report[0], 0x01);
            assert_eq!(&translated.usb_report[1..10], &bt[3..12]);
            assert_eq!(
                &translated.usb_report[10..],
                &neutral_usb_ds4_report()[10..]
            );
        }

        #[test]
        fn minimal_bluetooth_report_maps_basic_controls() {
            let bt = [0x01, 1, 2, 3, 4, 5, 6, 7, 8, 9];
            let translated = translate_bluetooth_report(&bt).unwrap();
            assert_eq!(&translated.usb_report[..10], &bt);
        }

        #[test]
        fn unexpected_report_is_rejected() {
            assert!(translate_bluetooth_report(&[0x99, 0]).is_err());
            assert!(translate_bluetooth_report(&[0x11; 35]).is_err());
            assert!(translate_bluetooth_report(&[0x01; 11]).is_err());
        }

        #[test]
        fn version_precedence_matches_usb_and_input_targets() {
            assert_eq!(choose_uhid_version(Some(0x0200), Some(0x0100)), 0x0200);
            assert_eq!(choose_uhid_version(None, Some(0x0100)), 0x0100);
            assert_eq!(choose_uhid_version(None, None), 0x0100);
            assert_eq!(choose_uinput_version(Some(0x1234), Some(0x8111)), 0x1234);
            assert_eq!(choose_uinput_version(None, Some(0x8111)), 0x8111);
            assert_eq!(choose_uinput_version(None, None), 0x8111);
            assert_eq!(version_source(Some(1), Some(2)), "explicit CLI");
            assert_eq!(version_source(None, Some(2)), "captured real USB");
            assert_eq!(version_source(None, None), "built-in fallback");
        }

        #[test]
        fn parses_descriptor_feature_sizes_and_builds_safe_fallback() {
            let descriptor = [0x85, 0x90, 0x75, 0x08, 0x95, 0x04, 0xb1, 0x02];
            let sizes = feature_report_sizes(&descriptor);
            assert_eq!(sizes.get(&0x90), Some(&5));
            let reports =
                FeatureReports::load(None, false, &descriptor, &StatusTracker::new(None));
            assert_eq!(reports.reports.get(&0x90).map(|data| data.len()), Some(5));
            assert_eq!(reports.reports.get(&0x90).map(|data| data[0]), Some(0x90));
            assert_eq!(reports.reports.get(&0x81).map(|data| data.len()), Some(7));
        }

        #[test]
        fn unknown_feature_without_a_declared_safe_size_has_no_fallback() {
            let reports = FeatureReports::load(
                None,
                false,
                fallback_ds4_usb_descriptor(),
                &StatusTracker::new(None),
            );
            assert!(!reports.reports.contains_key(&0xfe));
        }

        #[test]
        fn gamepad_state_maps_buttons_dpad_and_uinput_events() {
            let mut usb = neutral_usb_ds4_report();
            usb[5] = 0x20 | 0x01;
            usb[6] = 0x01 | 0x10 | 0x40;
            usb[7] = 0x01;
            usb[8] = 42;
            let state = gamepad_state_from_usb_report(&usb);
            assert!(state.cross);
            assert!(state.l1);
            assert!(state.share);
            assert!(state.thumb_l);
            assert!(state.ps);
            assert_eq!((state.dpad_x, state.dpad_y), (1, -1));
            assert_eq!(state.l2, 42);
            let events = gamepad_events(&state);
            assert!(events.iter().any(|event| {
                event.event_type == EV_KEY && event.code == BTN_SOUTH && event.value == 1
            }));
            assert_eq!(events.last().map(|event| event.event_type), Some(EV_SYN));
        }

        #[test]
        fn uinput_struct_layouts_match_linux_uapi() {
            assert_eq!(size_of::<InputId>(), 8);
            assert_eq!(size_of::<UinputSetup>(), 92);
            assert_eq!(size_of::<InputAbsInfo>(), 24);
            assert_eq!(size_of::<UinputAbsSetup>(), 28);
            assert_eq!(size_of::<InputEvent>(), 24);
        }

        #[test]
        fn status_counter_accumulates() {
            let status = StatusTracker::new(None);
            status.set("count", "0");
            status.increment("count", 2);
            status.increment("count", 3);
            let values = status.values.lock().unwrap();
            assert_eq!(values.get("count").map(String::as_str), Some("5"));
        }
    }
}
