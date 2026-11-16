#import "../ProxyAudioDeviceSettings/WindowDelegate.h"
#import <QuartzCore/QuartzCore.h>
#include "../shared/AudioDevice.h"
#include "../proxyAudioDevice/ProxyAudioDevice.h"
#include <objc/runtime.h>
#include <iostream>
#include <stdexcept>

namespace {
NSUserDefaults *preferences;
NSString *configuredSource = @"usb-source";
AudioDeviceID sourceID = 3, defaultOutput = 2;
bool sourcePresent = true, sourceAlive = true, fallbackPresent = true, proxyPresent = true;
bool failAliveRead = false, failOutputWrite = false;
SInt32 configurationToRead = 0;
unsigned outputWrites = 0;
struct Listener {
    AudioObjectID object;
    AudioObjectPropertyAddress address;
    AudioObjectPropertyListenerProc callback;
    void *context;
};
std::vector<Listener> listeners;

void require(bool condition, const char *message) {
    if (!condition)
        throw std::runtime_error(message);
}
NSUserDefaults *testPreferences(id object, SEL selector) {
    return preferences;
}
NSString *uidForDevice(AudioDeviceID device) {
    if (device == 1) return @kDevice_UID;
    if (device == 2) return @"built-in";
    if (device == sourceID) return @"usb-source";
    if (device == 4) return @"alternate";
    return @"unnamed";
}
void notify(AudioObjectID object, AudioObjectPropertySelector selector) {
    AudioObjectPropertyAddress address = {selector, kAudioObjectPropertyScopeGlobal, 0};
    auto snapshot = listeners;
    for (const auto &listener : snapshot) {
        if (listener.object == object && listener.address.mSelector == selector)
            listener.callback(object, 1, &address, listener.context);
    }
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
}
}

// All device discovery, configuration, listeners, and output writes are isolated from the real HAL.
std::vector<AudioObjectID> AudioDevice::devicesWithOutputCapabilitiesThatAreNotProxyAudioDevice() {
    std::vector<AudioObjectID> devices = {5, 2};
    if (sourcePresent) devices.push_back(sourceID);
    if (fallbackPresent) devices.push_back(4);
    return devices;
}
AudioDeviceID AudioDevice::audioDeviceIDForBoxUID(CFStringRef uid) { return 100; }
AudioDeviceID AudioDevice::audioDeviceIDForDeviceUID(CFStringRef uid) {
    NSString *value = (__bridge NSString *)uid;
    if ([value isEqualToString:@kDevice_UID]) return proxyPresent ? 1 : kAudioObjectUnknown;
    if ([value isEqualToString:@"built-in"]) return 2;
    if ([value isEqualToString:@"usb-source"]) return sourcePresent ? sourceID : kAudioObjectUnknown;
    if ([value isEqualToString:@"alternate"]) return fallbackPresent ? 4 : kAudioObjectUnknown;
    return kAudioObjectUnknown;
}
AudioObjectID AudioDevice::defaultOutputDevice() { return defaultOutput; }
CFStringRef AudioDevice::copyDeviceUID(AudioObjectID device) {
    return (__bridge_retained CFStringRef)uidForDevice(device);
}
CFStringRef AudioDevice::copyObjectName(AudioObjectID device) {
    NSString *name = nil;
    if (device == 100) {
        switch (static_cast<ProxyAudioDevice::ConfigType>(-configurationToRead)) {
            case ProxyAudioDevice::ConfigType::outputDevice: name = configuredSource; break;
            case ProxyAudioDevice::ConfigType::deviceName: name = @"Equalizer Audio"; break;
            case ProxyAudioDevice::ConfigType::outputDeviceBufferFrameSize: name = @"512"; break;
            default: name = @"0"; break;
        }
    } else if (device == 2) {
        name = @"MacBook Pro Speakers";
    } else if (device == sourceID) {
        name = @"USB Audio";
    } else if (device == 4) {
        name = @"Other Speakers";
    }
    return (__bridge_retained CFStringRef)name;
}
bool AudioDevice::setIdentifyValue(AudioDeviceID device, SInt32 value) {
    configurationToRead = value;
    return true;
}
void AudioDevice::setObjectName(AudioObjectID device, CFStringRef name) {
    NSString *value = (__bridge NSString *)name;
    require([value hasPrefix:@"outputDevice="], "Only a deliberate source selection may configure the driver");
    configuredSource = [value substringFromIndex:[@"outputDevice=" length]];
}
OSStatus AudioObjectGetPropertyData(AudioObjectID device, const AudioObjectPropertyAddress *address,
                                   UInt32 qualifierSize, const void *qualifier, UInt32 *size, void *data) {
    require(address->mScope == kAudioObjectPropertyScopeGlobal, "Routing must use global properties");
    if (address->mSelector == kAudioDevicePropertyDeviceIsAlive) {
        if (device == sourceID && failAliveRead)
            return kAudioHardwareUnspecifiedError;
        *static_cast<UInt32 *>(data) = device == sourceID ? sourceAlive : 1;
    } else if (address->mSelector == kAudioDevicePropertyTransportType) {
        *static_cast<UInt32 *>(data) = device == 2 ? kAudioDeviceTransportTypeBuiltIn : kAudioDeviceTransportTypeUSB;
    } else {
        throw std::runtime_error("Unexpected HAL read");
    }
    *size = sizeof(UInt32);
    return noErr;
}
OSStatus AudioObjectSetPropertyData(AudioObjectID object, const AudioObjectPropertyAddress *address,
                                   UInt32 qualifierSize, const void *qualifier, UInt32 size, const void *data) {
    require(object == kAudioObjectSystemObject && address->mSelector == kAudioHardwarePropertyDefaultOutputDevice
            && address->mScope == kAudioObjectPropertyScopeGlobal && size == sizeof(AudioDeviceID),
            "Automatic routing must only change the main default output");
    ++outputWrites;
    if (failOutputWrite)
        return kAudioHardwareUnspecifiedError;
    defaultOutput = *static_cast<const AudioDeviceID *>(data);
    return noErr;
}
OSStatus AudioObjectAddPropertyListener(AudioObjectID object, const AudioObjectPropertyAddress *address,
                                       AudioObjectPropertyListenerProc callback, void *context) {
    listeners.push_back({object, *address, callback, context});
    return noErr;
}
OSStatus AudioObjectRemovePropertyListener(AudioObjectID object, const AudioObjectPropertyAddress *address,
                                          AudioObjectPropertyListenerProc callback, void *context) {
    for (auto it = listeners.begin(); it != listeners.end(); ++it) {
        if (it->object == object && it->address.mSelector == address->mSelector
            && it->callback == callback && it->context == context) {
            listeners.erase(it);
            return noErr;
        }
    }
    return kAudioHardwareBadObjectError;
}

