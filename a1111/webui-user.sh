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
#   --no-half                 force full fp32 throughout the model. Heavy
#                             (doubles model memory: SDXL ~6.5GB → ~13GB)
#                             but reliably prevents NaN crashes on MPS for
#                             SDXL inpainting. The lighter alternatives
#                             (--upcast-sampling + the Settings "Upcast
#                             cross attention" toggle) tested INSUFFICIENT
#                             on M1 Max for SDXL inpaint workflow — Unet
#                             still produced NaN even with both. The
#                             config.json `upcast_attn: true` is kept as
#                             belt-and-suspenders but is technically moot
#                             once --no-half is in effect (sampling is
#                             already fp32 throughout). Note: --upcast-
#                             sampling has "no effect with --no-half" per
#                             A1111's own help text, so dropped.
#   --no-half-vae             MPS VAE bug workaround — full fp32 VAE.
#   --use-cpu interrogate     CLIP/BLIP interrogators run on CPU (MPS path
#                             unstable for these models).
#   --enable-insecure-extension-access
#                             without this, --listen disables the Extensions
#                             tab; we want extensions usable on a trusted
#                             network.
export COMMANDLINE_ARGS="--listen --port 7860 --skip-torch-cuda-test --no-half --no-half-vae --use-cpu interrogate --enable-insecure-extension-access"

# Stability-AI deleted the canonical stablediffusion repo (2026-Q1; A1111 PR
# #17271 documents the migration). The default URL in launch_utils.py:349
# returns 404 (masked behind a 401 challenge that breaks the credential flow).
# w-e-w mirror is the community-standard replacement — public, stable, same
# commit hash A1111 pins (cf1d67a6fd5ea1aa600c4df58e5b47da45f6bdbf).
export STABLE_DIFFUSION_REPO="https://github.com/w-e-w/stablediffusion.git"
