# Person Profile

Updated: 2026-11-01

## Purpose

Use this file as the operator's project preference profile for `C:\Robotics`.
Keep it updated when the operator explicitly provides or changes a preference.
Do not infer personal identity from account names, camera images, or face detections.

## Identity

- Preferred name: not yet provided.
- Face enrollment name: **Aidyn**.

## Development preferences

- Default development laptop: **LEGION_A**, the Lenovo Legion 5.
- Workspace: **`C:\Robotics`**.
- Run the camera and vision development stack in **WSL2 Ubuntu-22.04**, rather
  than switching it to native Windows Python.
- Provision the full development stack, including camera access, Python
  environment, GPU dependencies, model weights, laptop configuration, and docs.
- Default camera: **Intel RealSense D455** through `pyrealsense2`.
- Desired capture mode: **1280 × 720 at 30 fps**.
- Current preferred browser display size: **1280 × 720**, responsive on smaller
  screens. This changes display size, not capture resolution.

## Project boundaries

- Camera/vision work is read-only with respect to the robot: no motion commands.
- Do not interpret setup or development requests as authorization to change live
  robot configurations or enable motion.
- Preserve runtime databases, existing user profiles, and unrelated work.
- Follow `Astro_dog/AGENTS.md` for detailed robot safety and deployment guidance.

## Verified setup reference

Verified on 2026-11-01; recheck live state rather than assuming it persists:

- D455 captured 298 colour frames in 10 seconds at 1280 × 720, with zero read
  failures, after reconnecting over USB 3.2.
- InsightFace initialized on CUDA using the RTX 5060 Laptop GPU.
- Vision environment: `Astro_dog/vision/.venv`.
- Live view address: `http://localhost:8099/` when the app is running.
- On 2026-11-02, Aidyn enrolled 25 face views, including side-view attempts,
  on this laptop. Detection or a
  face match is not conclusive evidence of a person's identity.
- USB busids and process IDs are temporary state, not preferences. Discover the
  camera with `bash scripts/realsense-wsl.sh` rather than assuming a fixed port.

## Maintenance

- Record confirmed preferences separately from observations and temporary state.
- Ask before filling in unknown personal details or enrolling a face under a name.
- Do not store passwords, access tokens, face embeddings, or private runtime
  databases in this file.
- This profile does not itself change camera settings, start services, enroll
  people, or authorize deployment.
