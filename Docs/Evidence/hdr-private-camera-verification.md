# Native camera fine-tuning and server cleanup

2026-10-02. The user explicitly authorized using their camera archive on their
designated training server and required deletion afterward. **The server's entire
private job directory has been deleted and its absence verified.** The trained
candidate and private results were first copied back to the Mac and checked
against server SHA-256 values. No private photo, per-photo result or trained
checkpoint is included in Git. The app still uses its existing bundled model.

## Data preparation

The archive contained 999 supported still images and one video. Still-image
staging copied bytes into anonymous local filenames and verified SHA-256; the
source archive was opened read-only. The video was excluded. Of the still images,
**882 had readable HDR gain maps** and **117 did not**. All 882 yielded usable
aligned SDR/HDR pairs; no artificial HDR labels were substituted for missing maps.

Decoding ran on macOS 27 with ImageIO, taking the default embedded SDR rendering
and `kCGImageSourceDecodeToHDR` rendering from the same source. Orientation and
512px long-edge scaling were applied to both. Explicit float Core Graphics bitmap
contexts converted both to extended linear sRGB, avoiding the previously observed
direct Core Image float-readback problem. The system returned 8-bit SDR and
10-bit HDR thumbnails for these pairs. These are the camera/system's renditions,
not a measurement of original scene luminance in nits. Neither representation was
independently normalized to improve scores.

The restricted initial ImageIO invocation failed to expose auxiliary gain maps.
Container inspection and an authorized decoder invocation confirmed the maps and
successfully decoded the files. An all-missing result from that restricted run was
not used to reject the collection. Five real pairs were subsequently re-decoded
after tightening error handling; their metadata and float pixel hashes matched.

The preparation code groups photographs by capture day, with a perceptual-hash
check to join visually similar images across days. Groups never cross the split.
The heuristic is conservative about same-day captures but does not guarantee that
every recurring subject or location was identified.

| Split | Images | Capture groups |
| --- | ---: | ---: |
| Training | 618 | 50 |
| Validation | 132 | 29 |
| Final test | 132 | 30 |

Only necessary pixel tensors, anonymous split groups and integrity hashes were
transferred. Original filenames, EXIF dates, camera metadata and location were
omitted. The transferred pixels were nevertheless treated as private photos.
The archive was 959,395,840 bytes and its SHA-256 matched after transfer.

The target is the log2 ratio of HDR and SDR linear luminance. The point loss
excludes pixels below 0.01 in either representation. Model output is still bounded
to −2…log2(5) EV. About 0.097% of valid pixels per image fall outside that range on
average. Negative target gain below −0.05 EV occupies only **0.84%** on average
across the collection, making attenuation a relatively scarce training signal.

## Training and selection

The 595,201-parameter SignedGainNet starts from the earlier public-CC0-data pilot.
This experiment is supervised adaptation using native camera targets. It does
not train on GMNet's predictions or introduce new server processing in the app.

Training uses 256px aligned crops from 512px images, full-image 128px thumbnails,
horizontal flips, batch 24, AdamW, FP16 autocast and a cosine learning rate from
0.00005 to 0.000002. The signed EV loss and masked spatial-gradient term preserve
pixel alignment. Arbitrary exposure changes were not applied to the camera labels.

The fixed 6,000-step loop took **43.35 seconds**, including periodic validation
and checkpoint writes, excluding transfer, loading, initial validation and final
test inference. Hardware was an RTX PRO 6000 Blackwell Workstation Edition with
Torch 2.7.0+cu128. These numbers are not iPhone performance evidence.

Validation selected **step 500**, with MAE 0.27506 EV. Later checkpoints did not
improve it. The final test was loaded only after that checkpoint was selected and
frozen. No parameters or postprocessing were tuned on the final test results.

## Final test: 132 photos from 30 unseen capture groups

Lower error is better. Photo means weight each photo equally; group means weight
each capture group equally. Both use the full, unclipped target EV. The difference
between full and bounded target errors is small and recorded in the numeric file.

| Predictor | Mean photo error EV | Mean group error EV |
| --- | ---: | ---: |
| Unchanged SDR | 0.839559 | 0.794625 |
| Previous synthetic-data pilot | 0.749221 | 0.712089 |
| Published GMNet, direct 1024px prediction | 0.487931 | 0.455463 |
| GMNet with approximate app protection | 0.635414 | 0.596112 |
| **Camera-adapted SignedGainNet** | **0.349993** | **0.378250** |

The candidate reduces photo-weighted error by **28.3%** versus direct GMNet and
**53.3%** versus the previous own-model pilot. It improves 93/132 photos versus
direct GMNet and 97/132 versus protected GMNet. Some photos regress: the worst
increase is 0.5807 EV versus direct GMNet and 0.8995 EV versus protected GMNet.

