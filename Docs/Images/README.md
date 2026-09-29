# README images and reproduction

Updated September 29, 2026. These images were made for the public project page. No user photos are included.

## Sources

- **App icon:** `Velyn/Assets.xcassets/AppIcon.appiconset/AppIcon.png`. The existing Velyn icon is reused here. See the [generation record](../app-icon.md).
- **`sample-alpine.png`:** A 1536×1024 SDR landscape generated with OpenAI's image generation tool. It is not a camera capture or a RAW validation sample. Its SHA-256 is recorded in `report.json`.
- **`alpine-before.jpg`, `alpine-after.jpg`:** Exports of the same input through Velyn's production `EditingService.export` path.
- **`alpine-hdr.jpg`, `alpine-hdr.heic`:** Gain maps predicted by the bundled GMNet model and embedded by Velyn's HDR export code.
- **`app-*.png`:** Screenshots of Velyn in the iOS 27 Simulator, with English selected in the app. The editor loads the synthetic input and its saved edits. The status bar is set to 9:41 with `simctl`. These screenshots do not measure physical HDR display brightness.

The icon, synthetic input, and derived README images are provided under the repository's MIT license to the extent of the rights available. Bundled models retain their own licenses.

## Reproduce the exports

These examples were rendered on macOS with Xcode 27 and Swift 6.4. They are not A17 Pro performance or display measurements. Models compile and run locally; no photos are uploaded.

Use a new output directory. The script keeps the generated project and intermediate edit documents, so a directory under `.work/` is recommended.

```sh
mkdir -p .work
swiftc -O -parse-as-library \
  $(find Velyn/Engine -name '*.swift' -print) \
  Scripts/make-readme-examples.swift -o .work/readme-examples

.work/readme-examples \
  Docs/Images/sample-alpine.png \
  .work/readme-examples-output \
  Velyn/Models/VelynGainMap.mlpackage
```

`report.json` records the edit settings, file sizes, gain map checks, original-file preservation, and execution environment. UUIDs, file sizes, and floating-point results may vary between runs.

## Displaying HDR on the web

`hdr-reference-sdr.jpg` and `hdr-reference-hdr.jpg` both apply **−2 EV to linear output**. This shared scale makes their relative brightness readable on a regular SDR page. It is not a screenshot comparison of SDR and HDR on a display.

`hdr-applied-gain.png` divides the sum of the processed HDR RGB channels by the sum of the SDR channels, then displays `log2(gain) / 2`. Black represents 1× gain and white represents 4×. This includes midtone protection; it is not the raw model output.

ImageIO confirmed that both HDR downloads contain gain maps. After decoding them as HDR, a 256×170 sample had a peak RGB channel value of 2.3613× for JPEG and 2.3574× for HEIC. The rendered sample's maximum applied gain was about 2.44×, and its peak RGB value was about 2.39×. These values measure different things from the display's EDR headroom. Visible results depend on the device, viewer, and screen brightness.

## Input generation prompt

> Use case: photorealistic-natural. Asset type: synthetic sample photograph for an open-source iPhone photo editor README, used as INPUT for actual code-based photo editing and HDR gain-map demonstrations. Generate a single realistic landscape photograph, landscape 3:2 composition, 1536x1024 if possible. Quiet alpine lake at dawn, small weathered dark timber cabin on the left bank, tall fir trees, layered mountains in the background, softly illuminated clouds with a small bright sun just above the ridge, fine silver-gold highlights reflected across rippling water, detailed stones and grasses in the foreground. Natural camera rendering, subtly cool white balance, slightly subdued saturation and underexposed shadow detail that remains visible and can be lifted in editing. Rich but restrained realistic texture, no dramatic baked-in color grading or excessive HDR effect, no clipped large white sky regions. The photo should feel coherent and usable as an unedited SDR sample. No humans, no trademarks, no text, no borders, no labels, no split view, no comparison, no UI.
