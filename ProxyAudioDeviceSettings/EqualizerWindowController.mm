#import "EqualizerWindowController.h"
#include "AudioDevice.h"
#include "EqualizerSettings.h"
#include "ProxyAudioDevice.h"
#include <AudioToolbox/AudioHardwareService.h>

@interface EqualizerMeterView : NSView
@property(nonatomic) float peak;
@end

@implementation EqualizerMeterView
- (BOOL)isOpaque { return YES; }
- (void)setPeak:(float)peak {
    _peak = peak;
    self.needsDisplay = YES;
    self.accessibilityValue = [NSString stringWithFormat:NSLocalizedString(@"%.0f dBFS", nil),
                              20 * log10f(fmaxf(peak, 0.001f))];
}
- (void)drawRect:(NSRect)dirtyRect {
    NSColor *background = [NSColor colorWithWhite:0.08 alpha:1];
    [background setFill];
    NSRectFill(self.bounds);
    const float db = 20 * log10f(fmaxf(self.peak, 0.001f));
    for (unsigned led = 0; led < 20; ++led) {
        const float threshold = -57 + static_cast<int>(led) * 3;
        NSColor *color = led >= 18 ? [NSColor colorWithCalibratedRed:1 green:0.25 blue:0.2 alpha:1]
            : led >= 15 ? [NSColor colorWithCalibratedRed:1 green:0.75 blue:0.15 alpha:1]
            : [NSColor colorWithCalibratedRed:0.25 green:0.85 blue:0.45 alpha:1];
        [(db >= threshold ? color : [color blendedColorWithFraction:0.9 ofColor:background]) setFill];
        NSRectFill(NSMakeRect(3, 3 + led * 7, self.bounds.size.width - 6, 5));
    }
}
@end

@interface EqualizerBackgroundView : NSView
@end

@implementation EqualizerBackgroundView
- (void)drawRect:(NSRect)dirtyRect {
    [[NSColor colorWithWhite:0.12 alpha:1] setFill];
    NSRectFill(self.bounds);
    [[NSColor colorWithWhite:0.17 alpha:1] setFill];
    for (unsigned band = 0; band < Equalizer::bandCount; ++band) {
        [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(24 + band * 76, 80, 68, 334)
                                        xRadius:8 yRadius:8] fill];
    }
}
@end

@implementation EqualizerWindowController {
    NSSegmentedControl *_modeToggle;
    NSButton *_resetButton;
    NSTextField *_statusLabel;
    NSSlider *_preamp;
    NSTextField *_preampValue;
    NSMutableArray<NSSlider *> *_sliders;
    NSMutableArray<NSTextField *> *_values;
    NSMutableArray<EqualizerMeterView *> *_meters;
    NSTimer *_meterTimer;
    NSTimer *_writeTimer;
    Equalizer::Settings _settings;
    AudioObjectID _box;
    BOOL _available;
    unsigned _pollCount;
    Float64 _sampleRate;
    NSLevelIndicator *_masterVolumeIndicator;
    NSTextField *_masterVolumeValue;
}

static NSTextField *EQLabel(NSView *parent, NSString *text, NSRect frame, CGFloat fontSize) {
    NSTextField *label = [[NSTextField alloc] initWithFrame:frame];
    label.stringValue = text;
    label.editable = NO;
    label.selectable = NO;
    label.bezeled = NO;
    label.drawsBackground = NO;
    label.textColor = [NSColor colorWithWhite:0.9 alpha:1];
    label.font = [NSFont systemFontOfSize:fontSize];
    [parent addSubview:label];
    return label;
}

template<typename T>
static bool EQReadOutputProperty(AudioObjectID device, AudioObjectPropertySelector selector,
                                 AudioObjectPropertyElement element, T &value) {
    AudioObjectPropertyAddress address = {selector, kAudioObjectPropertyScopeOutput, element};
    if (!AudioObjectHasProperty(device, &address))
        return false;
    UInt32 size = sizeof(value);
    return AudioObjectGetPropertyData(device, &address, 0, NULL, &size, &value) == noErr && size == sizeof(value);
}

