# README images and reproduction

Updated October 1, 2026 for v1.1. These images were made for the public project page. No user photos are included.

## Sources

- **App icon:** `Velyn/Assets.xcassets/AppIcon.appiconset/AppIcon.png`. The existing Velyn icon is reused here. See the [generation record](../app-icon.md).
- **`sample-alpine.png`:** A 1536×1024 SDR landscape generated with OpenAI's image generation tool. It is not a camera capture or a RAW validation sample. Its SHA-256 is recorded in `report.json`.
- **`alpine-before.jpg`, `alpine-after.jpg`:** Exports of the same input through Velyn's production `EditingService.export` path.
- **`alpine-hdr.jpg`, `alpine-hdr.heic`:** Gain maps predicted by the bundled GMNet model and embedded by Velyn's HDR export code.
- **`app-*.png`:** Six screenshots of Velyn v1.1 in the iOS 27 Simulator, with English selected in the app. The library contains the synthetic input and three crop/color variants made by Velyn. The editor loads that input and its saved edits. The status bar is set to 9:41 with `simctl`. These screenshots do not measure physical HDR display brightness.

The icon, synthetic input, and derived README images are provided under the repository's MIT license to the extent of the rights available. Bundled models retain their own licenses.

## Reproduce the exports

These examples were rendered on macOS with Xcode 27 and Swift 6.4. They are not A17 Pro performance or display measurements. Models compile and run locally; no photos are uploaded.

Use a new output directory. The script keeps the generated project and intermediate edit documents, so a directory under `.work/` is recommended.

```sh
mkdir -p .work
swiftc -O -parse-as-library \
  $(rg --files Velyn/Engine -g '*.swift') \
  Scripts/make-readme-examples.swift -o .work/readme-examples

.work/readme-examples \
  Docs/Images/sample-alpine.png \
  .work/readme-examples-output \
  Velyn/Models/VelynGainMap.mlpackage
```

`report.json` records the edit settings, file sizes, gain map checks, original-file preservation, and execution environment. UUIDs, file sizes, and floating-point results may vary between runs.

Build the Debug simulator app, boot a simulator, then capture the actual UI:

```sh
python3 Scripts/capture-readme.py \
  SIMULATOR_UDID \
  .work/DerivedData/Build/Products/Debug-iphonesimulator/Velyn.app \
  .work/readme-examples-output
```

The script writes `Docs/Images/`, uses a separate `ReadmeV11` fixture store, and serially launches the library, selection, editor, HDR, export, and settings screens. Do not launch another simulator workflow during capture. Original synthetic bytes remain unchanged; the three gallery variants use saved edit recipes.

## Displaying HDR on the web

`hdr-reference-sdr.jpg` and `hdr-reference-hdr.jpg` both apply **−2 EV to linear output**. This shared scale makes their relative brightness readable on a regular SDR page. It is not a screenshot comparison of SDR and HDR on a display.

`hdr-applied-gain.png` divides the sum of the processed HDR RGB channels by the sum of the SDR channels, then displays `log2(gain) / 2`. Black represents 1× gain and white represents 4×. This includes midtone protection; it is not the raw model output.

ImageIO confirmed that both HDR downloads contain gain maps. After decoding them as HDR, a 256×170 sample had a peak RGB channel value of 2.3828× for JPEG and 2.3711× for HEIC. The rendered sample's maximum applied gain was about 2.44×, and its peak RGB value was about 2.47×. These values measure different things from the display's EDR headroom. Visible results depend on the device, viewer, and screen brightness.

## Input generation brief

Photorealistic 1536×1024 landscape of an alpine lake in the Italian Dolomites shortly after sunrise. Pale limestone mountains catch warm low sunlight above cool blue-green water. A weathered wooden boat sits in the lower left, with sparse pines on the right and restrained clouds. Keep foreground shadows slightly underexposed but visible, with natural color and no exaggerated HDR effect. No people, text, logos, borders, or UI. This generated SDR photograph is the input; all subsequent edits and HDR examples are produced by Velyn.
