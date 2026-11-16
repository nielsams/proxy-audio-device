#import "../ProxyAudioDeviceSettings/AppDelegate.h"
#import "../ProxyAudioDeviceSettings/EqualizerWindowController.h"
#include "../shared/AudioDevice.h"
#include "../shared/EqualizerSettings.h"
#include <AudioToolbox/AudioHardwareService.h>
#include <iostream>
#include <stdexcept>

namespace {
Equalizer::Settings storedSettings;
Equalizer::Meters liveMeters;
Float64 sampleRate = 48000;
bool driverPresent = true;
bool supportsEQ = true;
bool failWrite = false;
unsigned writeCount = 0;
AudioObjectID defaultOutput = 3;
Float32 systemVolume = 0.25, leftVolume = 0.3, rightVolume = 0.7;
bool systemMuted = false;
bool virtualVolumeAvailable = true;
bool mainVolumeAvailable = false;
bool channelVolumesAvailable = false;
bool volumeReadFails = false;
bool muteReadFails = false;

void require(bool condition, const char *message) {
    if (!condition)
        throw std::runtime_error(message);
}
}

// Link-time HAL substitutes keep these UI tests away from the installed audio driver.
AudioDeviceID AudioDevice::audioDeviceIDForBoxUID(CFStringRef uid) {
    return driverPresent ? 2 : kAudioObjectUnknown;
}
AudioDeviceID AudioDevice::audioDeviceIDForDeviceUID(CFStringRef uid) {
    return driverPresent ? 3 : kAudioObjectUnknown;
}
AudioObjectID AudioDevice::defaultOutputDevice() {
    return defaultOutput;
}

