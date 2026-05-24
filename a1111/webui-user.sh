#!/bin/bash
# webui-user.sh -- A1111 stable-diffusion-webui local config
#
# Tailnet + LAN binding, Apple Silicon MPS backend. Auto-loaded by webui.sh.
# Live copy lives at ~/stable-diffusion-webui/webui-user.sh on pico — keep
# both in sync (mac.setup.sh installs this one).

# Pin Python 3.10 (system python3 is 3.9 on macOS Sonoma; A1111 needs 3.10).
python_cmd="/opt/homebrew/bin/python3.10"

# COMMANDLINE_ARGS — what the launcher passes to webui.py:
#   --listen                  bind 0.0.0.0 (so tailnet + LAN devices reach it,
#                             not just localhost). NO public-internet exposure
#                             — nginx on zig-computer does NOT proxy to here.
#   --port 7860               default Gradio port; nothing else on pico uses it.
#   --skip-torch-cuda-test    macOS has no CUDA; suppress the test that would
#                             otherwise crash the launcher.
#   --upcast-sampling         MPS-specific: keep sampling in fp32 to avoid the
#                             garbled-output bug on some samplers.
#   --no-half-vae             MPS VAE bug workaround — full fp32 VAE.
#   --use-cpu interrogate     CLIP/BLIP interrogators run on CPU (MPS path
#                             unstable for these models).
#   --enable-insecure-extension-access
#                             without this, --listen disables the Extensions
#                             tab; we want extensions usable on a trusted
#                             network.
#
# Note: the "Upcast cross attention layer to float32" toggle (needed for
# SDXL inpainting on MPS — without it, Unet produces NaN tensors and the
# generation crashes) is a Settings-only option in A1111 1.10. There is no
# CLI flag. Pre-seeded in `a1111/config.json` (installed by mac.setup.sh
# as the initial config). Less heavy than --no-half (which doubles memory
# for the whole model rather than just the cross-attention layer).
export COMMANDLINE_ARGS="--listen --port 7860 --skip-torch-cuda-test --upcast-sampling --no-half-vae --use-cpu interrogate --enable-insecure-extension-access"

# Stability-AI deleted the canonical stablediffusion repo (2026-Q1; A1111 PR
# #17271 documents the migration). The default URL in launch_utils.py:349
# returns 404 (masked behind a 401 challenge that breaks the credential flow).
# w-e-w mirror is the community-standard replacement — public, stable, same
# commit hash A1111 pins (cf1d67a6fd5ea1aa600c4df58e5b47da45f6bdbf).
export STABLE_DIFFUSION_REPO="https://github.com/w-e-w/stablediffusion.git"
