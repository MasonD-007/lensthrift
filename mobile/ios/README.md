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

## Run it

```bash
brew install xcodegen   # only if you change project.yml
xcodegen generate
open LensThrift.xcodeproj
```

Set your team under Signing & Capabilities and run on a real iPhone. The Simulator has no camera, so it only shows the UI.
