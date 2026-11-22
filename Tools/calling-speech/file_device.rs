// Audio device for the test reference peer. This file is included only in a private
// build of RingRTC's existing audio_device_module.rs. Its audio transport, codecs,
// echo processing, jitter buffer and network stack are the pinned implementations.
fn speech_fixture() -> Option<(std::path::PathBuf, bool)> {
    // The signed hardware test hosts RingRTC in the service with a bundled phrase.
    // Discard everything RingRTC hears from the live microphone.
    let executable = std::env::current_exe().ok()?;
    let resources = executable.parent()?.parent()?.join("Resources/ReferenceSpeech");
    if resources.join("native-input.pcm").is_file() {
        return Some((resources, false));
    }
    std::env::var_os("SEREIN_SPEECH_DIR").map(|directory| (directory.into(), true))
}

fn spawn_file_device(
    started: mpsc::Sender<Option<String>>,
    events: mpsc::Receiver<Event>,
    delays: mpsc::Sender<anyhow::Result<u16>>,
    inputs: Arc<Mutex<AudioDeviceList>>,
    outputs: Arc<Mutex<AudioDeviceList>>,
    directory: std::path::PathBuf,
    save_playout: bool,
) -> JoinHandle<()> {
    use std::io::Write;
    use std::time::Instant;
    thread::spawn(move || {
        let input = std::fs::read(directory.join("native-input.pcm")).expect("read native speech");
        assert!(input.len() >= 960 && input.len() <= 48_000 * 2 * 10 && input.len() % 2 == 0);
        let source: Vec<i16> = input.chunks_exact(2).map(|p| i16::from_le_bytes([p[0], p[1]])).collect();
        let mut output: Box<dyn Write> = if save_playout {
            Box::new(std::fs::File::create(directory.join("native-output.pcm")).expect("create PCM sink"))
        } else {
            Box::new(std::io::sink())
        };
        fn device(name: &str) -> AudioDevice {
            AudioDevice { name: name.into(), unique_id: name.into() }
        }
        let mic = device("Serein file microphone");
        let speaker = device("Serein file speaker");
        inputs.lock().unwrap().list.push(mic.clone());
        outputs.lock().unwrap().list.push(speaker.clone());
        if started.send(Some("Serein speech fixture".into())).is_err() { return }
        let mut callback = None;
        let mut observer: Option<Box<dyn AudioDeviceObserver>> = None;
        let mut playback = false;
        let mut record = false;
        let mut cursor = 0;
        let mut written = 0;
        let seconds = std::env::var("SEREIN_SPEECH_SECONDS")
            .ok().and_then(|s| s.parse::<usize>().ok()).unwrap_or(15).clamp(7, 600);
        let output_limit = (seconds + 15) * 48_000;
        let period = Duration::from_millis(10);
        let mut next = Instant::now() + period;
        loop {
            match events.recv_timeout(next.saturating_duration_since(Instant::now())) {
                Ok(Event::Terminate) | Err(mpsc::RecvTimeoutError::Disconnected) => break,
                Ok(Event::SetCallbackIndirect(value)) => callback = Some(value),
                Ok(Event::RegisterAudioObserver(value)) => observer = Some(value),
                Ok(Event::StartRecording) => {
                    record = true;
                    if let Some(obs) = &observer { obs.settle_start_recording_via_callback(true, Some(mic.clone())) }
                }
                Ok(Event::StartPlayout) => {
                    playback = true;
                    if let Some(obs) = &observer { obs.settle_start_playback_via_callback(true, Some(speaker.clone())) }
                }
                Ok(Event::StopRecording) => record = false,
                Ok(Event::StopPlayout) => playback = false,
                Ok(Event::PlayoutDelay) => { let _ = delays.send(Ok(10)); }
                Ok(Event::SetPlayoutDevice { request_id, .. }) => {
                    if let Some(obs) = &observer { obs.settle_promise(true, Some(speaker.clone()), request_id) }
                }
                Ok(Event::SetRecordingDevice { request_id, .. }
                    | Event::WarmupRecording(request_id) | Event::SetInputProcessing(_, request_id)) => {
                    if let Some(obs) = &observer { obs.settle_promise(true, Some(mic.clone()), request_id) }
                }
                Ok(Event::RefreshCache(_) | Event::InitRecording | Event::InitPlayout)
                    | Err(mpsc::RecvTimeoutError::Timeout) => {}
            }
            let now = Instant::now();
            if now < next { continue }
            next += period;
            if next < now { next = now + period }
            let Some(transport) = callback else { continue };
            if playback && (!save_playout || written < output_limit) {
                let samples = Worker::need_more_play_data(transport, WEBRTC_WINDOW, 1, SAMPLE_FREQUENCY);
                if save_playout && samples.success == 0 {
                    let bytes: Vec<u8> = samples.data.iter().flat_map(|v| v.to_le_bytes()).collect();
                    output.write_all(&bytes).expect("write reference playout");
                    written += samples.data.len();
                }
            }
            if record {
                let samples = (0..WEBRTC_WINDOW).map(|_| {
                    let value = source[cursor];
                    cursor = (cursor + 1) % source.len();
                    value
                }).collect();
                Worker::recorded_data_is_available(transport, samples, 1, SAMPLE_FREQUENCY,
                    period, 0, 0, false, None);
            }
        }
    })
}
