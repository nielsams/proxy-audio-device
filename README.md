## Proxy Audio Driver

A HAL virtual stereo audio driver and menu-bar app for macOS. It routes audio
to a physical output, adds a ten-band graphic equalizer, and makes macOS's system
volume controls work with external audio interfaces that do not provide them.
The app also supports automatic output switching when a configured device
connects or disconnects.

The virtual output appears in macOS as **Equalizer Audio**. Upgrading migrates the
previous default name, **Proxy Audio Device**, while preserving custom names.

### Installation

#### Install with a package manager

[![Packaging status on repology](https://repology.org/badge/vertical-allrepos/proxy-audio-device.svg)](https://repology.org/project/proxy-audio-device/versions)

Install [proxy-audio-device with Homebrew with `brew`](https://formulae.brew.sh/cask/proxy-audio-device):

    brew install --cask proxy-audio-device

_or_ [proxy-audio-device on macports with `port`](https://ports.macports.org/port/proxy-audio-device/):

    sudo port install proxy-audio-device

Run the _Proxy Audio Device_ app to configure your new audio device.

Package managers install their published versions, which may not include the
menu-bar app, equalizer, or automatic switching described here. To use these
changes, build this repository and install both updated products.

#### Manual installation

1. Build the driver and app as described under **Building**, or obtain matching
   release artifacts. Both **ProxyAudioDevice.driver** and
   **Proxy Audio Device.app** are needed.

2. Quit the existing menu-bar/settings app and copy **Proxy Audio Device.app**
   to **/Applications**. If upgrading from **Proxy Audio Device Settings.app**,
   remove that older app after copying the replacement. The bundle identifier
   stays the same, preserving the app's preferences.

3. In Terminal, change to the directory containing **ProxyAudioDevice.driver**
   and install it, entering your administrator password when prompted:

        sudo mkdir -p /Library/Audio/Plug-Ins/HAL
        sudo ditto ProxyAudioDevice.driver /Library/Audio/Plug-Ins/HAL/ProxyAudioDevice.driver
        sudo chown -R root:wheel /Library/Audio/Plug-Ins/HAL/ProxyAudioDevice.driver

4. Restart your Mac to load the updated driver. Alternatively, inspect the
   current Core Audio PID with
   `launchctl print system/com.apple.audio.coreaudiod`, then restart that
   specific process with `sudo kill -TERM <PID>`, replacing `<PID>` with the
   value just inspected. This interrupts all audio. Updating only the app does
   not require restarting Core Audio.

5. Launch **Proxy Audio Device**. Choose **Settings...** from its menu-bar icon
   and select the physical **Source device**, then select **Equalizer Audio**
   as the macOS sound output. Open **Equalizer** and select **Active** to apply
   filtering. Automatic switching is optional and initially off.

### Menu bar controls and equalizer

Launching _Proxy Audio Device_ adds an audio-controls icon to the macOS
menu bar. Choose **Settings...** to configure the output device or **Equalizer**
to open the graphic equalizer. Closing either window leaves the menu-bar app
running. Use **Quit Proxy Audio Device** in its menu to quit the app.

To start the menu-bar app automatically, add
**/Applications/Proxy Audio Device.app** under **System Settings > General >
Login Items & Extensions > Open at Login**. It starts without opening either
window. This also makes automatic device switching available after login;
the audio driver itself loads independently of the app.

The equalizer starts in **Bypass**, which leaves audio unchanged. Select **Active**
on the Bypass/Active toggle to enable filtering. The ten vertical faders adjust both stereo
channels together, from -12 to +12 dB, at approximately 31, 63, 125, 250, 500,
1k, 2k, 4k, 8k, and 16k Hz. **Reset to flat** resets the gains and preamp without
changing the Active/Bypass state.

The read-only **System volume** indicator follows the current macOS output
device's volume setting and mute state, including changes made with keyboard
volume keys. It is not an audio signal meter. Devices that do not expose volume
controls show **Unavailable**.

The LED columns show live, post-EQ audio levels in each frequency band, before
system volume and mute, even in Bypass. Green, yellow, and red segments cover
-57 to 0 dBFS; red indicates little remaining headroom. These are frequency-band
peak meters, not gain indicators or a full-output clipping detector. Lower the
**Preamp** (0 to -24 dB) when boosting bands to avoid clipping. Bands at or above
the current sample rate's Nyquist frequency are not processed.

EQ settings are saved by the audio driver and survive restarts. Filtering
continues when either window is closed or the menu-bar app is quit. It only
affects audio routed through Equalizer Audio (or its custom name). Both the updated driver
and app must be installed to use the equalizer; building or updating the app
alone does not update the installed HAL driver.

### Audio engine activity

In **Settings...**, **Audio engine activity** controls when the driver keeps
the forwarding audio stream running on the physical source device, provided
that device is available and ready:

- **When Equalizer Audio is in use** runs the stream only while macOS has audio
  I/O running through Equalizer Audio. This includes streams carrying silence;
  it does not detect audible sound or just check whether the source is connected.
  It saves idle power, but starting the output stream can cut off the beginning
  of a sound.
- **When user is not idle** (the default) runs the stream during audio playback
  or when keyboard/mouse activity occurred within the last 30 seconds. Ongoing
  playback continues when the user becomes idle. Keeping the stream ready
  during interaction reduces startup cut-offs.
- **Always** keeps the stream running even without playback or user activity.
  This uses more idle power and can prevent automatic sleep.

This setting was previously labelled **Proxy device is active**, with the
first option labelled **When proxied device is active**. The clearer labels do
not change its behavior or saved selection. It remains separate from the
connection-based output switching below and from the equalizer's
**Active/Bypass** toggle: those choose the audio destination and enable or
disable filtering, respectively. Audio engine activity is saved and enforced
by the driver even when the menu-bar app is quit.

### Source device and automatic output switching

In **Settings...**, **Source device** selects the physical audio device that
Equalizer Audio forwards audio to (previously labelled **Proxied device**).

Two independent options automate macOS output selection:

- **Switch to proxy audio when source device is connected** selects Equalizer
  Audio when the configured source is attached or becomes available.
- **Switch to fallback device when source device is disconnected** selects the
  **Fallback device** when that source is detached or becomes unavailable.

macOS's default output is simply its current output selection; it does not
provide a separate saved fallback while Equalizer Audio is selected. Choose
**MacBook Pro Speakers**, or another output, in **Fallback device**. The app
initially suggests the built-in output when available, otherwise the current
non-proxy output if it differs from the source. It remembers your selection by
device UID, including while that device is disconnected. An unavailable
fallback is not silently replaced with a different device.

Both options are off by default and are saved per user. They respond to
connection changes, not app launch, checkbox changes, or selection of a
different source. Unrelated device changes do not override a manual output
selection. Automatic switching requires the menu-bar app to remain running,
but works with both windows closed. Quitting the app stops automatic switching,
not the driver's audio processing. These options change the main audio output,
not the separate macOS sound-effects output, volume, mute, or EQ settings.

### Uninstallation

1. Remove **Proxy Audio Device** from **Open at Login**, if present, quit the
   app, and remove **/Applications/Proxy Audio Device.app**.

2. Remove the driver:

        sudo rm -rf /Library/Audio/Plug-Ins/HAL/ProxyAudioDevice.driver

3. Restart your Mac or restart the specific Core Audio process as described
   under **Manual installation**.

### Building

Clone the repo, open the Xcode project and build the driver and the settings application. Then follow the above installation instructions to install it.

The app product is **Proxy Audio Device.app**. The Xcode target and shared scheme
retain the name **Proxy Audio Device Settings**. The app's bundle identifier is
unchanged, so existing EQ and automatic-switching preferences are preserved.

With an Xcode version that no longer supports the project's macOS 10.11
deployment target, override it for a local build, for example:

    xcodebuild -project proxyAudioDevice.xcodeproj \
      -scheme "Proxy Audio Device Settings" -configuration Debug \
      MACOSX_DEPLOYMENT_TARGET=12.0 CODE_SIGNING_ALLOWED=NO build

For local builds made with code signing disabled, ad-hoc sign both products
before installation. Run these commands in the build products directory:

    codesign --force --sign - ProxyAudioDevice.driver
    codesign --force --sign - "Proxy Audio Device.app"

Keep the original signatures when installing already-signed release artifacts.

The portable equalizer DSP tests can be run without installing the driver:

    clang++ -std=c++11 -O2 -Wall -Wextra -pedantic \
      tests/EqualizerTests.cpp -o /tmp/proxy-audio-eq-tests
    /tmp/proxy-audio-eq-tests

Native menu/window/control tests use a mock HAL, so they do not change the
installed audio driver. They briefly open test windows:

    clang++ -std=c++14 -fobjc-arc -fblocks \
      -Ishared -IproxyAudioDevice -IproxyAudioDevice/PublicUtility \
      -x objective-c++ tests/EqualizerUITests.mm \
      ProxyAudioDeviceSettings/EqualizerWindowController.mm \
      ProxyAudioDeviceSettings/AppDelegate.m \
      -framework Cocoa -framework CoreAudio -o /tmp/proxy-audio-eq-ui-tests
    /tmp/proxy-audio-eq-ui-tests

Driver property and persistence tests also use an isolated mock host/HAL:

    clang++ -std=c++11 -O2 -fblocks -DDEBUG=0 \
      -Ishared -IproxyAudioDevice -IproxyAudioDevice/PublicUtility \
      tests/EqualizerDriverTests.cpp proxyAudioDevice/ProxyAudioDevice.cpp \
      proxyAudioDevice/AudioRingBuffer.cpp proxyAudioDevice/utilities.cpp \
      proxyAudioDevice/PublicUtility/*.cpp shared/AudioDevice.cpp \
      -framework Cocoa -framework CoreAudio -framework Carbon -framework IOKit \
      -o /tmp/proxy-audio-eq-driver-tests
    /tmp/proxy-audio-eq-driver-tests

Settings routing tests simulate device connections and default-output changes
without changing the real macOS output or the installed driver's settings:

    clang++ -std=c++14 -fobjc-arc -fblocks \
      -Ishared -IproxyAudioDevice -IproxyAudioDevice/PublicUtility \
      tests/SettingsRoutingTests.mm ProxyAudioDeviceSettings/WindowDelegate.mm \
      -framework Cocoa -framework CoreAudio -o /tmp/proxy-audio-routing-tests
    /tmp/proxy-audio-routing-tests


### Issues

If you make the audio buffer too small then the driver will introduce pops, crackles, or distortion. If you notice that then try increasing the buffer size.


### Possible Future Work

- Indicator in the settings app for when the proxy audio device overruns its buffer and causes audio artifacts
- Proxying more than two channels of audio
- Ability to increase the number of proxy devices
