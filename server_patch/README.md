# MAX_NODES Patch for Garry's Mod

A simple Python script designed to patch `server.dll` for the `x86-64` branch of Garry's Mod.

Garry's Mod has a hardcoded limit of 8,192 nodes in a nodegraph. When a nodegraph exceeds this limit, the engine will fail to load the network or crash. This patch increases the internal nodegraph limits to 32,768 nodes, allowing for much larger and more detailed nodegraphs.

This patch was made for the `2026.03.16` version of the `x86-64` branch of Garry's Mod. It may or may not work for other versions.

## Disclaimer

- This patch is highly experimental and may cause crashes and bugs.
- Be careful to not join VAC-enabled servers with the patch applied.
- Use at your own risk.

## Prerequisites

- Python 3.11 or higher.
- `x86-64` branch of Garry's Mod.

## Usage

WARNING: Although the script creates a backup of your `server.dll` automatically, it is recommended that you make a backup of your `server.dll` before running the script.

1. Copy `patch.py` to your Garry's Mod `bin/win64` directory.
2. Run the script:
   ```bash
   python patch.py
   ```
3. If successful, the script will report `Patching complete successfully`.