- (instancetype)init {
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 808, 540)
                                                styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                                           | NSWindowStyleMaskMiniaturizable)
                                                  backing:NSBackingStoreBuffered defer:NO];
    self = [super initWithWindow:window];
    if (self) {
        window.title = NSLocalizedString(@"Equalizer - Proxy Audio Device", nil);
        window.releasedWhenClosed = NO;
        window.delegate = self;
        window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameVibrantDark];
        [window center];
        [self buildControls];
    }
    return self;
}

- (void)buildControls {
    NSView *content = [[EqualizerBackgroundView alloc] initWithFrame:self.window.contentView.bounds];
    self.window.contentView = content;
    EQLabel(content, NSLocalizedString(@"Graphic equalizer", nil), NSMakeRect(24, 492, 420, 28), 23);

    _modeToggle = [[NSSegmentedControl alloc] initWithFrame:NSMakeRect(584, 486, 200, 32)];
    _modeToggle.segmentCount = 2;
    _modeToggle.trackingMode = NSSegmentSwitchTrackingSelectOne;
    _modeToggle.segmentStyle = NSSegmentStyleRounded;
    [_modeToggle setLabel:NSLocalizedString(@"Bypass", nil) forSegment:0];
    [_modeToggle setLabel:NSLocalizedString(@"Active", nil) forSegment:1];
    [_modeToggle setWidth:96 forSegment:0];
    [_modeToggle setWidth:96 forSegment:1];
    _modeToggle.accessibilityLabel = NSLocalizedString(@"Equalizer processing", nil);
    _modeToggle.target = self;
    _modeToggle.action = @selector(toggleActive:);
    [content addSubview:_modeToggle];

    EQLabel(content, NSLocalizedString(@"System volume", nil), NSMakeRect(24, 444, 112, 22), 12);
    _masterVolumeIndicator = [[NSLevelIndicator alloc] initWithFrame:NSMakeRect(140, 447, 508, 16)];
    _masterVolumeIndicator.levelIndicatorStyle = NSLevelIndicatorStyleContinuousCapacity;
    _masterVolumeIndicator.minValue = 0;
    _masterVolumeIndicator.maxValue = 1;
    _masterVolumeIndicator.warningValue = 2;
    _masterVolumeIndicator.criticalValue = 2;
    _masterVolumeIndicator.editable = NO;
    _masterVolumeIndicator.accessibilityLabel = NSLocalizedString(@"System output volume", nil);
    [content addSubview:_masterVolumeIndicator];
    _masterVolumeValue = EQLabel(content, @"", NSMakeRect(660, 444, 124, 22), 12);
    _masterVolumeValue.alignment = NSTextAlignmentRight;
    [self updateSystemVolume];

    _statusLabel = EQLabel(content, @"", NSMakeRect(24, 420, 760, 18), 12);
    _statusLabel.textColor = [NSColor colorWithCalibratedRed:1 green:0.6 blue:0.4 alpha:1];
    _statusLabel.hidden = YES;
    _sliders = [NSMutableArray array];
    _values = [NSMutableArray array];
    _meters = [NSMutableArray array];
    NSArray<NSString *> *names = @[@"31", @"63", @"125", @"250", @"500", @"1k", @"2k", @"4k", @"8k", @"16k"];
    for (unsigned band = 0; band < Equalizer::bandCount; ++band) {
        CGFloat x = 24 + band * 76;
        NSTextField *label = EQLabel(content, [NSString stringWithFormat:NSLocalizedString(@"%@ Hz", nil), names[band]],
                                    NSMakeRect(x, 391, 68, 20), 12);
        label.alignment = NSTextAlignmentCenter;
        EqualizerMeterView *meter = [[EqualizerMeterView alloc] initWithFrame:NSMakeRect(x + 22, 238, 24, 146)];
        meter.accessibilityElement = YES;
        meter.accessibilityRole = NSAccessibilityLevelIndicatorRole;
        meter.accessibilityLabel = [NSString stringWithFormat:NSLocalizedString(@"%@ Hz audio level", nil), names[band]];
        meter.toolTip = NSLocalizedString(@"Post-EQ peak level before system volume: green -57 to -15 dBFS, "
                                          "yellow -12 to -6 dBFS, red -3 to 0 dBFS.", nil);
        [content addSubview:meter];
        [_meters addObject:meter];

        NSSlider *slider = [[NSSlider alloc] initWithFrame:NSMakeRect(x + 18, 88, 32, 140)];
        slider.sliderType = NSSliderTypeLinear;
        slider.minValue = -12;
        slider.maxValue = 12;
        slider.numberOfTickMarks = 3;
        slider.allowsTickMarkValuesOnly = NO;
        slider.continuous = YES;
        slider.tag = band;
        slider.target = self;
        slider.action = @selector(bandChanged:);
        slider.accessibilityLabel = [NSString stringWithFormat:NSLocalizedString(@"%@ Hz gain in decibels", nil),
                                    names[band]];
        [content addSubview:slider];
        [_sliders addObject:slider];

        NSTextField *value = EQLabel(content, @"", NSMakeRect(x - 2, 55, 72, 20), 12);
        value.alignment = NSTextAlignmentCenter;
        [_values addObject:value];
    }
    EQLabel(content, NSLocalizedString(@"Preamp", nil), NSMakeRect(24, 18, 60, 22), 12);
    _preamp = [[NSSlider alloc] initWithFrame:NSMakeRect(84, 18, 164, 24)];
    _preamp.minValue = -24;
    _preamp.maxValue = 0;
    _preamp.continuous = YES;
    _preamp.target = self;
    _preamp.action = @selector(preampChanged:);
    _preamp.accessibilityLabel = NSLocalizedString(@"Preamp gain in decibels", nil);
    [content addSubview:_preamp];
    _preampValue = EQLabel(content, @"", NSMakeRect(254, 18, 76, 22), 12);
    _resetButton = [[NSButton alloc] initWithFrame:NSMakeRect(652, 14, 132, 30)];
    _resetButton.title = NSLocalizedString(@"Reset to flat", nil);
    _resetButton.bezelStyle = NSBezelStyleRounded;
    _resetButton.target = self;
    _resetButton.action = @selector(resetToFlat:);
    [content addSubview:_resetButton];
    [self updateControls];
}

