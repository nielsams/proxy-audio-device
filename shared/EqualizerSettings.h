#ifndef EqualizerSettings_h
#define EqualizerSettings_h

#include <cmath>
#include <cstdint>

namespace Equalizer {
constexpr unsigned bandCount = 10;
constexpr double frequencies[bandCount] = {31.25, 62.5, 125, 250, 500, 1000, 2000, 4000, 8000, 16000};
constexpr uint32_t settingsProperty = 'pEQs';
constexpr uint32_t metersProperty = 'pEQm';

// Versioned CFData payloads for the HAL's CFPropertyList custom properties.
struct Settings {
    uint32_t version = 1;
    uint32_t enabled = 0;
    float preampDB = 0;
    float gainsDB[bandCount] = {};
};

struct Meters {
    uint32_t version = 1;
    float peaks[bandCount] = {};
};

inline bool validSettings(const Settings &settings) {
    if (settings.version != 1 || settings.enabled > 1 || !std::isfinite(settings.preampDB)
        || settings.preampDB < -24 || settings.preampDB > 0) {
        return false;
    }
    for (float gain : settings.gainsDB) {
        if (!std::isfinite(gain) || gain < -12 || gain > 12) {
            return false;
        }
    }
    return true;
}
}

#endif
