# Insomnia

My fork of [Insomnia by Krish Garg](https://github.com/krishhgg/Insomnia), based on v0.1.0. [MIT license](LICENSE).

## What's different

- Right-click the menu bar icon to end a session.
- Plugging in can start a session. Set the duration in Settings → Charging automation. It also works when macOS wakes the Mac to report the charger connection.
- Timer shows minutes and up.
- Removed the Session section from Settings.

Includes the menu bar fix from [hasin023's PR](https://github.com/krishhgg/Insomnia/pull/93).

## Install

Apple Silicon, macOS 26+. Download the ZIP and checksum from [Releases](https://github.com/B4Fajr/Insomnia/releases). Verify the download, unzip it, then run this from the unpacked folder:

```sh
./scripts/install.sh --app ./Insomnia.app
```

The installer needs admin access for the [power settings and recovery setup](https://github.com/krishhgg/Insomnia/tree/v0.1.0#install). The app is ad-hoc signed. Enable **Launch at login** if you want charger sessions after a restart.

To build from source, use Xcode with Swift 6.2+ and run `./scripts/install.sh`. To remove it, run `./scripts/uninstall.sh`.