- (void)showWindow:(id)sender {
    [super showWindow:sender];
    if (!_meterTimer) {
        [self pollDriver:nil];
        _meterTimer = [NSTimer timerWithTimeInterval:0.05 target:self selector:@selector(pollDriver:)
                                          userInfo:nil repeats:YES];
        [[NSRunLoop mainRunLoop] addTimer:_meterTimer forMode:NSRunLoopCommonModes];
    }
}

- (void)windowWillClose:(NSNotification *)notification {
    [self flushSettings];
    [_meterTimer invalidate];
    _meterTimer = nil;
    _pollCount = 0;
}

- (OSStatus)readProperty:(AudioObjectPropertySelector)selector bytes:(void *)bytes length:(size_t)length {
    AudioObjectPropertyAddress address = {selector, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMaster};
    CFPropertyListRef data = NULL;
    UInt32 size = sizeof(data);
    OSStatus status = AudioObjectGetPropertyData(_box, &address, 0, NULL, &size, &data);
    if (status == noErr) {
        if (size != sizeof(data) || !data || CFGetTypeID(data) != CFDataGetTypeID()
            || CFDataGetLength((CFDataRef)data) != static_cast<CFIndex>(length)) {
            status = kAudioHardwareBadPropertySizeError;
        } else {
            memcpy(bytes, CFDataGetBytePtr((CFDataRef)data), length);
        }
    }
    if (data)
        CFRelease(data);
    return status;
}

- (void)driverUnavailable:(NSString *)message {
    _available = NO;
    _statusLabel.stringValue = message;
    _statusLabel.hidden = NO;
    for (EqualizerMeterView *meter in _meters)
        meter.peak = 0;
    [self updateControls];
}

