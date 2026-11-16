#include <vector>
#include <CoreAudio/CoreAudio.h>
#import "WindowDelegate.h"
#include "AudioDevice.h"
#include "ProxyAudioDevice.h"

int onDevicesChanged(AudioObjectID inObjectID,
                     UInt32 inNumberAddresses,
                     const AudioObjectPropertyAddress *inAddresses,
                     void *inClientData);

static NSString *const SwitchOnConnectKey = @"SwitchToProxyWhenSourceConnected";
static NSString *const SwitchOnDisconnectKey = @"SwitchToDefaultWhenSourceDisconnected";
static NSString *const FallbackDeviceUIDKey = @"FallbackOutputDeviceUID";
static NSString *const FallbackDeviceNameKey = @"FallbackOutputDeviceName";

@implementation WindowDelegate {
    std::vector<AudioDeviceID> currentDeviceList;
    int initializationAttemptInterval;
    BOOL devicesListenerInstalled;
    NSString *observedSourceUID;
    AudioDeviceID observedSourceID;
    BOOL sourceWasConnected;
    NSString *pendingOutputUID;
    NSTimer *routingRetryTimer;
    unsigned routingAttempts;
    NSTimer *sourceStateRetryTimer;
    unsigned sourceStateAttempts;
}

- (void)awakeFromNib {
    self.deviceNameTextField.stringValue = NSLocalizedString(@"< Loading... >", nil);
    self.deviceNameTextField.enabled = NO;
    self.outputDeviceComboBox.enabled = NO;
    self.bufferSizeComboBox.enabled = NO;
    self.proxiedDeviceIsActiveRadioButton.enabled = NO;
    self.userIsActiveRadioButton.enabled = NO;
    self.alwaysRadioButton.enabled = NO;
    self.hideWhenUnavailableCheckbox.enabled = NO;
    self.switchOnConnectCheckbox.enabled = NO;
    self.switchOnDisconnectCheckbox.enabled = NO;
    self.fallbackDevicePopUp.enabled = NO;
    self.switchOnConnectCheckbox.state = [[self routingDefaults] boolForKey:SwitchOnConnectKey];
    self.switchOnDisconnectCheckbox.state = [[self routingDefaults] boolForKey:SwitchOnDisconnectKey];
    initializationAttemptInterval = 3;
    [self keepTryingToInitializeUntilSuccess];
}

- (void)keepTryingToInitializeUntilSuccess {
    // For some reason, sometimes when the app launches right after the system boots we'll get bunk data
    // for all of the connected audio devices. If that happens then we'll try to initialize again after
    // a few seconds. We're initially waiting three seconds because that seems to work. Using less time
    // can actually cause the audio server to crash, so we want to be careful not to query it too often!
    bool success = [self initialize];
    
    if (!success) {
        NSLog(@"NB: failed to initialize, will try again in a sec...");
        [NSTimer scheduledTimerWithTimeInterval:initializationAttemptInterval target:self selector:@selector(keepTryingToInitializeUntilSuccess) userInfo:nil repeats:NO];
        // Increase the length of time between attempting to initialize by two seconds each time, just to be safe:
        initializationAttemptInterval += 2;
    }
}

