# Parallel Android Emulators

Run multiple AVD instances side by side for parallel Appium testing.

## Port allocation

Each emulator needs a unique console port (even number) and a unique Appium port.

| Instance | AVD name         | Emulator port | Appium port |
|----------|------------------|---------------|-------------|
| 1        | MobiSSH_Pixel7   | 5554          | 4723        |
| 2        | MobiSSH_Pixel7_2 | 5556          | 4725        |

ADB derives its serial from the console port: `emulator-5554`, `emulator-5556`.

## Setup

Create two AVDs (one-time):

```bash
scripts/setup-avd.sh
scripts/setup-avd.sh --name MobiSSH_Pixel7_2 --port 5556
```

## Running tests in parallel

Terminal 1:

```bash
scripts/run-appium-tests.sh --avd MobiSSH_Pixel7 --port 5554 --appium-port 4723
```

Terminal 2:

```bash
scripts/run-appium-tests.sh --avd MobiSSH_Pixel7_2 --port 5556 --appium-port 4725
```

## Notes

- Emulator console ports must be even numbers in the range 5554-5682.
- Each instance gets its own ADB serial (`emulator-PORT`), so `adb` commands are isolated.
- The MobiSSH server port (`MOBISSH_PORT`) is separate and shared by default (8081). Override with `MOBISSH_PORT=8082` if needed.
- Default behavior (no arguments) is unchanged: AVD `MobiSSH_Pixel7`, port 5554, Appium 4723.