- (void)pollDriver:(NSTimer *)timer {
    if (_pollCount % 2 == 0)
        [self updateSystemVolume];
    if (_pollCount++ % 20 == 0) {
        _box = AudioDevice::audioDeviceIDForBoxUID(CFSTR(kBox_UID));
        if (_box == kAudioObjectUnknown) {
            [self driverUnavailable:NSLocalizedString(@"Audio driver unavailable. Install the driver to use the equalizer.", nil)];
            return;
        }
        if (!_writeTimer) {
            Equalizer::Settings settings;
            OSStatus status = [self readProperty:Equalizer::settingsProperty bytes:&settings length:sizeof(settings)];
            if (status != noErr || !Equalizer::validSettings(settings)) {
                [self driverUnavailable:NSLocalizedString(@"Equalizer unavailable. Install the matching updated audio driver.", nil)];
                return;
            }
            _settings = settings;
            AudioObjectID device = AudioDevice::audioDeviceIDForDeviceUID(CFSTR(kDevice_UID));
            AudioObjectPropertyAddress rateAddress = {kAudioDevicePropertyNominalSampleRate,
                                                      kAudioObjectPropertyScopeGlobal,
                                                      kAudioObjectPropertyElementMaster};
            UInt32 size = sizeof(_sampleRate);
            status = AudioObjectGetPropertyData(device, &rateAddress, 0, NULL, &size, &_sampleRate);
            if (status != noErr || !std::isfinite(_sampleRate) || _sampleRate <= 0) {
                [self driverUnavailable:NSLocalizedString(@"Could not read the audio sample rate. Reconnecting...", nil)];
                return;
            }
            _available = YES;
            [self updateControls];
        }
    }
    if (!_available)
        return;
    Equalizer::Meters meters;
    OSStatus status = [self readProperty:Equalizer::metersProperty bytes:&meters length:sizeof(meters)];
    if (status != noErr || meters.version != 1) {
        [self driverUnavailable:NSLocalizedString(@"Connection to the audio driver lost. Retrying...", nil)];
        return;
    }
    for (unsigned band = 0; band < Equalizer::bandCount; ++band)
        _meters[band].peak = meters.peaks[band];
}

- (void)updateControls {
    _modeToggle.selectedSegment = _settings.enabled ? 1 : 0;
    _modeToggle.enabled = _available;
    _resetButton.enabled = _available;
    _preamp.enabled = _available;
    _preamp.doubleValue = _settings.preampDB;
    _preampValue.stringValue = [NSString stringWithFormat:NSLocalizedString(@"%.1f dB", nil), _settings.preampDB];
    for (unsigned band = 0; band < Equalizer::bandCount; ++band) {
        const BOOL supported = !_available || Equalizer::frequencies[band] < _sampleRate * 0.5;
        _sliders[band].enabled = _available && supported;
        _sliders[band].doubleValue = _settings.gainsDB[band];
        _sliders[band].toolTip = supported
            ? NSLocalizedString(@"Adjust stereo gain from -12 to +12 dB.", nil)
            : NSLocalizedString(@"This frequency is above the current sample rate's Nyquist limit.", nil);
        _values[band].stringValue = [NSString stringWithFormat:NSLocalizedString(@"%+.1f dB", nil), _settings.gainsDB[band]];
        if (!supported)
            _values[band].stringValue = NSLocalizedString(@"Unavailable", nil);
    }
    if (_available) {
        _statusLabel.stringValue = @"";
        _statusLabel.hidden = YES;
    }
}

