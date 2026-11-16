#ifndef Equalizer_h
#define Equalizer_h

#include "../shared/EqualizerSettings.h"
#include <algorithm>
#include <atomic>
#include <cstring>

namespace Equalizer {
struct Coefficients {
    double b0, b1, b2, a1, a2;

    Coefficients(double b0 = 1, double b1 = 0, double b2 = 0, double a1 = 0, double a2 = 0)
        : b0(b0), b1(b1), b2(b2), a1(a1), a2(a2) {}

    void approach(const Coefficients &target, double fraction) {
        b0 += (target.b0 - b0) * fraction;
        b1 += (target.b1 - b1) * fraction;
        b2 += (target.b2 - b2) * fraction;
        a1 += (target.a1 - a1) * fraction;
        a2 += (target.a2 - a2) * fraction;
    }
};

struct Plan {
    uint64_t revision = 0;
    double sampleRate = 44100;
    Coefficients bands[bandCount];
    Coefficients analysis[bandCount];
    double preamp = 1;
    double wet = 0;
    double meterRelease = 0;
};

inline Plan makePlan(const Settings &settings, double sampleRate, uint64_t revision) {
    Plan plan;
    plan.revision = revision;
    plan.sampleRate = sampleRate;
    plan.preamp = std::pow(10.0, settings.preampDB / 20.0);
    plan.wet = settings.enabled ? 1 : 0;
    plan.meterRelease = std::exp(-1.0 / (0.15 * sampleRate));

    for (unsigned band = 0; band < bandCount; ++band) {
        // A band above Nyquist is unavailable, rather than moved to a different frequency.
        if (frequencies[band] >= sampleRate * 0.5) {
            plan.analysis[band].b0 = 0;
            continue;
        }
        const double omega = 2.0 * 3.14159265358979323846 * frequencies[band] / sampleRate;
        const double cosine = std::cos(omega);
        const double alpha = std::sin(omega) / (2.0 * std::sqrt(2.0));
        const double amplitude = std::pow(10.0, settings.gainsDB[band] / 40.0);
        const double a0 = 1.0 + alpha / amplitude;
        plan.bands[band] = { (1.0 + alpha * amplitude) / a0, -2.0 * cosine / a0,
                            (1.0 - alpha * amplitude) / a0, -2.0 * cosine / a0,
                            (1.0 - alpha / amplitude) / a0 };
        plan.analysis[band] = {alpha / (1.0 + alpha), 0, -alpha / (1.0 + alpha),
                               -2.0 * cosine / (1.0 + alpha), (1.0 - alpha) / (1.0 + alpha)};
    }
    return plan;
}

class Processor {
  public:
    Processor() {
        static_assert(ATOMIC_INT_LOCK_FREE == 2, "Meter publication must be lock-free");
        clearMeters();
    }

    void reset() {
        for (auto &band : filters)
            for (auto &channel : band)
                channel = {};
        for (auto &band : analyzers)
            for (auto &channel : band)
                channel = {};
        std::fill(envelopes, envelopes + bandCount, 0);
        clearMeters();
    }

    void setPlan(const Plan &plan) {
        if (plan.revision == target.revision)
            return;
        if (plan.sampleRate != target.sampleRate) {
            reset();
            for (unsigned band = 0; band < bandCount; ++band)
                current[band] = plan.bands[band];
        }
        target = plan;
        rampRemaining = static_cast<unsigned>(plan.sampleRate * 0.02);
    }

    void process(float *interleavedStereo, unsigned frames) {
        for (unsigned frame = 0; frame < frames; ++frame) {
            if (rampRemaining > 0) {
                const double fraction = 1.0 / rampRemaining;
                for (unsigned band = 0; band < bandCount; ++band)
                    current[band].approach(target.bands[band], fraction);
                preamp += (target.preamp - preamp) * fraction;
                wet += (target.wet - wet) * fraction;
                --rampRemaining;
            }
            double output[2];
            for (unsigned channel = 0; channel < 2; ++channel) {
                const double dry = interleavedStereo[frame * 2 + channel];
                double filtered = dry * preamp;
                for (unsigned band = 0; band < bandCount; ++band)
                    filtered = filters[band][channel].process(filtered, current[band]);
                output[channel] = wet == 0 ? dry : dry + wet * (filtered - dry);
                interleavedStereo[frame * 2 + channel] = static_cast<float>(output[channel]);
            }
            for (unsigned band = 0; band < bandCount; ++band) {
                double peak = 0;
                for (unsigned channel = 0; channel < 2; ++channel)
                    peak = std::max(peak, std::abs(analyzers[band][channel].process(output[channel],
                                                                                  target.analysis[band])));
                envelopes[band] = std::max(peak, envelopes[band] * target.meterRelease);
            }
        }
        for (unsigned band = 0; band < bandCount; ++band) {
            const float peak = static_cast<float>(envelopes[band]);
            uint32_t bits;
            std::memcpy(&bits, &peak, sizeof(bits));
            meterBits[band].store(bits, std::memory_order_relaxed);
        }
    }

    void clearMeters() {
        for (auto &value : meterBits)
            value.store(0, std::memory_order_relaxed);
    }

    Meters meters() const {
        Meters result;
        for (unsigned band = 0; band < bandCount; ++band) {
            uint32_t bits = meterBits[band].load(std::memory_order_relaxed);
            std::memcpy(&result.peaks[band], &bits, sizeof(bits));
        }
        return result;
    }

  private:
    struct Filter {
        double x1 = 0, x2 = 0, y1 = 0, y2 = 0;

        double process(double input, const Coefficients &c) {
            const double output = c.b0 * input + c.b1 * x1 + c.b2 * x2 - c.a1 * y1 - c.a2 * y2;
            x2 = x1;
            x1 = input;
            y2 = y1;
            y1 = std::abs(output) < 1e-30 ? 0 : output;
            return output;
        }
    };

    Plan target;
    Coefficients current[bandCount];
    Filter filters[bandCount][2];
    Filter analyzers[bandCount][2];
    double envelopes[bandCount] = {};
    double preamp = 1, wet = 0;
    unsigned rampRemaining = 0;
    std::atomic<uint32_t> meterBits[bandCount];
};
}

#endif
