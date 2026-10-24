# Thrift Lens iOS (proof of concept)

A native iOS capture client built on [HaishinKit](https://github.com/HaishinKit/HaishinKit.swift) 2.2.5. It saves the clearest rear-camera frame of each second as a 1080×1920 JPEG.

## How capture works

HaishinKit's `MediaMixer` owns a single `AVCaptureSession` at the `.hd1920x1080` preset, and it drives the live preview (`MTHKView`). Press the red button to start: the app saves **the clearest frame of each second** as a 1080×1920 JPEG, which matches the backend's ~1 fps budget in `Plan.md`.

`SharpFramePicker` picks that frame while keeping the load on the phone light:

- It scores every 3rd camera frame (about 10 a second), on its own queue, and skips frames while it's busy, so the preview never waits.
- The score is the Laplacian variance of a 256×256 center crop of the luma plane, discounted by how fast the gyroscope says the phone is turning.
- It holds only the best frame so far, and only that one is encoded to JPEG when the second ends.

To reduce motion blur, the camera focuses on the center and caps exposure at 1/60s. In low light the image gets noisier rather than smeared.

`CameraModel.Source.photo` is kept for native `AVCapturePhotoOutput` stills, in case they're needed later. The UI doesn't expose it.

Captures go to `Documents/captures/<time>-s<score>.jpg`. The in-app gallery shows each capture's gap from the previous one and its sharpness score. They're also in the Files app under **On My iPhone → Thrift Lens**. The backend upload belongs at the `TODO` in `CameraModel.captureOnce()`.

## YOLO boxes

While capturing, the app also sends the newest frame's center square (320px JPEG, same as the web client) to `POST /api/detect`, up to 4 times a second, and draws the returned boxes over the preview. The dashed square shows what YOLO sees. The status bar shows the box count and round-trip time, and the server button's dot turns green when detection works.

Every detection also lands on the Mac at `http://localhost:8080/objects.html`. Each object is appended when it comes into view, repeats included; one held in view isn't repeated.

**Backend URL:** tap the server button to set it, or bake a default in at build time with `BACKEND_URL=http://<mac-ip>:8080`. A build with a new default replaces the URL saved in the app.

**Networks:** venue Wi-Fi often blocks phone-to-laptop traffic. Put the Mac on the iPhone's Personal Hotspot instead. Hotspots can be IPv6-only, so run the backend with `--host ::` and use the Mac's IPv6 address, e.g. `http://[2607:…]:8080`:

```bash
cd backend && .venv/bin/python -m uvicorn app.main:app --host :: --port 8080
```

## Run it

```bash
brew install xcodegen   # only if you change project.yml
xcodegen generate
open LensThrift.xcodeproj
```

Set your team under Signing & Capabilities and run on a real iPhone. The Simulator has no camera, so it only shows the UI.
