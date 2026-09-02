# SnapGd

**Snapshot based multiplayer synchronization for [Godot 4](https://godotengine.org/)**

[![Godot](https://img.shields.io/badge/Godot-4.6%2B-478cbf?logo=godot-engine&logoColor=white)](https://godotengine.org/download)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
![Release](https://img.shields.io/github/v/release/joaquinkiko/SnapGd)

SnapGd is a networking addon for handling smooth gameplay and synchronization for fast-paced multiplayer.

## Features

- **Time synchronization** between players
- **Client prediction and Server reconciliation** for responsive gameplay
- **Interpolation** for smooth synchronization regardless of ping
- **Lag compensation** for fast-paced gameplay
- **Anit-cheat** systems to ensure fair-gameplay

## Install
 
After adding the latest [Release](../../releases/latest) to your project, enable the addon in your project settings.

## Usage

See [How To Use](docs/usage.md) for full guide.

A demo is also provided to show an example of how it can be used.

Note that SnapGd is design with Server-Authoritative networking in mind, and not pure P2P, though there is support for Client-Server networking (where the server is a player themselves).

## Roadmap

- [ ]  Improved physics support

## License
 
This project is licensed under the [MIT License](LICENSE).

## Support

If you enjoy this project, consider supporting development:

[![ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/joaquinkiko)
