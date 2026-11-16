#include "../proxyAudioDevice/Equalizer.h"
#include <cstdlib>
#include <iostream>
#include <limits>
#include <stdexcept>
#include <vector>

namespace {
void require(bool condition, const char *message) {
    if (!condition)
        throw std::runtime_error(message);
}

std::vector<float> tone(double sampleRate, double frequency, double amplitude = 0.05, bool right = true) {
    const unsigned frames = static_cast<unsigned>(sampleRate);
    std::vector<float> audio(frames * 2);
    for (unsigned frame = 0; frame < frames; ++frame) {
        audio[frame * 2] = amplitude * std::sin(2 * 3.14159265358979323846 * frequency * frame / sampleRate);
        audio[frame * 2 + 1] = right ? audio[frame * 2] : 0;
    }
    return audio;
}

double energy(const std::vector<float> &audio, unsigned channel) {
    double sum = 0;
    const unsigned start = static_cast<unsigned>(audio.size() / 4) * 2;
    for (unsigned sample = start + channel; sample < audio.size(); sample += 2)
        sum += audio[sample] * audio[sample];
    return sum;
}

void bypassAndChannelIsolation() {
    Equalizer::Settings settings;
    settings.preampDB = -24;
    settings.gainsDB[5] = 12;
    Equalizer::Processor processor;
    auto audio = tone(48000, 1000, 0.05, false);
    const auto original = audio;
    processor.setPlan(Equalizer::makePlan(settings, 48000, 1));
    processor.process(audio.data(), 48000);
    require(audio == original, "Bypass must leave every sample unchanged, including preamp bypass");

    settings.enabled = 1;
    settings.preampDB = 0;
    processor.setPlan(Equalizer::makePlan(settings, 48000, 2));
    processor.process(audio.data(), 48000);
    require(energy(audio, 1) == 0, "Left-channel filtering must not leak into the right channel");
    require(energy(audio, 0) > energy(original, 0) * 15, "The active band should boost the input tone");

    settings.enabled = 0;
    audio = original;
    processor.setPlan(Equalizer::makePlan(settings, 48000, 3));
    processor.process(audio.data(), 48000);
    for (unsigned frame = 1000; frame < 48000; ++frame) {
        require(audio[frame * 2] == original[frame * 2], "Bypass must become exact after the 20 ms transition");
        require(audio[frame * 2 + 1] == 0, "Bypass must preserve silent channels");
    }
}

void frequencyResponse() {
    for (double sampleRate : {22050.0, 44100.0, 48000.0, 88200.0, 96000.0, 176400.0, 192000.0}) {
        for (unsigned band = 0; band < Equalizer::bandCount; ++band) {
            if (Equalizer::frequencies[band] >= sampleRate / 2)
                continue;
            const auto original = tone(sampleRate, Equalizer::frequencies[band]);
            for (float gain : {-12.0f, 0.0f, 12.0f}) {
                Equalizer::Settings settings;
                settings.enabled = 1;
                settings.gainsDB[band] = gain;
                Equalizer::Processor processor;
                processor.setPlan(Equalizer::makePlan(settings, sampleRate, 1));
                auto audio = original;
                processor.process(audio.data(), static_cast<unsigned>(sampleRate));
                const double measuredDB = 10 * std::log10(energy(audio, 0) / energy(original, 0));
                require(std::abs(measuredDB - gain) < 0.1, "Band-center gain must match the requested dB within 0.1 dB");
                for (float sample : audio)
                    require(std::isfinite(sample), "Filter output must remain finite at every supported sample rate");
            }
        }
    }
}

void preampAndMeters() {
    Equalizer::Settings settings;
    settings.enabled = 1;
    settings.preampDB = -12;
    Equalizer::Processor processor;
    auto original = tone(48000, 1000, 0.1);
    auto audio = original;
    processor.setPlan(Equalizer::makePlan(settings, 48000, 1));
    processor.process(audio.data(), 48000);
    const double measuredDB = 10 * std::log10(energy(audio, 0) / energy(original, 0));
    require(std::abs(measuredDB + 12) < 0.01, "Preamp must attenuate amplitude using the 20 log10 convention");
    auto meters = processor.meters();
    require(std::abs(meters.peaks[5] - 0.1 * std::pow(10, -12.0 / 20)) < 0.002,
            "The 1 kHz meter must show actual post-EQ audio energy");
    require(meters.peaks[5] > meters.peaks[4] * 2, "Meters must distinguish frequency bands");
    require(meters.peaks[5] > meters.peaks[6] * 2, "Meters must distinguish frequency bands");
    std::fill(audio.begin(), audio.end(), 0);
    processor.process(audio.data(), 48000);
    require(processor.meters().peaks[5] < 0.0001, "Meters must decay back to silence");
    processor.reset();
    for (float peak : processor.meters().peaks)
        require(peak == 0, "A device reset must clear stale meters");

    settings.enabled = 0;
    processor.setPlan(Equalizer::makePlan(settings, 48000, 2));
    audio = original;
    processor.process(audio.data(), 48000);
    require(processor.meters().peaks[5] > 0.09, "Meters must keep analyzing live audio in bypass");
}

void transitionsAndRateChanges() {
    Equalizer::Settings settings;
    Equalizer::Processor processor;
    uint64_t revision = 0;
    for (double sampleRate : {48000.0, 22050.0, 192000.0, 44100.0}) {
        for (unsigned change = 0; change < 8; ++change) {
            settings.enabled = change % 3 != 0;
            settings.preampDB = change % 2 ? -24 : 0;
            for (float &gain : settings.gainsDB)
                gain = change % 2 ? -12 : 12;
            processor.setPlan(Equalizer::makePlan(settings, sampleRate, ++revision));
            auto audio = tone(sampleRate, 500, 0.005);
            processor.process(audio.data(), 256);
            for (unsigned sample = 0; sample < 512; ++sample)
                require(std::isfinite(audio[sample]) && std::abs(audio[sample]) < 0.1,
                        "Rapid gain/bypass/sample-rate changes must remain bounded and finite");
        }
    }

    settings = {};
    settings.enabled = 1;
    settings.gainsDB[9] = 12;
    processor.reset();
    processor.setPlan(Equalizer::makePlan(settings, 22050, ++revision));
    auto audio = tone(22050, 9000);
    const auto original = audio;
    processor.process(audio.data(), 22050);
    require(std::abs(10 * std::log10(energy(audio, 0) / energy(original, 0))) < 0.01,
            "A band above Nyquist must not be shifted to an audible frequency");
    require(processor.meters().peaks[9] == 0, "An unavailable band must not report audio");

    settings = {};
    settings.enabled = 1;
    settings.gainsDB[5] = 12;
    processor.reset();
    processor.setPlan(Equalizer::makePlan(settings, 48000, ++revision));
    audio = tone(48000, 1000, 0.01);
    processor.process(audio.data(), 48000);
    settings.enabled = 0;
    processor.setPlan(Equalizer::makePlan(settings, 48000, ++revision));
    auto next = tone(48000, 1000, 0.01);
    const float previous = audio.back();
    processor.process(next.data(), 48000);
    require(std::abs(next.front() - previous) < 0.006, "Toggling bypass must not abruptly cut boosted samples");
}

void invalidSettings() {
    Equalizer::Settings settings;
    settings.version = 2;
    require(!Equalizer::validSettings(settings), "Unknown settings versions must be rejected");
    settings = {};
    settings.enabled = 2;
    require(!Equalizer::validSettings(settings), "Invalid bypass values must be rejected");
    settings = {};
    settings.preampDB = 0.5;
    require(!Equalizer::validSettings(settings), "Preamp boosts must be rejected");
    settings.preampDB = -24.5;
    require(!Equalizer::validSettings(settings), "Out-of-range preamp attenuation must be rejected");
    settings.preampDB = std::numeric_limits<float>::quiet_NaN();
    require(!Equalizer::validSettings(settings), "NaN settings must be rejected");
    settings = {};
    settings.gainsDB[0] = 12.5;
    require(!Equalizer::validSettings(settings), "Out-of-range band gains must be rejected");
    settings.gainsDB[0] = -12.5;
    require(!Equalizer::validSettings(settings), "Out-of-range band cuts must be rejected");
    settings.gainsDB[0] = std::numeric_limits<float>::infinity();
    require(!Equalizer::validSettings(settings), "Nonfinite gains must be rejected");
}
}

int main() {
    try {
        invalidSettings();
        bypassAndChannelIsolation();
        frequencyResponse();
        preampAndMeters();
        transitionsAndRateChanges();
        std::cout << "Equalizer tests passed\n";
        return EXIT_SUCCESS;
    } catch (const std::exception &error) {
        std::cerr << "Equalizer test failed: " << error.what() << '\n';
        return EXIT_FAILURE;
    }
}