- (bool)initialize {
    if (![self setCurrentProcessAsConfigurator]) {
        return false;
    }
    
    self.deviceNameTextField.stringValue = [self currentDeviceName];
    
    if (![self proxyAudioDeviceAvailable]) {
        // It's expected that we won't find the Proxy Audio Device if it's not installed, so this
        // technically isn't a failure case where we'd want to try initializing the app again.
        return true;
    }
    
    if (![self refreshOutputDevices]) {
        return false;
    }
    
    if (![self setupListenerForCurrentAudioDevices]) {
        return false;
    }
    
    [self.bufferSizeComboBox selectItemWithObjectValue:[self currentOutputDeviceBufferFrameSize]];
    self.deviceNameTextField.enabled = YES;
    self.outputDeviceComboBox.enabled = YES;
    self.bufferSizeComboBox.enabled = YES;
    self.proxiedDeviceIsActiveRadioButton.enabled = YES;
    self.userIsActiveRadioButton.enabled = YES;
    self.alwaysRadioButton.enabled = YES;
    self.hideWhenUnavailableCheckbox.enabled = YES;
    self.switchOnConnectCheckbox.enabled = YES;
    self.switchOnDisconnectCheckbox.enabled = YES;
    self.hideWhenUnavailableCheckbox.state =
        [self currentHideWhenUnavailable] ? NSControlStateValueOn : NSControlStateValueOff;

    ProxyAudioDevice::ActiveCondition condition = [self currentOutputDeviceActiveCondition];

    if (condition == ProxyAudioDevice::ActiveCondition::proxiedDeviceActive) {
        self.proxiedDeviceIsActiveRadioButton.state = NSControlStateValueOn;
        self.userIsActiveRadioButton.state = NSControlStateValueOff;
        self.alwaysRadioButton.state = NSControlStateValueOff;
    } else if (condition == ProxyAudioDevice::ActiveCondition::userActive) {
        self.proxiedDeviceIsActiveRadioButton.state = NSControlStateValueOff;
        self.userIsActiveRadioButton.state = NSControlStateValueOn;
        self.alwaysRadioButton.state = NSControlStateValueOff;
    } else {
        self.proxiedDeviceIsActiveRadioButton.state = NSControlStateValueOff;
        self.userIsActiveRadioButton.state = NSControlStateValueOff;
        self.alwaysRadioButton.state = NSControlStateValueOn;
    }

    return true;
}

- (bool)setCurrentProcessAsConfigurator {
    AudioDeviceID proxyAudioBox = AudioDevice::audioDeviceIDForBoxUID(CFSTR(kBox_UID));
    
    if (proxyAudioBox == kAudioObjectUnknown) {
        NSLog(@"Error: unable to find proxy audio device");
        // It's expected that we won't find the Proxy Audio Device if it's not installed, so this
        // technically isn't a failure case where we'd want to try initializing the app again.
        return true;
    }
    
    if (!AudioDevice::setIdentifyValue(proxyAudioBox, getpid())) {
        NSLog(@"Error: unable to set current process as configurator");
        return false;
    }
    
    return true;
}

int onDevicesChanged(AudioObjectID inObjectID,
                     UInt32 inNumberAddresses,
                     const AudioObjectPropertyAddress *inAddresses,
                     void *inClientData) {
#pragma unused(inObjectID, inNumberAddresses, inAddresses)
    dispatch_async(dispatch_get_main_queue(), ^{
        WindowDelegate *delegate = (__bridge WindowDelegate *)inClientData;
        [delegate refreshOutputDevices];
    });

    return noErr;
}

- (bool)setupListenerForCurrentAudioDevices {
    if (devicesListenerInstalled)
        return true;
    AudioObjectPropertyAddress listenerPropertyAddress = {
        kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMaster};
    OSStatus err =
        AudioObjectAddPropertyListener(kAudioObjectSystemObject, &listenerPropertyAddress, &onDevicesChanged, (__bridge_retained void *)self);

    if (err != noErr) {
        CFRelease((__bridge CFTypeRef)self);
        NSLog(@"Error: could not set up listener for audio devices changing");
        return false;
    }
    devicesListenerInstalled = YES;
    return true;
}

- (bool)proxyAudioDeviceAvailable {
    return AudioDevice::audioDeviceIDForBoxUID(CFSTR(kBox_UID)) != kAudioObjectUnknown;
}

- (NSString *)currentDeviceName {
    AudioDeviceID proxyAudioBox = AudioDevice::audioDeviceIDForBoxUID(CFSTR(kBox_UID));
    AudioDevice::setIdentifyValue(proxyAudioBox, -((SInt32)ProxyAudioDevice::ConfigType::deviceName));
    NSString *result = (__bridge_transfer NSString *)AudioDevice::copyObjectName(proxyAudioBox);
    
    return result ? result : NSLocalizedString(@"< Proxy Audio Device not found >", nil);
}

