#include "audio.hpp"

#define MINIAUDIO_IMPLEMENTATION
#include "miniaudio.h"

#include <utility>

// Builds an audio player with no active engine or track yet.
AudioPlayer::AudioPlayer() : initialized(false), engine(nullptr), track(nullptr) {}

// Ensures audio resources are released when the object is destroyed.
AudioPlayer::~AudioPlayer() {
    shutdown();
}

// Initializes the miniaudio engine once and keeps the player ready.
bool AudioPlayer::init() {
    if (initialized) {
        return true;
    }

    engine = new ma_engine;
    if (ma_engine_init(nullptr, engine) != MA_SUCCESS) {
        delete engine;
        engine = nullptr;
        return false;
    }

    track = nullptr;
    initialized = true;
    return true;
}

// Starts a looping background track from disk.
bool AudioPlayer::initLoopingTrack(const std::string& audioPath, float volume) {
    if (!init()) {
        return false;
    }

    if (track != nullptr) {
        return true;
    }

    track = new ma_sound;

    if (ma_sound_init_from_file(engine, audioPath.c_str(), MA_SOUND_FLAG_STREAM, nullptr, nullptr, track) != MA_SUCCESS) {
        delete track;
        track = nullptr;
        return false;
    }

    ma_sound_set_looping(track, MA_TRUE);
    ma_sound_set_volume(track, volume);
    if (ma_sound_start(track) != MA_SUCCESS) {
        ma_sound_uninit(track);
        delete track;
        track = nullptr;
        return false;
    }

    return true;
}

// Plays a one-shot sound effect (kick, whistle, etc.).
bool AudioPlayer::playOneShot(const std::string& audioPath, float volume) {
    if (!init()) {
        return false;
    }

    cleanupFinishedSounds();

    ma_sound* sound = new ma_sound;
    if (ma_sound_init_from_file(engine, audioPath.c_str(), MA_SOUND_FLAG_STREAM, nullptr, nullptr, sound) != MA_SUCCESS) {
        delete sound;
        return false;
    }
    
    ma_sound_set_volume(sound, volume);
    
    bool success = (ma_sound_start(sound) == MA_SUCCESS);
    if (!success) {
        ma_sound_uninit(sound);
        delete sound;
        return false;
    }

    activeSounds.push_back(sound);
    
    return true;
}

void AudioPlayer::cleanupFinishedSounds() {
    for (int i = static_cast<int>(activeSounds.size()) - 1; i >= 0; --i) {
        ma_sound* sound = activeSounds[i];
        if (ma_sound_at_end(sound)) {
            ma_sound_uninit(sound);
            delete sound;
            activeSounds.erase(activeSounds.begin() + i);
        }
    }
}

// Stops sounds and releases all allocated audio objects.
void AudioPlayer::shutdown() {
    for (ma_sound* sound : activeSounds) {
        ma_sound_uninit(sound);
        delete sound;
    }
    activeSounds.clear();

    if (track != nullptr) {
        ma_sound_uninit(track);
        delete track;
        track = nullptr;
    }

    if (engine != nullptr) {
        ma_engine_uninit(engine);
        delete engine;
        engine = nullptr;
    }

    initialized = false;
}