Boolean AudioObjectHasProperty(AudioObjectID object, const AudioObjectPropertyAddress *address) {
    if (object != defaultOutput || object == kAudioObjectUnknown)
        return false;
    if (address->mSelector == kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        return virtualVolumeAvailable && address->mElement == 0;
    if (address->mSelector == kAudioDevicePropertyVolumeScalar)
        return address->mElement == 0 ? mainVolumeAvailable : channelVolumesAvailable;
    return address->mSelector == kAudioDevicePropertyMute;
}

OSStatus AudioObjectGetPropertyData(AudioObjectID object, const AudioObjectPropertyAddress *address,
                                   UInt32 qualifierSize, const void *qualifier, UInt32 *size, void *data) {
    if (address->mSelector == kAudioHardwareServiceDeviceProperty_VirtualMainVolume
        || address->mSelector == kAudioDevicePropertyVolumeScalar) {
        require(object == defaultOutput, "Volume indicator must follow the current default output");
        if (volumeReadFails)
            return kAudioHardwareBadObjectError;
        *static_cast<Float32 *>(data) = address->mElement == 0 ? systemVolume
            : address->mElement == 1 ? leftVolume : rightVolume;
        *size = sizeof(Float32);
        return noErr;
    }
    if (address->mSelector == kAudioDevicePropertyMute) {
        if (muteReadFails)
            return kAudioHardwareBadObjectError;
        *static_cast<UInt32 *>(data) = systemMuted ? 1 : 0;
        *size = sizeof(UInt32);
        return noErr;
    }
    if (!driverPresent)
        return kAudioHardwareBadObjectError;
    if (address->mSelector == kAudioDevicePropertyNominalSampleRate) {
        *static_cast<Float64 *>(data) = sampleRate;
        *size = sizeof(sampleRate);
        return noErr;
    }
    if (!supportsEQ)
        return kAudioHardwareUnknownPropertyError;
    CFDataRef result;
    if (address->mSelector == Equalizer::settingsProperty) {
        result = CFDataCreate(NULL, reinterpret_cast<const UInt8 *>(&storedSettings), sizeof(storedSettings));
    } else if (address->mSelector == Equalizer::metersProperty) {
        result = CFDataCreate(NULL, reinterpret_cast<const UInt8 *>(&liveMeters), sizeof(liveMeters));
    } else {
        return kAudioHardwareUnknownPropertyError;
    }
    *static_cast<CFPropertyListRef *>(data) = result;
    *size = sizeof(result);
    return noErr;
}

OSStatus AudioObjectSetPropertyData(AudioObjectID object, const AudioObjectPropertyAddress *address,
                                   UInt32 qualifierSize, const void *qualifier, UInt32 size, const void *data) {
    if (failWrite)
        return kAudioHardwareUnspecifiedError;
    require(address->mSelector == Equalizer::settingsProperty, "UI must write the equalizer property");
    require(size == sizeof(CFPropertyListRef), "Settings must travel as a CFPropertyList");
    CFDataRef bytes = *static_cast<const CFDataRef *>(data);
    require(CFGetTypeID(bytes) == CFDataGetTypeID() && CFDataGetLength(bytes) == sizeof(storedSettings),
            "Settings must use the shared versioned payload");
    memcpy(&storedSettings, CFDataGetBytePtr(bytes), sizeof(storedSettings));
    require(Equalizer::validSettings(storedSettings), "UI must send validated settings");
    ++writeCount;
    return noErr;
}

@interface AppDelegate (UITesting)
- (void)showEqualizer:(id)sender;
- (void)showSettings:(id)sender;
@end
@interface EqualizerWindowController (UITesting)
- (void)pollDriver:(NSTimer *)timer;
- (void)updateSystemVolume;
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        try {
            [NSApplication sharedApplication];
            [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
            AppDelegate *delegate = [[AppDelegate alloc] init];
            NSWindow *settingsWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 500, 300)
                                                                 styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable)
                                                                   backing:NSBackingStoreBuffered defer:NO];
            settingsWindow.releasedWhenClosed = NO;
            [delegate setValue:settingsWindow forKey:@"window"];
            [delegate applicationDidFinishLaunching:[NSNotification notificationWithName:NSApplicationDidFinishLaunchingNotification
                                                                                  object:NSApp]];
            NSStatusItem *item = [delegate valueForKey:@"statusItem"];
            require(item.button.image != nil && item.menu.numberOfItems == 4, "Launch must create a status icon and menu");
            require(!settingsWindow.visible, "Launch must not open the settings window");
            require(![delegate applicationShouldTerminateAfterLastWindowClosed:NSApp],
                    "Closing the last window must leave the app running");

            liveMeters.peaks[0] = 0.3;
            liveMeters.peaks[5] = 0.95;
            [item.menu performActionForItemAtIndex:0];
            EqualizerWindowController *controller = [delegate valueForKey:@"equalizerController"];
            require(controller.window.visible, "Equalizer menu item must open the equalizer window");
            NSArray<NSSlider *> *sliders = [controller valueForKey:@"sliders"];
            NSArray<NSView *> *meters = [controller valueForKey:@"meters"];
            NSSegmentedControl *mode = [controller valueForKey:@"modeToggle"];
            require(sliders.count == 10 && meters.count == 10, "EQ must have ten faders and ten live meters");
            require(sliders[0].enabled && mode.selectedSegment == 0, "EQ must begin with Bypass visibly selected");
            require([mode labelForSegment:0].length > 0 && [mode labelForSegment:1].length > 0,
                    "Both processing modes must stay visible");
            for (unsigned band = 0; band < sliders.count; ++band) {
                require(sliders[band].vertical && sliders[band].sliderType == NSSliderTypeLinear
                        && sliders[band].frame.size.height >= 120,
                        "Each band must have an easily adjusted vertical fader");
                require(NSMaxY(sliders[band].frame) < NSMinY(meters[band].frame),
                        "Faders must sit below their own band meters");
            }
            NSTextField *status = [controller valueForKey:@"statusLabel"];
            require(status.hidden, "Normal operation must not display instructional status text");
            require([[meters[5] valueForKey:@"peak"] floatValue] == 0.95f, "LEDs must receive live HAL meter values");
            NSBitmapImageRep *lit = [meters[5] bitmapImageRepForCachingDisplayInRect:meters[5].bounds];
            [meters[5] cacheDisplayInRect:meters[5].bounds toBitmapImageRep:lit];
            NSBitmapImageRep *unlit = [meters[1] bitmapImageRepForCachingDisplayInRect:meters[1].bounds];
            [meters[1] cacheDisplayInRect:meters[1].bounds toBitmapImageRep:unlit];
            require([lit colorAtX:12 y:75].greenComponent > 0.5
                    && [unlit colorAtX:12 y:75].greenComponent < 0.25,
                    "LEDs must visibly light for audio and stay dark in silent bands");

            mode.selectedSegment = 1;
            [mode sendAction:mode.action to:mode.target];
            sliders[5].doubleValue = 6;
            [sliders[5] sendAction:sliders[5].action to:sliders[5].target];
            [controller flushSettings];
            require(storedSettings.enabled == 1 && storedSettings.gainsDB[5] == 6,
                    "Active toggle and fader adjustments must update driver settings");
            require(mode.selectedSegment == 1, "The selected toggle must stay visibly Active");
            require(writeCount == 1, "Rapid control changes should share a throttled write");
            [controller.window close];
            require([controller valueForKey:@"meterTimer"] == nil, "Closing EQ must stop UI polling");
            require(storedSettings.enabled == 1, "Closing EQ must not bypass filtering");
            [item.menu performActionForItemAtIndex:0];
            require([delegate valueForKey:@"equalizerController"] == controller && controller.window.visible,
                    "Reopening EQ must reuse the retained window and controls");

            NSLevelIndicator *volumeIndicator = [controller valueForKey:@"masterVolumeIndicator"];
            NSTextField *volumeValue = [controller valueForKey:@"masterVolumeValue"];
            require(volumeIndicator.doubleValue == 0.25 && [volumeValue.stringValue isEqualToString:@"25%"],
                    "Master indicator must show the system volume setting");
            systemVolume = 0.6;
            [controller updateSystemVolume];
            require(fabs(volumeIndicator.doubleValue - 0.6) < 0.001 && [volumeValue.stringValue isEqualToString:@"60%"],
                    "External system volume changes must update the indicator");
            systemMuted = true;
            [controller updateSystemVolume];
            require([volumeValue.stringValue isEqualToString:@"Muted (60%)"] && volumeIndicator.alphaValue < 1,
                    "Mute must be explicit without losing the saved volume setting");
            systemMuted = false;
            defaultOutput = 7;
            systemVolume = 0.8;
            [controller updateSystemVolume];
            require([volumeValue.stringValue isEqualToString:@"80%"],
                    "Switching the system output must follow the new device's volume");
            virtualVolumeAvailable = false;
            mainVolumeAvailable = true;
            systemVolume = 0.4;
            [controller updateSystemVolume];
            require([volumeValue.stringValue isEqualToString:@"40%"], "Devices with a hardware main volume must work");
            mainVolumeAvailable = false;
            channelVolumesAvailable = true;
            [controller updateSystemVolume];
            require([volumeValue.stringValue isEqualToString:@"70%"],
                    "Channel-only devices must show master volume without averaging away balance");
            channelVolumesAvailable = false;
            [controller updateSystemVolume];
            require([volumeValue.stringValue isEqualToString:@"Unavailable"],
                    "Devices without volume controls must not display a fabricated volume");
            virtualVolumeAvailable = true;
            volumeReadFails = true;
            [controller updateSystemVolume];
            require([volumeValue.stringValue isEqualToString:@"Unavailable"],
                    "A failed volume read must not leave a stale or success-shaped value");
            volumeReadFails = false;
            muteReadFails = true;
            [controller updateSystemVolume];
            require([volumeValue.stringValue isEqualToString:@"Unavailable"],
                    "A failed mute read must not claim the output is unmuted");
            muteReadFails = false;
            defaultOutput = kAudioObjectUnknown;
            [controller updateSystemVolume];
            require([volumeValue.stringValue isEqualToString:@"Unavailable"], "Missing output devices must be explicit");
            require(writeCount == 1, "A read-only volume indicator must never change system volume or EQ");
            defaultOutput = 3;
            systemVolume = 0.25;
            [controller updateSystemVolume];

            if (argc > 1) {
                NSView *view = controller.window.contentView;
                NSBitmapImageRep *image = [view bitmapImageRepForCachingDisplayInRect:view.bounds];
                [view cacheDisplayInRect:view.bounds toBitmapImageRep:image];
                NSData *png = [image representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
                require([png writeToFile:[NSString stringWithUTF8String:argv[1]] atomically:YES],
                        "Could not save UI preview");
            }

            NSButton *reset = [controller valueForKey:@"resetButton"];
            [reset performClick:nil];
            [controller flushSettings];
            require(storedSettings.enabled == 1 && storedSettings.gainsDB[5] == 0 && storedSettings.preampDB == 0,
                    "Reset must flatten gains while preserving Active");
            [controller.window close];
            sampleRate = 22050;
            [item.menu performActionForItemAtIndex:0];
            require(!sliders[9].enabled && sliders[8].enabled, "Bands above Nyquist must be disabled without disabling lower bands");

            failWrite = true;
            mode.selectedSegment = 0;
            [mode sendAction:mode.action to:mode.target];
            [controller flushSettings];
            require(!mode.enabled, "A failed driver write must disable controls and surface an error");
            require(!status.hidden && [status.stringValue containsString:@"Could not save"], "Write failures must be visible");
            require(storedSettings.enabled == 1, "A failed write must not appear persisted");
            [controller.window close];
            failWrite = false;
            supportsEQ = false;
            [item.menu performActionForItemAtIndex:0];
            require(!mode.enabled && [status.stringValue containsString:@"updated audio driver"],
                    "An older driver must show an update instruction, not working controls");
            [controller.window close];
            driverPresent = false;
            [item.menu performActionForItemAtIndex:0];
            require(!mode.enabled && [status.stringValue containsString:@"Install the driver"],
                    "A missing driver must show an installation instruction");
            [controller.window close];

            [item.menu performActionForItemAtIndex:1];
            require(settingsWindow.visible, "Settings menu item must open the settings window");
            [settingsWindow close];
            [item.menu performActionForItemAtIndex:1];
            require(settingsWindow.visible, "Settings window must reopen after being closed");
            [settingsWindow close];
            [delegate applicationWillTerminate:[NSNotification notificationWithName:NSApplicationWillTerminateNotification
                                                                              object:NSApp]];
            std::cout << "Equalizer UI tests passed (mock HAL; installed driver untouched)\n";
            return 0;
        } catch (const std::exception &error) {
            std::cerr << "Equalizer UI test failed: " << error.what() << '\n';
            return 1;
        }
    }
}