A paired bootstrap over the 30 groups gives a 95% difference interval of
−0.1952…+0.0473 EV versus direct GMNet. That interval crosses zero, so this sample
does not establish a consistent advantage across capture groups. The interval
versus approximate protected GMNet is −0.3877…−0.0344 EV. Neither interval predicts
performance on other users' photos, camera models or an HDR display.

The GMNet comparison uses its pinned published weights in PyTorch at 1024px,
the same SDR input and a 256px full-image thumbnail. Protection reproduces the
75% strength, scene-adaptive gate and 2 EV cap in tensor code, with bilinear map
enlargement. It excludes the app's edge-aware enlargement, full-resolution export
and codec behavior; this is **not** a complete app-versus-app comparison.

### Attenuation is rare here, not a requirement for HDR

The selected candidate predicts no gain below −0.05 EV on valid final-test pixels.
Negative-region recall is therefore **0%**, while the target contains 2.26%
negative pixels per photo on average. This measures a limitation in reproducing
those regions; it does **not** by itself make the result invalid HDR or justify
rejecting the model. The earlier synthetic pilot predicted many wrong negative
regions, which adaptation largely removed.

The user correctly questioned whether attenuation should be a central objective.
[Apple's HDR presentation](https://developer.apple.com/videos/play/wwdc2024/10177/)
describes preserving bright regions above SDR reference white and applying gain
to an SDR base. HDR does not require some pixels to become darker than SDR.
The more general Adaptive HDR format supports alternate renditions and reverse
transformations, so this is not a claim that negative gain is impossible or absent
from every HDR workflow.

Follow-up measurements on the 132 frozen test images give a median negative-region
fraction of **0.118%** at −0.05 EV; the mean is pulled up by a minority of images.
Only 27 images have over 1% negative pixels, and 12 have over 5%. Regions darker by
more than 0.25 EV cover **0.663%** on average. If the predictor applied exactly
zero gain on all negative target pixels, their contribution to full-image MAE
would be only **0.00554 EV**. This is a reference diagnostic, not the candidate's
actual negative-region error, since it can apply positive gain there.

These values compare decoded and resized SDR/HDR luminance; small differences can
also include quantization, resampling and color-conversion effects. They do not
independently establish deliberate negative gain in the original encoded map.
We should prioritize correct highlight placement and magnitude, overall exposure,
color and per-image regressions, while monitoring attenuation where it matters.
We should not invent negative labels or distort their frequency to make HDR look
more sophisticated. This interpretation changed no trained weights or test score.
New final-test groups will be needed after using these results to guide training.

## Local conversion and prior development audit

Core ML FP16 conversion succeeded. The package is 1,233,460 bytes. Six generated
inputs under CPU_ONLY and CPU_AND_NE policies pass comparison against PyTorch,
with worst absolute error **0.00814 EV**. Testing was on the Mac, not an iPhone;
a compute policy is not proof that every operation ran on the Neural Engine.

The existing 15-photo development audit was also rerun locally against saved
actual app GMNet renders. Mean error changed from 0.463032 to 0.444345 EV for direct
candidate gain, or 0.425664 EV with existing protection. Direct gain improved 9/15
photos, but its worst regression was 0.7516 EV. These repeatedly used photos are
exploratory; possible overlap with this gallery was not ruled out. They provide
no additional independent validation and did not select the trained checkpoint.

## Cleanup and acceptance

The server job used an isolated mode-0700 directory. A bounded runner removed
the uploaded archive and unpacked tensors in `finally` after training/evaluation.
It also has failure and termination cleanup and a 20-minute child-process timeout.
An uncatchable host/process failure would still require explicit caller cleanup.

After the successful run, all result files were downloaded and their SHA-256 values
were compared with the server copies. The complete private workspace was then
removed, including private weights, per-image scores and logs. Its absence was
verified. Pre-existing public datasets, public checkpoints and general research
scripts remain on the server. Original photos and retained research artifacts
are local on the Mac; the user's source archive is unchanged.

Four synthetic privacy tests pass both locally and on the server: ZIP traversal
rejection, byte-preserving anonymous staging/deduplication, TAR link rejection,
and deletion of an archive plus partially extracted pixels after job failure.
Swift decoder compilation, Python syntax checks and the five real-pair decoder
regressions also pass. Aggregate evidence excludes image identities, local paths,
capture metadata, per-image metrics and image hashes.

No app engine code or default weights changed, so the engine suite was not rerun.
The candidate remains private research output because individual-photo regressions
and physical-device HDR display/thermal validation remain open. Attenuation is an
optional fidelity improvement where supported by the target, not a universal HDR
acceptance gate. Low-headroom signed export remains a separate limitation for
edits that need it. No release or C01–C10 gate was marked complete.

[Aggregate numeric evidence](hdr-private-camera-results.json) ·
[Research workflow and cleanup contract](../../Scripts/HDR/Training/README.md#explicitly-authorized-private-camera-adaptation)
