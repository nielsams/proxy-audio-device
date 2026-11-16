#include "../proxyAudioDevice/ProxyAudioDevice.h"
#include <iostream>
#include <stdexcept>

namespace {
CFDataRef stored = NULL;
CFStringRef storedDeviceName = CFSTR("Test Proxy Audio Device");
bool failStorage = false;

void require(bool condition, const char *message) {
    if (!condition)
        throw std::runtime_error(message);
}

OSStatus copyStorage(AudioServerPlugInHostRef, CFStringRef key, CFPropertyListRef *data) {
    if (CFEqual(key, CFSTR("deviceName")))
        *data = storedDeviceName ? CFRetain(storedDeviceName) : NULL;
    else
        *data = CFEqual(key, CFSTR("equalizerSettings")) && stored ? CFRetain(stored) : NULL;
    return noErr;
}

OSStatus writeStorage(AudioServerPlugInHostRef, CFStringRef key, CFPropertyListRef data) {
    if (failStorage)
        return kAudioHardwareUnspecifiedError;
    require(CFEqual(key, CFSTR("equalizerSettings")), "EQ must use its own storage key");
    if (stored)
        CFRelease(stored);
    stored = CFDataCreateCopy(NULL, static_cast<CFDataRef>(data));
    return noErr;
}

Equalizer::Settings readSettings(ProxyAudioDevice &device, AudioServerPlugInDriverRef driver) {
    AudioObjectPropertyAddress address = {Equalizer::settingsProperty, kAudioObjectPropertyScopeGlobal, 0};
    CFPropertyListRef data = NULL;
    UInt32 size = 0;
    require(device.GetPropertyData(driver, kObjectID_Box, 0, &address, 0, NULL,
                                   sizeof(data), &size, &data) == noErr,
            "Settings must be readable through the public HAL entry point");
    require(size == sizeof(data) && data && CFGetTypeID(data) == CFDataGetTypeID(),
            "The driver must return a CFData property list");
    require(CFDataGetLength(static_cast<CFDataRef>(data)) == sizeof(Equalizer::Settings),
            "The driver must return the complete versioned settings payload");
    Equalizer::Settings settings;
    memcpy(&settings, CFDataGetBytePtr(static_cast<CFDataRef>(data)), sizeof(settings));
    CFRelease(data);
    return settings;
}

OSStatus writeSettings(ProxyAudioDevice &device, AudioServerPlugInDriverRef driver, const Equalizer::Settings &settings) {
    CFDataRef data = CFDataCreate(NULL, reinterpret_cast<const UInt8 *>(&settings), sizeof(settings));
    AudioObjectPropertyAddress address = {Equalizer::settingsProperty, kAudioObjectPropertyScopeGlobal, 0};
    OSStatus status = device.SetPropertyData(driver, kObjectID_Box, 0, &address, 0, NULL, sizeof(data), &data);
    CFRelease(data);
    return status;
}
}

// Prevent device discovery and listeners from touching the real HAL during initialization.
OSStatus AudioObjectGetPropertyDataSize(AudioObjectID, const AudioObjectPropertyAddress *,
                                       UInt32, const void *, UInt32 *size) {
    *size = 0;
    return noErr;
}
OSStatus AudioObjectGetPropertyData(AudioObjectID, const AudioObjectPropertyAddress *,
                                   UInt32, const void *, UInt32 *, void *) {
    return kAudioHardwareBadObjectError;
}
OSStatus AudioObjectAddPropertyListener(AudioObjectID, const AudioObjectPropertyAddress *,
                                       AudioObjectPropertyListenerProc, void *) {
    return noErr;
}