- (void)updateSystemVolume {
    AudioObjectID output = AudioDevice::defaultOutputDevice();
    Float32 volume = 0;
    bool readable = output != kAudioObjectUnknown
        && (EQReadOutputProperty(output, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, 0, volume)
            || EQReadOutputProperty(output, kAudioDevicePropertyVolumeScalar, 0, volume));
    if (!readable && output != kAudioObjectUnknown) {
        UInt32 channels[2] = {1, 2};
        EQReadOutputProperty(output, kAudioDevicePropertyPreferredChannelsForStereo, 0, channels);
        Float32 left = 0, right = 0;
        bool hasLeft = EQReadOutputProperty(output, kAudioDevicePropertyVolumeScalar, channels[0], left);
        bool hasRight = EQReadOutputProperty(output, kAudioDevicePropertyVolumeScalar, channels[1], right);
        readable = hasLeft || hasRight;
        // The louder channel represents master volume while preserving stereo balance.
        volume = std::max(left, right);
    }
    readable = readable && std::isfinite(volume) && volume >= 0 && volume <= 1;
    UInt32 mute = 0;
    AudioObjectPropertyAddress muteAddress = {kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput, 0};
    if (readable && AudioObjectHasProperty(output, &muteAddress)
        && !EQReadOutputProperty(output, kAudioDevicePropertyMute, 0, mute))
        readable = false;
    if (!readable) {
        _masterVolumeIndicator.doubleValue = 0;
        _masterVolumeIndicator.alphaValue = 0.35;
        _masterVolumeValue.stringValue = NSLocalizedString(@"Unavailable", nil);
        _masterVolumeIndicator.accessibilityValue = _masterVolumeValue.stringValue;
        return;
    }
    _masterVolumeIndicator.doubleValue = volume;
    _masterVolumeIndicator.alphaValue = mute ? 0.35 : 1;
    _masterVolumeValue.stringValue = mute
        ? [NSString stringWithFormat:NSLocalizedString(@"Muted (%.0f%%)", nil), volume * 100]
        : [NSString stringWithFormat:NSLocalizedString(@"%.0f%%", nil), volume * 100];
    _masterVolumeIndicator.accessibilityValue = _masterVolumeValue.stringValue;
}

- (void)scheduleWrite {
    [self updateControls];
    if (!_writeTimer) {
        _writeTimer = [NSTimer timerWithTimeInterval:0.05 target:self selector:@selector(flushSettingsTimer:)
                                          userInfo:nil repeats:NO];
        [[NSRunLoop mainRunLoop] addTimer:_writeTimer forMode:NSRunLoopCommonModes];
    }
}

- (void)flushSettingsTimer:(NSTimer *)timer {
    [self flushSettings];
}

- (void)flushSettings {
    if (!_writeTimer)
        return;
    [_writeTimer invalidate];
    _writeTimer = nil;
    if (!_available)
        return;
    CFDataRef data = CFDataCreate(NULL, reinterpret_cast<const UInt8 *>(&_settings), sizeof(_settings));
    AudioObjectPropertyAddress address = {Equalizer::settingsProperty, kAudioObjectPropertyScopeGlobal,
                                         kAudioObjectPropertyElementMaster};
    OSStatus status = data ? AudioObjectSetPropertyData(_box, &address, 0, NULL, sizeof(data), &data)
                           : kAudioHardwareUnspecifiedError;
    if (data)
        CFRelease(data);
    if (status != noErr) {
        NSLog(@"Could not save equalizer settings (%d)", status);
        [self driverUnavailable:NSLocalizedString(@"Could not save EQ settings. Reconnecting to the audio driver...", nil)];
    }
}

- (void)toggleActive:(NSSegmentedControl *)sender {
    _settings.enabled = sender.selectedSegment == 1;
    [self scheduleWrite];
}

- (void)bandChanged:(NSSlider *)sender {
    _settings.gainsDB[sender.tag] = roundf(sender.floatValue * 2) / 2;
    [self scheduleWrite];
}

- (void)preampChanged:(NSSlider *)sender {
    _settings.preampDB = roundf(sender.floatValue * 2) / 2;
    [self scheduleWrite];
}

- (void)resetToFlat:(id)sender {
    const uint32_t enabled = _settings.enabled;
    _settings = Equalizer::Settings{};
    _settings.enabled = enabled;
    [self scheduleWrite];
}
@end
