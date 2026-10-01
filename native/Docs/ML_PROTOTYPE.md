# First executed motion model

## Model and training

FocusMotionNetProto is a synthetic-only convolutional prototype, not production deghosting. It accepts Float32 NCHW 1×5×256×256: reference grayscale, aligned candidate grayscale, absolute residual, focus confidence, gradient magnitude. Output 1×2×256×256 is motion/blend-safety probability. Four convolution layers (12 hidden channels, dilation 1/2/3) and sigmoid have 3,194 parameters. Shared Core ML ML Program deployment is macOS 14/iOS 17. Compact source package totals **14,631 bytes**, including weights/manifest/model specification. Model-internal FP16 weight/mask arithmetic is explicit; photographic focus/depth/fusion remain Float32.

Training used isolated developer PyTorch 2.7.1/coremltools 9.0/NumPy 2.2.6/SciPy 1.18.1; the golden Python environment was unchanged. Seed 27, 1,200 steps, batch 12, 64² training crops, CPU four threads. Generated lines/grass/branches/hair, leaves, cloud/waves, foreground translations/deformations/occlusion supplied motion masks. Static negatives include blur, noise, exposure and simulated breathing followed by known inverse global registration. No photographs, training dataset or checkpoint is committed.

Training/evaluation took 48.82 s. Held-out 160 synthetic examples at threshold .5: precision .5598, recall .8873, IoU .5226; static/focus-only mean motion .1971 versus moving-region mean .8267. These modest metrics demonstrate separation but leave substantial false positives. They do not establish photographic deghost quality or justify enabling AI by default.

```sh
# Use a separate environment; never install training dependencies into .venv.
python3 -m venv /tmp/fs-motion-training
/tmp/fs-motion-training/bin/pip install torch==2.7.1 coremltools==9.0 numpy==2.2.6 scipy==1.18.1
/tmp/fs-motion-training/bin/python native/Developer/ML/train_motion_proto.py --artifacts /tmp/fs-model
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcrun coremlcompiler compile /tmp/fs-model/FocusMotionNetProto.mlpackage /tmp/fs-model
$BENCH --ml-prototype /tmp/fs-model
```

## Core ML measurement on physical M1 Max

Final weights, one warmup then 20 timed predictions, 256² five-channel input. Timings are model invocation only, excluding output-array extraction; configurations ran sequentially within one process. RSS peak therefore accumulates across configurations.

| Configuration | Load ms | Warmup ms | Mean inference ms | Min ms | Approx. tiles/s | Peak RSS MiB | Max difference vs PyTorch |
|---|---:|---:|---:|---:|---:|---:|---:|
| All | 58.49 | 4.91 | .914 | .846 | 1094 | 25.28 | .003594 |
| CPU only | .99 | 1.24 | .779 | .724 | 1284 | 26.24 | .002450 |
| CPU + GPU | 33.83 | 22.83 | 1.674 | 1.580 | 597 | 33.56 | .000653 |
| CPU + ANE | 12.36 | 2.99 | .553 | .504 | 1807 | 35.14 | .003594 |

The output shape, finite range [0,1] and ≤.01 PyTorch error are checked. FP16 model conversion explains small output differences. Final inference benchmark was repeated after build/test contention had ended; it is a local microbenchmark, not full-stack throughput.

MLComputePlan .all device mapping: all four convolutions, all three ReLUs and sigmoid prefer the detected 16-core ANE; supported devices include CPU, Apple M1 Max GPU and ANE. Input/output casts prefer CPU (supported CPU/GPU). Convolution relative costs were .02527/.43191/.19196/.03317; ReLU .06369 each; sigmoid .01734; casts .07805/.03122. Constants expose no useful device/cost. These weights are model-plan relative costs, not milliseconds. Actual compatible CPU+ANE inference succeeded. Plan preference plus successful configuration supports ANE acceleration eligibility; public APIs here do not expose definitive physical per-dispatch placement. No stronger execution claim is made.

## Actual Metal 4 ML dispatch

Official installed metal-package-builder produced a temporary .mtlpackage from the same model. On this Xcode/MetalToolchain arrangement its initial compiler lookup failed because coremlcompiler resides in XcodeDefault rather than beside the standalone Metal toolchain. `native/Developer/build_metal_model.py` builds a temporary sibling-toolchain layout using the existing Apple executable/frameworks; it does not modify Xcode or global settings.

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  python3 native/Developer/build_metal_model.py \
  /tmp/fs-model/FocusMotionNetProto.mlpackage /tmp/fs-model/FocusMotionNetProto.mtlpackage
$BENCH --metal-ml /tmp/fs-model
```

Actual reflected bindings: input `features` index 0/read-only and output `probabilities` index 1/write-only. Shared Float32 buffer-backed tensors have dimensions [256,256,C,1] and explicit strides. Metal compute fills input, shared GPU events order the ML dispatch and subsequent Metal output compute, then one final CPU readback validates results. No CPU pixel readback occurs between compute/ML/compute. Intermediate heap requirement is 64 bytes (allocate at least 4096).

Final measured cold invocation: tensor setup .0533 ms; complete library/pipeline/resource setup 69.150 ms; dispatch CPU encoding .0699 ms; **ML GPU feedback duration 6.9319 ms**; CPU synchronization wait 7.2094 ms; compute→ML→compute completion 8.1863 ms. Output range .02658–.97281; max PyTorch error .000653, matching the ordinary CPU+GPU result. End-to-end excludes final validation-array comparison, includes GPU synchronization; setup and wait overlap with different scopes and should not be summed. This single cold dispatch is not directly comparable to 20 warm Core ML means. It provides no performance reason to replace the ordinary fallback on this device. No newer hardware tensor/neural instruction utilization is claimed.

## Integration and flow

NativeStackEngine can opt into Auto/High mask assistance, default Off. One candidate is processed at a time through fixed 256² feature/probability resources. Auto/High motion thresholds .97/.85 and conservative dilation select coherent reference-source ownership in high-motion regions; static regions retain ordinary focus blending. Only the motion channel currently affects ownership. AI never emits photographic RGB. A native AI-on two-source TIFF roundtrip preserves exact source RGB in the deterministic static case.

The ordinary path shares Metal input backing with MLMultiArray and copies only bounded mask output back; Core ML internal transfers are unspecified. The tested Metal 4 path stays a developer experiment instead of adding a second unvalidated app ownership backend.

Vision low-accuracy 128² Float32×2 flow executed in 494.765 ms, output 131,072 bytes, process peak 59.875 MiB. It is kept optional and omitted from default motion features because this request costs far more than the small model. No all-frame/full-resolution flow is scheduled. Local normalized residual/flow consistency and better photographic training are future work.
