"""Qwen-Image-2.1 GPU smoke test.

Runs a small 512x512, 4-step generation inside the ``qwen_image_dev`` container to
verify that CUDA, the pinned model revision and the Diffusers pipeline all work.

The script now accepts command-line arguments so that ``scripts/runner.py`` can
direct each run to a unique output path and vary generation parameters.  Every
argument keeps the previous hard-coded value as its default, so running this
script with no arguments behaves exactly as before.
"""

from __future__ import annotations

import argparse
from pathlib import Path

import torch
from diffusers import QwenImage21Pipeline

DEFAULT_MODEL_PATH = (
    "/home/stte_docker/.cache/huggingface/hub/"
    "models--Qwen--Qwen-Image-2.1/snapshots/"
    "d26bb61231c349cf6b7896fa83353113880e1ba3"
)

DEFAULT_OUTPUT_PATH = "/workspace/outputs/qwen_image_21_smoke_test.png"

DEFAULT_PROMPT = (
    "A small red fox sitting in a field of wildflowers, "
    "natural morning light, detailed fur, realistic photography"
)


def parse_args(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model-path", default=DEFAULT_MODEL_PATH)
    parser.add_argument("--output-path", default=DEFAULT_OUTPUT_PATH)
    parser.add_argument("--width", type=int, default=512)
    parser.add_argument("--height", type=int, default=512)
    parser.add_argument("--num-inference-steps", type=int, default=4)
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--true-cfg-scale", type=float, default=1.0)
    parser.add_argument("--prompt", default=DEFAULT_PROMPT)
    return parser.parse_args(argv)


def main(argv=None) -> int:
    args = parse_args(argv)

    model_path = args.model_path
    output_path = Path(args.output_path)

    print("CUDA:", torch.cuda.is_available(), flush=True)
    if not torch.cuda.is_available():
        raise RuntimeError("CUDA is unavailable")

    print("GPU:", torch.cuda.get_device_name(0), flush=True)
    print("Loading Qwen-Image-2.1...", flush=True)

    pipe = QwenImage21Pipeline.from_pretrained(
        model_path,
        torch_dtype=torch.bfloat16,
        local_files_only=True,
    )
    # 会在 CPU 与 GPU 之间转移模型组件，以适应 16 GB 显存
    pipe.enable_sequential_cpu_offload()

    print(
        f"Generating {args.width}x{args.height} image with "
        f"{args.num_inference_steps} steps...",
        flush=True,
    )

    result = pipe(
        prompt=args.prompt,
        width=args.width,
        height=args.height,
        num_inference_steps=args.num_inference_steps,
        true_cfg_scale=args.true_cfg_scale,
        generator=torch.Generator(device="cpu").manual_seed(args.seed),
    )

    output_path.parent.mkdir(parents=True, exist_ok=True)
    result.images[0].save(output_path)

    print(f"SUCCESS: {output_path}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
