# Hugging Face inference package

Published model: https://huggingface.co/H4RUming/Velyn-GMNet-Camera-v1

`prepare.py` takes the pinned local training checkpoint and a new output directory:

```sh
python prepare.py /private/path/best.pt /private/path/public-inference-package
```

Run from this directory, with Torch and safetensors installed. It verifies the
checkpoint hash, loads its strict GMNet state, exports only learned tensors to
safetensors, and compares every restored tensor exactly. It copies an explicit
set of public files and verifies the Core ML packages against the app's integrity
manifest. It never recursively copies a training directory. The output's
`SHA256SUMS.txt` lists the intended public files.

Publish only the listed files plus the checksum file. Importing Python files can
create `__pycache__`; these files are not part of the release. No training photos,
EXIF, filenames, individual scores, optimizer state, or full checkpoint are
included. Do not create or upload a photo dataset as part of this model workflow.

`model-card.md` is the published model card source. `inference.py` is copied beside
the architecture and weights in the package; run it from that package, not this
source directory. Its output is scalar EV in a NumPy array, not an HDR container.

The initial public package was checked on generated constant-gray inputs for
FP32 reference agreement, rectangular output geometry, finite gain, invalid-input
rejection, sRGB image loading and command-line execution. Core ML packages are
byte-identical to those tested in Velyn v1.2. Engine behavior is unchanged.