- (IBAction)deviceNameEntered:(id)sender {
#pragma unused(sender)
    NSString *newName = [self.deviceNameTextField.stringValue
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    
    if (newName.length == 0) {
        self.deviceNameTextField.stringValue = [self currentDeviceName];
        return;
    }

    AudioDeviceID proxyAudioBox = AudioDevice::audioDeviceIDForBoxUID(CFSTR(kBox_UID));
    AudioDevice::setObjectName(proxyAudioBox,
                               (__bridge_retained CFStringRef)[NSString stringWithFormat:@"deviceName=%@", newName]);
}

- (AudioDeviceID)currentOutputDevice {
    return AudioDevice::audioDeviceIDForDeviceUID((__bridge CFStringRef)[self currentOutputDeviceUID]);
}

- (NSString *)currentOutputDeviceUID {
    AudioDeviceID proxyAudioBox = AudioDevice::audioDeviceIDForBoxUID(CFSTR(kBox_UID));
    if (proxyAudioBox == kAudioObjectUnknown
        || !AudioDevice::setIdentifyValue(proxyAudioBox, -((SInt32)ProxyAudioDevice::ConfigType::outputDevice))) {
        NSLog(@"Error: unable to read the configured source device");
        return nil;
    }
    NSString *outputDeviceUID = (__bridge_transfer NSString *)AudioDevice::copyObjectName(proxyAudioBox);
    return outputDeviceUID;
}

- (bool)refreshOutputDevices {
    [sourceStateRetryTimer invalidate];
    sourceStateRetryTimer = nil;
    bool success = false;
    [self.outputDeviceComboBox removeAllItems];
    [self.fallbackDevicePopUp removeAllItems];
    self.fallbackDevicePopUp.menu.autoenablesItems = NO;
    [self.fallbackDevicePopUp addItemWithTitle:NSLocalizedString(@"Select a fallback device", nil)];
    self.fallbackDevicePopUp.lastItem.enabled = NO;
    currentDeviceList.clear();
    NSString *sourceUID = [self currentOutputDeviceUID];
    if (!sourceUID.length)
        return false;
    AudioDeviceID outputDevice = AudioDevice::audioDeviceIDForDeviceUID((__bridge CFStringRef)sourceUID);
    NSString *fallbackUID = [[self routingDefaults] stringForKey:FallbackDeviceUIDKey];
    NSString *suggestedUID = nil;
    AudioDeviceID defaultOutput = AudioDevice::defaultOutputDevice();

    for (AudioDeviceID device : AudioDevice::devicesWithOutputCapabilitiesThatAreNotProxyAudioDevice()) {
        NSString *deviceName = (__bridge_transfer NSString *)AudioDevice::copyObjectName(device);
        NSString *uid = (__bridge_transfer NSString *)AudioDevice::copyDeviceUID(device);
        
        if (!deviceName.length || !uid.length) {
            NSLog(@"Error: unable to read the name or UID of output device %u", device);
            continue;
        }
        currentDeviceList.push_back(device);
        [self.outputDeviceComboBox addItemWithObjectValue:deviceName];
        
        if (outputDevice == device) {
            [self.outputDeviceComboBox selectItemAtIndex:currentDeviceList.size() - 1];
        } else {
            [self.fallbackDevicePopUp addItemWithTitle:deviceName];
            self.fallbackDevicePopUp.lastItem.representedObject = uid;
            UInt32 transport = 0, size = sizeof(transport);
            AudioObjectPropertyAddress address = {kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal, 0};
            OSStatus status = AudioObjectGetPropertyData(device, &address, 0, NULL, &size, &transport);
            if (status != noErr) {
                NSLog(@"Error: unable to read output device transport (%d)", status);
            } else if (transport == kAudioDeviceTransportTypeBuiltIn) {
                suggestedUID = uid;
            }
            if (!suggestedUID && device == defaultOutput)
                suggestedUID = uid;
        }
        success = true;
    }
    if (self.outputDeviceComboBox.indexOfSelectedItem < 0)
        self.outputDeviceComboBox.stringValue = NSLocalizedString(@"< Source device disconnected >", nil);
    if (!fallbackUID.length && suggestedUID.length)
        fallbackUID = suggestedUID;
    for (NSMenuItem *item in self.fallbackDevicePopUp.itemArray) {
        if ([item.representedObject isEqual:fallbackUID]) {
            [self.fallbackDevicePopUp selectItem:item];
            [[self routingDefaults] setObject:fallbackUID forKey:FallbackDeviceUIDKey];
            [[self routingDefaults] setObject:item.title forKey:FallbackDeviceNameKey];
            break;
        }
    }
    if (fallbackUID.length && !self.fallbackDevicePopUp.selectedItem.representedObject) {
        NSString *name = [[self routingDefaults] stringForKey:FallbackDeviceNameKey] ?: fallbackUID;
        [self.fallbackDevicePopUp addItemWithTitle:
            [NSString stringWithFormat:NSLocalizedString(@"%@ (unavailable)", nil), name]];
        self.fallbackDevicePopUp.lastItem.representedObject = fallbackUID;
        self.fallbackDevicePopUp.lastItem.enabled = NO;
        [self.fallbackDevicePopUp selectItem:self.fallbackDevicePopUp.lastItem];
    }
    self.fallbackDevicePopUp.enabled = self.fallbackDevicePopUp.numberOfItems > 1;
    if (!success) {
        NSLog(@"Error: failed to get any information about current output devices!");
        return false;
    }
    [self updateAutomaticRoutingForSourceUID:sourceUID device:outputDevice];
    return true;
}

- (IBAction)outputDeviceSelected:(id)sender {
#pragma unused(sender)
    NSInteger index = self.outputDeviceComboBox.indexOfSelectedItem;
    
    if (index < 0 || static_cast<size_t>(index) >= currentDeviceList.size()) {
        NSLog(@"Error: got invalid selection index when trying to set output device");
        return;
    }

    NSString *uid = (__bridge_transfer NSString *)AudioDevice::copyDeviceUID(currentDeviceList[index]);
    
    if (!uid) {
        NSLog(@"Error: got invalid UID when trying to set output device");
        return;
    }

    AudioDeviceID proxyAudioBox = AudioDevice::audioDeviceIDForBoxUID(CFSTR(kBox_UID));
    AudioDevice::setObjectName(proxyAudioBox,
                               (__bridge_retained CFStringRef)[NSString stringWithFormat:@"outputDevice=%@", uid]);
    [self refreshOutputDevices];
}

- (NSUserDefaults *)routingDefaults {
    return [NSUserDefaults standardUserDefaults];
}

- (void)cancelPendingOutputSwitch {
    [routingRetryTimer invalidate];
    routingRetryTimer = nil;
    pendingOutputUID = nil;
}

- (void)attemptPendingOutputSwitch {
    [routingRetryTimer invalidate];
    routingRetryTimer = nil;
    if (!pendingOutputUID || sourceStateRetryTimer)
        return;
    AudioDeviceID device = AudioDevice::audioDeviceIDForDeviceUID((__bridge CFStringRef)pendingOutputUID);
    UInt32 alive = 0, size = sizeof(alive);
    AudioObjectPropertyAddress address = {kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal, 0};
    OSStatus status = device == kAudioObjectUnknown ? kAudioHardwareBadDeviceError
        : AudioObjectGetPropertyData(device, &address, 0, NULL, &size, &alive);
    // A hidden proxy may be published after the source's device-list notification.
    if (status != noErr || !alive) {
        if (++routingAttempts < 5) {
            routingRetryTimer = [NSTimer scheduledTimerWithTimeInterval:1 target:self
                selector:@selector(attemptPendingOutputSwitch) userInfo:nil repeats:NO];
        } else {
            NSLog(@"Error: automatic output switch failed; device %@ is unavailable (%d)", pendingOutputUID, status);
            [self cancelPendingOutputSwitch];
        }
        return;
    }
    if (AudioDevice::defaultOutputDevice() != device) {
        address.mSelector = kAudioHardwarePropertyDefaultOutputDevice;
        status = AudioObjectSetPropertyData(kAudioObjectSystemObject, &address, 0, NULL, sizeof(device), &device);
        if (status != noErr)
            NSLog(@"Error: automatic output switch to %@ failed (%d)", pendingOutputUID, status);
    }
    [self cancelPendingOutputSwitch];
}

- (void)updateAutomaticRoutingForSourceUID:(NSString *)uid device:(AudioDeviceID)device {
    BOOL sourceChanged = ![observedSourceUID isEqualToString:uid];
    if (sourceChanged)
        [self cancelPendingOutputSwitch];
    if (device != observedSourceID) {
        sourceStateAttempts = 0;
        AudioObjectPropertyAddress address = {kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal, 0};
        if (observedSourceID != kAudioObjectUnknown) {
            OSStatus status = AudioObjectRemovePropertyListener(observedSourceID, &address, &onDevicesChanged,
                                                               (__bridge void *)self);
            if (status != noErr && status != kAudioHardwareBadObjectError)
                NSLog(@"Error: unable to remove source connection listener (%d)", status);
        }
        observedSourceID = device;
        if (device != kAudioObjectUnknown) {
            OSStatus status = AudioObjectAddPropertyListener(device, &address, &onDevicesChanged, (__bridge void *)self);
            if (status != noErr)
                NSLog(@"Error: unable to monitor source connection state (%d)", status);
        }
    }
    UInt32 alive = 0, size = sizeof(alive);
    if (device != kAudioObjectUnknown) {
        AudioObjectPropertyAddress address = {kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal, 0};
        OSStatus status = AudioObjectGetPropertyData(device, &address, 0, NULL, &size, &alive);
        if (status != noErr) {
            NSLog(@"Error: unable to read source connection state (%d)", status);
            if (++sourceStateAttempts < 5) {
                sourceStateRetryTimer = [NSTimer scheduledTimerWithTimeInterval:1 target:self
                    selector:@selector(refreshOutputDevices) userInfo:nil repeats:NO];
            } else {
                [self cancelPendingOutputSwitch];
            }
            return;
        }
    }
    sourceStateAttempts = 0;
    BOOL connected = device != kAudioObjectUnknown && alive != 0;
    if (sourceChanged) {
        observedSourceUID = [uid copy];
        sourceWasConnected = connected;
        return;
    }
    if (connected != sourceWasConnected) {
        sourceWasConnected = connected;
        [self cancelPendingOutputSwitch];
        BOOL enabled = [[self routingDefaults] boolForKey:connected ? SwitchOnConnectKey : SwitchOnDisconnectKey];
        if (enabled) {
            pendingOutputUID = connected ? @kDevice_UID : [[self routingDefaults] stringForKey:FallbackDeviceUIDKey];
            routingAttempts = 0;
            if (!pendingOutputUID.length)
                NSLog(@"Error: automatic output switch requires a fallback device selection");
        }
    }
    if (!routingRetryTimer)
        [self attemptPendingOutputSwitch];
}

- (IBAction)automaticSwitchingChanged:(id)sender {
#pragma unused(sender)
    [[self routingDefaults] setBool:self.switchOnConnectCheckbox.state == NSControlStateValueOn forKey:SwitchOnConnectKey];
    [[self routingDefaults] setBool:self.switchOnDisconnectCheckbox.state == NSControlStateValueOn forKey:SwitchOnDisconnectKey];
    [self cancelPendingOutputSwitch];
}

- (IBAction)fallbackDeviceSelected:(id)sender {
#pragma unused(sender)
    NSString *uid = self.fallbackDevicePopUp.selectedItem.representedObject;
    if (!uid.length) {
        NSLog(@"Error: select an available fallback output device");
        return;
    }
    [[self routingDefaults] setObject:uid forKey:FallbackDeviceUIDKey];
    [[self routingDefaults] setObject:self.fallbackDevicePopUp.selectedItem.title forKey:FallbackDeviceNameKey];
    [self cancelPendingOutputSwitch];
}

- (NSString *)currentOutputDeviceBufferFrameSize {
    AudioDeviceID proxyAudioBox = AudioDevice::audioDeviceIDForBoxUID(CFSTR(kBox_UID));
    AudioDevice::setIdentifyValue(proxyAudioBox, -((SInt32)ProxyAudioDevice::ConfigType::outputDeviceBufferFrameSize));
    NSString *result = (__bridge_transfer NSString *)AudioDevice::copyObjectName(proxyAudioBox);
    
    return result ? result : @"";
}

- (IBAction)outputDeviceBufferFrameSizeSelected:(id)sender {
#pragma unused(sender)
    NSString *newBufferFrameSizeString = self.bufferSizeComboBox.objectValueOfSelectedItem;

    if (!newBufferFrameSizeString) {
        NSLog(@"Error: got invalid buffer frame size value");
        return;
    }

    AudioDeviceID proxyAudioBox = AudioDevice::audioDeviceIDForBoxUID(CFSTR(kBox_UID));
    AudioDevice::setObjectName(
        proxyAudioBox,
        (__bridge_retained CFStringRef)
            [NSString stringWithFormat:@"outputDeviceBufferFrameSize=%@", newBufferFrameSizeString]);
}

- (ProxyAudioDevice::ActiveCondition)currentOutputDeviceActiveCondition {
    AudioDeviceID proxyAudioBox = AudioDevice::audioDeviceIDForBoxUID(CFSTR(kBox_UID));
    AudioDevice::setIdentifyValue(proxyAudioBox, -((SInt32)ProxyAudioDevice::ConfigType::deviceActiveCondition));
    NSString *result = (__bridge_transfer NSString *)AudioDevice::copyObjectName(proxyAudioBox);

    return (ProxyAudioDevice::ActiveCondition)[result intValue];
}

- (void)setCurrentOutputDeviceActiveCondition:(ProxyAudioDevice::ActiveCondition)condition {
    AudioDeviceID proxyAudioBox = AudioDevice::audioDeviceIDForBoxUID(CFSTR(kBox_UID));
    AudioDevice::setObjectName(
        proxyAudioBox,
        (__bridge_retained CFStringRef)
            [NSString stringWithFormat:@"outputDeviceActiveCondition=%d", condition]);
}

- (IBAction)proxiedDeviceIsActiveConditionSelected:(id)sender {
    #pragma unused(sender)
    self.alwaysRadioButton.state = NSControlStateValueOff;
    self.userIsActiveRadioButton.state = NSControlStateValueOff;
    [self setCurrentOutputDeviceActiveCondition:ProxyAudioDevice::ActiveCondition::proxiedDeviceActive];
}

- (IBAction)userIsActiveConditionSelected:(id)sender {
    #pragma unused(sender)
    self.alwaysRadioButton.state = NSControlStateValueOff;
    self.proxiedDeviceIsActiveRadioButton.state = NSControlStateValueOff;
    [self setCurrentOutputDeviceActiveCondition:ProxyAudioDevice::ActiveCondition::userActive];
}

- (IBAction)alwaysConditionSelected:(id)sender {
    #pragma unused(sender)
    self.proxiedDeviceIsActiveRadioButton.state = NSControlStateValueOff;
    self.userIsActiveRadioButton.state = NSControlStateValueOff;
    [self setCurrentOutputDeviceActiveCondition:ProxyAudioDevice::ActiveCondition::always];
}

// The driver reports this preference as "1" or "0" (see copyConfigurationValue
// in ProxyAudioDevice.cpp). Anything non-"1" is treated as false.
- (bool)currentHideWhenUnavailable {
    AudioDeviceID proxyAudioBox = AudioDevice::audioDeviceIDForBoxUID(CFSTR(kBox_UID));
    AudioDevice::setIdentifyValue(proxyAudioBox, -((SInt32)ProxyAudioDevice::ConfigType::deviceHideWhenUnavailable));
    NSString *result = (__bridge_transfer NSString *)AudioDevice::copyObjectName(proxyAudioBox);

    return [result intValue] != 0;
}

- (void)setCurrentHideWhenUnavailable:(bool)hide {
    AudioDeviceID proxyAudioBox = AudioDevice::audioDeviceIDForBoxUID(CFSTR(kBox_UID));
    AudioDevice::setObjectName(
        proxyAudioBox,
        (__bridge_retained CFStringRef)
            [NSString stringWithFormat:@"outputDeviceHideWhenUnavailable=%d", hide ? 1 : 0]);
}

- (IBAction)hideWhenUnavailableToggled:(id)sender {
    #pragma unused(sender)
    [self setCurrentHideWhenUnavailable:(self.hideWhenUnavailableCheckbox.state == NSControlStateValueOn)];
}

@end