@interface WindowDelegate (RoutingTesting)
- (NSUserDefaults *)routingDefaults;
- (bool)refreshOutputDevices;
- (void)attemptPendingOutputSwitch;
@end

static WindowDelegate *makeDelegate() {
    WindowDelegate *delegate = [[WindowDelegate alloc] init];
    delegate.deviceNameTextField = [[NSTextField alloc] init];
    delegate.outputDeviceComboBox = [[NSComboBox alloc] init];
    delegate.bufferSizeComboBox = [[NSComboBox alloc] init];
    [delegate.bufferSizeComboBox addItemWithObjectValue:@"512"];
    delegate.proxiedDeviceIsActiveRadioButton = [[NSButton alloc] init];
    delegate.userIsActiveRadioButton = [[NSButton alloc] init];
    delegate.alwaysRadioButton = [[NSButton alloc] init];
    delegate.hideWhenUnavailableCheckbox = [[NSButton alloc] init];
    delegate.switchOnConnectCheckbox = [[NSButton alloc] init];
    delegate.switchOnDisconnectCheckbox = [[NSButton alloc] init];
    delegate.fallbackDevicePopUp = [[NSPopUpButton alloc] init];
    [delegate awakeFromNib];
    return delegate;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSString *suite = [@"ProxyAudioRoutingTests." stringByAppendingString:NSUUID.UUID.UUIDString];
        preferences = [[NSUserDefaults alloc] initWithSuiteName:suite];
        Method method = class_getInstanceMethod([WindowDelegate class], @selector(routingDefaults));
        IMP original = method_setImplementation(method, reinterpret_cast<IMP>(&testPreferences));
        int result = 0;
        try {
            [NSApplication sharedApplication];
            [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
            WindowDelegate *delegate = makeDelegate();
            require(outputWrites == 0 && !delegate.switchOnConnectCheckbox.state
                    && !delegate.switchOnDisconnectCheckbox.state,
                    "Startup must not switch outputs, and both policies must default to off");
            require([delegate.fallbackDevicePopUp.selectedItem.representedObject isEqual:@"built-in"],
                    "Built-in speakers must be the initial fallback");

            delegate.switchOnConnectCheckbox.state = NSControlStateValueOn;
            [delegate automaticSwitchingChanged:delegate.switchOnConnectCheckbox];
            notify(kAudioObjectSystemObject, kAudioHardwarePropertyDevices);
            require(outputWrites == 0, "Enabling a policy and unrelated device notifications must not switch outputs");
            sourcePresent = false;
            notify(kAudioObjectSystemObject, kAudioHardwarePropertyDevices);
            require(outputWrites == 0, "The disconnect policy must remain independent");
            sourceID = 7;
            sourcePresent = true;
            proxyPresent = false;
            notify(kAudioObjectSystemObject, kAudioHardwarePropertyDevices);
            require(outputWrites == 0 && [delegate valueForKey:@"pendingOutputUID"] != nil,
                    "Connecting a source must wait for a hidden proxy to become available");
            proxyPresent = true;
            [delegate attemptPendingOutputSwitch];
            require(defaultOutput == 1 && outputWrites == 1, "Connection must select the proxy by stable UID");
            defaultOutput = 4;
            notify(kAudioObjectSystemObject, kAudioHardwarePropertyDevices);
            require(defaultOutput == 4 && outputWrites == 1, "Unrelated changes must preserve manual output selection");

            delegate.switchOnConnectCheckbox.state = NSControlStateValueOff;
            delegate.switchOnDisconnectCheckbox.state = NSControlStateValueOn;
            [delegate automaticSwitchingChanged:delegate.switchOnDisconnectCheckbox];
            sourcePresent = false;
            notify(kAudioObjectSystemObject, kAudioHardwarePropertyDevices);
            require(defaultOutput == 2 && outputWrites == 2, "Disconnect must select the saved fallback");
            defaultOutput = 4;
            sourcePresent = true;
            notify(kAudioObjectSystemObject, kAudioHardwarePropertyDevices);
            require(defaultOutput == 4 && outputWrites == 2, "The disabled connect policy must not switch outputs");

            [delegate.fallbackDevicePopUp selectItemAtIndex:
                [delegate.fallbackDevicePopUp indexOfItemWithRepresentedObject:@"alternate"]];
            [delegate fallbackDeviceSelected:delegate.fallbackDevicePopUp];
            defaultOutput = 1;
            sourceAlive = false;
            notify(sourceID, kAudioDevicePropertyDeviceIsAlive);
            require(defaultOutput == 4 && outputWrites == 3,
                    "An alive-state change must select a user-chosen fallback even if the source stays enumerated");
            sourceAlive = true;
            notify(sourceID, kAudioDevicePropertyDeviceIsAlive);
            fallbackPresent = false;
            defaultOutput = 1;
            sourcePresent = false;
            notify(kAudioObjectSystemObject, kAudioHardwarePropertyDevices);
            for (unsigned attempt = 0; attempt < 5; ++attempt)
                [delegate attemptPendingOutputSwitch];
            require(defaultOutput == 1 && outputWrites == 3
                    && [delegate.fallbackDevicePopUp.selectedItem.representedObject isEqual:@"alternate"]
                    && [delegate valueForKey:@"pendingOutputUID"] == nil,
                    "An unavailable fallback must be remembered, not silently replaced or retried forever");

            delegate.switchOnConnectCheckbox.state = NSControlStateValueOn;
            [delegate automaticSwitchingChanged:delegate.switchOnConnectCheckbox];
            sourcePresent = true;
            failAliveRead = true;
            notify(kAudioObjectSystemObject, kAudioHardwarePropertyDevices);
            require(outputWrites == 3, "A failed state read must not invent a connection transition");
            failAliveRead = false;
            failOutputWrite = true;
            defaultOutput = 2;
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1.1]];
            require(defaultOutput == 2 && outputWrites == 4, "A failed output write must not claim success");
            failOutputWrite = false;
            notify(kAudioObjectSystemObject, kAudioHardwarePropertyDevices);
            require(outputWrites == 4, "Duplicate notifications must not repeat a failed or completed transition");

            fallbackPresent = true;
            configuredSource = @"alternate";
            notify(kAudioObjectSystemObject, kAudioHardwarePropertyDevices);
            require(defaultOutput == 2 && outputWrites == 4, "Changing the configured source must establish a new baseline");
            [delegate.outputDeviceComboBox selectItemAtIndex:1];
            [delegate outputDeviceSelected:delegate.outputDeviceComboBox];
            require([configuredSource isEqual:@"usb-source"],
                    "Source selection must stay aligned when an unnamed device is skipped");
            sourcePresent = false;
            notify(kAudioObjectSystemObject, kAudioHardwarePropertyDevices);
            unsigned writesBeforeRetry = outputWrites;
            sourcePresent = true;
            proxyPresent = false;
            notify(kAudioObjectSystemObject, kAudioHardwarePropertyDevices);
            sourcePresent = false;
            notify(kAudioObjectSystemObject, kAudioHardwarePropertyDevices);
            proxyPresent = true;
            [delegate attemptPendingOutputSwitch];
            require(defaultOutput == 4 && outputWrites == writesBeforeRetry,
                    "A quick disconnect must cancel the delayed switch to a hidden proxy");
            sourcePresent = true;
            proxyPresent = false;
            notify(kAudioObjectSystemObject, kAudioHardwarePropertyDevices);
            delegate.switchOnConnectCheckbox.state = NSControlStateValueOff;
            [delegate automaticSwitchingChanged:delegate.switchOnConnectCheckbox];
            proxyPresent = true;
            [delegate attemptPendingOutputSwitch];
            require(defaultOutput == 4 && outputWrites == writesBeforeRetry,
                    "Disabling automatic switching must cancel a pending retry");
            delegate.switchOnConnectCheckbox.state = NSControlStateValueOn;
            [delegate automaticSwitchingChanged:delegate.switchOnConnectCheckbox];
            WindowDelegate *restored = makeDelegate();
            require(restored.switchOnConnectCheckbox.state && restored.switchOnDisconnectCheckbox.state
                    && [restored.fallbackDevicePopUp.selectedItem.representedObject isEqual:@"alternate"]
                    && outputWrites == writesBeforeRetry,
                    "Preferences must survive controller recreation without switching outputs");

            if (argc > 1) {
                NSBundle *bundle = [NSBundle bundleWithPath:[NSString stringWithUTF8String:argv[1]]];
                NSNib *nib = [[NSNib alloc] initWithNibNamed:@"MainMenu" bundle:bundle];
                NSArray *objects = nil;
                require([nib instantiateWithOwner:NSApp topLevelObjects:&objects], "The built settings nib must load");
                WindowDelegate *settings = nil;
                NSWindow *window = nil;
                for (id object in objects) {
                    if ([object isKindOfClass:[WindowDelegate class]]) settings = object;
                    if ([object isKindOfClass:[NSWindow class]]) window = object;
                }
                require(settings && window && settings.switchOnConnectCheckbox.target == settings
                        && settings.switchOnDisconnectCheckbox.target == settings
                        && settings.fallbackDevicePopUp.target == settings,
                        "The native settings window must wire both policies and fallback selection");
                require([settings.fallbackDevicePopUp.title isEqualToString:@"Other Speakers"],
                        "The native fallback button must display the saved device name");
                bool hasSourceLabel = false;
                for (NSView *view in window.contentView.subviews) {
                    if ([view isKindOfClass:[NSTextField class]])
                        hasSourceLabel |= [static_cast<NSTextField *>(view).stringValue isEqual:@"Source device:"];
                }
                require(hasSourceLabel, "The settings window must label the source device");
                for (NSButton *checkbox in @[settings.switchOnConnectCheckbox, settings.switchOnDisconnectCheckbox])
                    require(checkbox.cell.cellSize.width <= checkbox.frame.size.width,
                            "Automatic switching checkbox text must fit without clipping");
                require(NSMaxY(settings.fallbackDevicePopUp.frame) < NSMinY(settings.switchOnDisconnectCheckbox.frame)
                        && NSMaxY(settings.switchOnDisconnectCheckbox.frame) < NSMinY(settings.switchOnConnectCheckbox.frame),
                        "The added settings controls must not overlap");
                if (argc > 2) {
                    window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
                    window.contentView.layer.backgroundColor = NSColor.windowBackgroundColor.CGColor;
                    [NSApp activateIgnoringOtherApps:YES];
                    [window orderFront:nil];
                    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.15]];
                    [window display];
                    NSBitmapImageRep *image = [window.contentView bitmapImageRepForCachingDisplayInRect:window.contentView.bounds];
                    [window.contentView cacheDisplayInRect:window.contentView.bounds toBitmapImageRep:image];
                    require([[image representationUsingType:NSBitmapImageFileTypePNG properties:@{}]
                        writeToFile:[NSString stringWithUTF8String:argv[2]] atomically:YES], "Settings preview must save");
                    [window close];
                }
            }
            std::cout << "Settings routing tests passed (mock HAL; real audio and preferences untouched)\n";
        } catch (const std::exception &error) {
            std::cerr << error.what() << '\n';
            result = 1;
        }
        method_setImplementation(method, original);
        [preferences removePersistentDomainForName:suite];
        return result;
    }
}