int main() {
    try {
        static AudioServerPlugInHostInterface host = {};
        host.CopyFromStorage = copyStorage;
        host.WriteToStorage = writeStorage;
        host.PropertiesChanged = [](AudioServerPlugInHostRef, AudioObjectID, UInt32,
                                     const AudioObjectPropertyAddress *) -> OSStatus { return noErr; };
        auto driver = static_cast<AudioServerPlugInDriverRef>(ProxyAudio_Create(NULL, kAudioServerPlugInTypeUUID));
        ProxyAudioDevice &device = *ProxyAudioDevice::deviceForDriver(driver);
        require(device.Initialize(driver, &host) == noErr, "Driver must initialize with empty storage");
        require(readSettings(device, driver).enabled == 0, "A new installation must default to Bypass");
        CFStringRef name = device.copyDeviceNameFromStorage();
        require(CFEqual(name, storedDeviceName), "User-customized device names must be preserved");
        CFRelease(name);
        storedDeviceName = NULL;
        name = device.copyDeviceNameFromStorage();
        require(CFEqual(name, CFSTR("Equalizer Audio")), "New installations must register as Equalizer Audio");
        CFRelease(name);
        storedDeviceName = CFSTR("Proxy Audio Device");
        name = device.copyDeviceNameFromStorage();
        require(CFEqual(name, CFSTR("Equalizer Audio")), "The previous default device name must migrate on upgrade");
        CFRelease(name);

        AudioObjectPropertyAddress address = {kAudioObjectPropertyCustomPropertyInfoList,
                                              kAudioObjectPropertyScopeGlobal, 0};
        AudioServerPlugInCustomPropertyInfo properties[2];
        UInt32 size = 0;
        require(device.GetPropertyDataSize(driver, kObjectID_Box, 0, &address, 0, NULL, &size) == noErr
                && size == sizeof(properties), "The HAL must discover both custom properties");
        require(device.GetPropertyData(driver, kObjectID_Box, 0, &address, 0, NULL, sizeof(properties),
                                       &size, properties) == noErr
                && properties[0].mSelector == Equalizer::settingsProperty
                && properties[1].mSelector == Equalizer::metersProperty
                && properties[0].mPropertyDataType == kAudioServerPlugInCustomPropertyDataTypeCFPropertyList,
                "The driver must advertise HAL-marshallable property types");
        address.mSelector = Equalizer::metersProperty;
        Boolean settable = true;
        require(device.IsPropertySettable(driver, kObjectID_Box, 0, &address, &settable) == noErr && !settable,
                "Live metering must be read-only");
        address.mSelector = Equalizer::settingsProperty;
        require(device.HasProperty(driver, kObjectID_Box, 0, &address), "Settings property must be discoverable");
        CFPropertyListRef invalid = CFSTR("not equalizer data");
        require(device.SetPropertyData(driver, kObjectID_Box, 0, &address, 0, NULL, sizeof(invalid), &invalid)
                == kAudioHardwareIllegalOperationError, "Wrong payload types must be rejected");

        Equalizer::Settings settings;
        settings.enabled = 1;
        settings.preampDB = -6;
        settings.gainsDB[3] = 4;
        require(writeSettings(device, driver, settings) == noErr, "Valid settings must save");
        require(stored != NULL && readSettings(device, driver).gainsDB[3] == 4,
                "Successful writes must update storage and live settings");

        failStorage = true;
        settings.gainsDB[3] = 8;
        require(writeSettings(device, driver, settings) != noErr && readSettings(device, driver).gainsDB[3] == 4,
                "Storage failure must be returned without applying unsaved settings");
        failStorage = false;
        settings.gainsDB[3] = 13;
        require(writeSettings(device, driver, settings) == kAudioHardwareIllegalOperationError,
                "Out-of-range settings must be rejected at the HAL boundary");

        // Driver instances and their asynchronous timers have process lifetime.
        auto restored = new ProxyAudioDevice;
        require(restored->Initialize(driver, &host) == noErr, "Driver must initialize with persisted EQ settings");
        auto result = readSettings(*restored, driver);
        require(result.enabled == 1 && result.preampDB == -6 && result.gainsDB[3] == 4,
                "Driver initialization must restore saved Active, preamp, and band gains");
        require(restored->PerformDeviceConfigurationChange(driver, kObjectID_Device, 96000, NULL) == noErr
                && readSettings(*restored, driver).gainsDB[3] == 4,
                "Sample-rate changes must preserve EQ preferences");
        CFRelease(stored);
        stored = CFDataCreate(NULL, reinterpret_cast<const UInt8 *>("bad"), 3);
        auto corrupted = new ProxyAudioDevice;
        require(corrupted->Initialize(driver, &host) == noErr && readSettings(*corrupted, driver).enabled == 0,
                "Corrupt persisted payloads must safely start in Bypass");
        std::cout << "Equalizer driver tests passed (mock host/HAL; installed driver untouched)\n";
        return 0;
    } catch (const std::exception &error) {
        std::cerr << "Equalizer driver test failed: " << error.what() << '\n';
        return 1;
    }
}
