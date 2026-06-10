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
    use std::collections::HashMap;
    use std::env;
    use std::error::Error;
    use std::ffi::c_int;
    use std::fs::{self, File, OpenOptions};
    use std::io::{self, Read, Write};
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
    const DS4_FEATURES: [(u8, usize); 3] = [(0x02, 37), (0x12, 16), (0xa3, 49)];

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
        feature_root: Option<PathBuf>,
        raw_capture_dir: Option<PathBuf>,
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
        let name = config
            .name
            .clone()
            .or(capture_defaults.name)
            .unwrap_or_else(|| "Sony Interactive Entertainment Wireless Controller".to_string());
        let version = config.version.or(capture_defaults.version).unwrap_or(0x0100);
        let features = Arc::new(FeatureReports::load(config.feature_root.as_deref(), config.bridge));
        let state = Arc::new(Mutex::new(InitState::default()));

        println!("[probe] opening /dev/uhid");
        let mut device = UhidDevice::open().map_err(|err| {
            io::Error::new(
                err.kind(),
                format!("could not open /dev/uhid: {err}. Run this as root on the Bazzite host"),
            )
        })?;
        println!("[probe] /dev/uhid opened");
        spawn_event_reader(device.file.try_clone()?, features, Arc::clone(&state));

        if descriptor.is_fallback {
            println!("[probe] WARNING: using built-in fallback DS4-like USB descriptor");
        }
        println!("[probe] descriptor source: {}", descriptor.label);
        println!(
            "[probe] virtual identity: bus=USB/0x{BUS_USB:04x} vid=0x{:04x} pid=0x{:04x} version=0x{version:04x} name=\"{name}\"",
            config.vid, config.pid
        );
        device.create(&name, config.vid, config.pid, version, &descriptor.bytes)?;
        println!("[probe] UHID_CREATE2 sent");

        let report = neutral_usb_ds4_report();
        device.send_input_report(&report)?;
        wait_for_virtual_device(&mut device, &state, config.vid, config.pid, &report)?;
        println!("[probe] READY: virtual DS4 initialized");

        if config.bridge {
            run_bridge(&mut device, &config, report)
        } else {
            run_neutral_loop(&mut device, &config, report)
        }
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
    ) -> Result<(), AnyError> {
        let hidraw = discover_bluetooth_hidraw(config.vid, config.pid).ok_or_else(|| {
            io::Error::other("no physical Bluetooth hidraw device found for BUS_BLUETOOTH 054c:09cc")
        })?;
        println!("[bridge] physical Bluetooth hidraw: {}", hidraw.display());
        let mut input = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NONBLOCK)
            .open(&hidraw)
            .map_err(|err| io::Error::new(err.kind(), format!("could not open {}: {err}", hidraw.display())))?;
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
                    last_keepalive = Instant::now();
                }
                continue;
            }
            match input.read(&mut buffer) {
                Ok(0) => {}
                Ok(size) => match translate_bluetooth_report(&buffer[..size]) {
                    Ok(report) => {
                        device.send_input_report(&report)?;
                        forwarded += 1;
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
                },
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
            let (virtual_hidraw, virtual_input) = discover_virtual_devices(vid, pid);
            update_state(state, |s| {
                s.virtual_hidraw = virtual_hidraw;
                s.virtual_input = virtual_input;
            });
            if lifecycle_ready && virtual_hidraw + virtual_input > 0 {
                println!(
                    "[probe] initialization lifecycle ready; opened={opened} known feature replies={known_feature_replies} virtual_hidraw={virtual_hidraw} virtual_input={virtual_input}"
                );
                return Ok(());
            }
            thread::sleep(Duration::from_millis(200));
        }
        Err(io::Error::other("virtual DS4 did not appear as hidraw/input device within 10 seconds").into())
    }

    impl FeatureReports {
        fn load(root: Option<&Path>, bridge: bool) -> Self {
            let mut reports = HashMap::new();
            for (id, size) in DS4_FEATURES {
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
                } else {
                    println!("[feature] report 0x{id:02x} source={source} size={size}");
                }
                let _ = reports.insert(id, report);
            }
            Self { reports }
        }
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

    fn spawn_event_reader(
        mut file: File,
        features: Arc<FeatureReports>,
        state: Arc<Mutex<InitState>>,
    ) {
        let _ = thread::spawn(move || {
            let mut event = vec![0_u8; EVENT_TYPE_LEN + CREATE2_LEN];
            loop {
                event.fill(0);
                match file.read(&mut event) {
                    Ok(0) => break,
                    Ok(n) if n >= EVENT_TYPE_LEN => {
                        handle_uhid_event(&mut file, &event[..n], &features, &state)
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
        for (id, size) in DS4_FEATURES {
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
            vid: 0x054c,
            pid: 0x09cc,
            interval_ms: 8,
            capture_root: PathBuf::from("captures"),
            bridge,
            feature_root: None,
            raw_capture_dir: None,
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

    fn translate_bluetooth_report(input: &[u8]) -> Result<[u8; 64], &'static str> {
        let mut output = neutral_usb_ds4_report();
        match input.first().copied() {
            Some(0x11) if input.len() == 78 => {
                output[1..10].copy_from_slice(&input[3..12]);
                Ok(output)
            }
            Some(0x01) if input.len() == 10 => {
                output[1..10].copy_from_slice(&input[1..10]);
                Ok(output)
            }
            Some(0x11) => Err("Bluetooth 0x11 report is not exactly 78 bytes"),
            Some(0x01) => Err("minimal Bluetooth 0x01 report is not exactly 10 bytes"),
            Some(_) => Err("unsupported Bluetooth report id"),
            None => Err("empty Bluetooth report"),
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

    fn discover_virtual_devices(vid: u32, pid: u32) -> (usize, usize) {
        let hidraw = discover_hidraw_by_id(BUS_USB, vid, pid, true);
        for path in &hidraw {
            println!("[probe] matching virtual hidraw device: {}", path.display());
        }
        let input = discover_input_events(vid, pid);
        for path in &input {
            println!("[probe] matching virtual input device: {path}");
        }
        (hidraw.len(), input.len())
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
            name: read_trimmed(usb_dir.join("identity/name.txt")),
            version: read_trimmed(usb_dir.join("identity/version.txt"))
                .and_then(|value| parse_hex_or_dec(&value).ok()),
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
            "ds4-bt-usb-probe 0.2

Commands:
  ds4-bt-usb-probe [options]
  ds4-bt-usb-probe bridge --feature-root <dir> --raw-capture-dir <dir>
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
            let usb = translate_bluetooth_report(&bt).unwrap();
            assert_eq!(usb[0], 0x01);
            assert_eq!(&usb[1..10], &bt[3..12]);
            assert_eq!(&usb[10..], &neutral_usb_ds4_report()[10..]);
        }

        #[test]
        fn minimal_bluetooth_report_maps_basic_controls() {
            let bt = [0x01, 1, 2, 3, 4, 5, 6, 7, 8, 9];
            let usb = translate_bluetooth_report(&bt).unwrap();
            assert_eq!(&usb[..10], &bt);
        }

        #[test]
        fn unexpected_report_is_rejected() {
            assert!(translate_bluetooth_report(&[0x99, 0]).is_err());
            assert!(translate_bluetooth_report(&[0x11; 35]).is_err());
            assert!(translate_bluetooth_report(&[0x01; 11]).is_err());
        }
    }
}
