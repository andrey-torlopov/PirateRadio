/*
 * CFMTransmitter shim - C wrapper around C++ fm_transmitter
 */

#include "include/CFMTransmitter.h"

#ifdef __linux__
// Real implementation for Raspberry Pi / Linux

#include "transmitter.hpp"
#include "wave_reader.hpp"

#include <string>
#include <mutex>
#include <thread>
#include <atomic>
#include <cstring>

struct FMTransmitterHandle {
    Transmitter* transmitter;
    std::mutex mtx;
    bool enable;
    std::atomic<bool> running;
    std::thread workerThread;
    std::string lastError;
    
    FMTransmitterHandle() 
        : transmitter(nullptr)
        , enable(true)
        , running(false) 
    {}
    
    ~FMTransmitterHandle() {
        stop();
        if (transmitter) {
            delete transmitter;
        }
    }
    
    void stop() {
        {
            std::lock_guard<std::mutex> lock(mtx);
            enable = false;
        }
        if (transmitter) {
            transmitter->Stop();
        }
        if (workerThread.joinable()) {
            workerThread.join();
        }
        running = false;
    }
};

extern "C" {

FMTransmitterConfig fm_transmitter_default_config(void) {
    FMTransmitterConfig config;
    config.frequency = 100.0f;
    config.bandwidth = 200.0f;
    config.dmaChannel = 0;
    config.loop = false;
    return config;
}

FMTransmitterRef fm_transmitter_create(void) {
    try {
        auto handle = new FMTransmitterHandle();
        handle->transmitter = new Transmitter();
        return handle;
    } catch (const std::exception& e) {
        return nullptr;
    }
}

void fm_transmitter_destroy(FMTransmitterRef transmitter) {
    if (transmitter) {
        delete transmitter;
    }
}

FMTransmitterError fm_transmitter_start_file(
    FMTransmitterRef handle,
    const char* filepath,
    const FMTransmitterConfig* config
) {
    if (!handle || !filepath || !config) {
        return FM_ERROR_INIT_FAILED;
    }
    
    if (handle->running) {
        return FM_ERROR_ALREADY_RUNNING;
    }
    
    {
        std::lock_guard<std::mutex> lock(handle->mtx);
        handle->enable = true;
    }
    handle->running = true;
    handle->lastError.clear();
    
    // Capture values for the thread
    std::string path(filepath);
    float frequency = config->frequency;
    float bandwidth = config->bandwidth;
    uint16_t dmaChannel = config->dmaChannel;
    bool loop = config->loop;
    
    handle->workerThread = std::thread([handle, path, frequency, bandwidth, dmaChannel, loop]() {
        try {
            do {
                WaveReader reader(path, handle->enable, handle->mtx);
                handle->transmitter->Transmit(reader, frequency, bandwidth, dmaChannel, false);
            } while (handle->enable && loop);
        } catch (const std::exception& e) {
            handle->lastError = e.what();
        }
        handle->running = false;
    });
    
    return FM_SUCCESS;
}

FMTransmitterError fm_transmitter_start_stdin(
    FMTransmitterRef handle,
    const FMTransmitterConfig* config
) {
    if (!handle || !config) {
        return FM_ERROR_INIT_FAILED;
    }
    
    if (handle->running) {
        return FM_ERROR_ALREADY_RUNNING;
    }
    
    {
        std::lock_guard<std::mutex> lock(handle->mtx);
        handle->enable = true;
    }
    handle->running = true;
    handle->lastError.clear();
    
    float frequency = config->frequency;
    float bandwidth = config->bandwidth;
    uint16_t dmaChannel = config->dmaChannel;
    
    handle->workerThread = std::thread([handle, frequency, bandwidth, dmaChannel]() {
        try {
            // Empty string means read from stdin
            WaveReader reader(std::string(), handle->enable, handle->mtx);
            handle->transmitter->Transmit(reader, frequency, bandwidth, dmaChannel, false);
        } catch (const std::exception& e) {
            handle->lastError = e.what();
        }
        handle->running = false;
    });
    
    return FM_SUCCESS;
}

void fm_transmitter_stop(FMTransmitterRef handle) {
    if (handle) {
        handle->stop();
    }
}

bool fm_transmitter_is_running(FMTransmitterRef handle) {
    return handle && handle->running;
}

const char* fm_transmitter_get_error(FMTransmitterRef handle) {
    if (!handle) {
        return "Invalid handle";
    }
    return handle->lastError.empty() ? nullptr : handle->lastError.c_str();
}

} // extern "C"

#else
// Stub implementation for macOS/other platforms (development only)

#include <string>

struct FMTransmitterHandle {
    bool running;
    std::string lastError;
    
    FMTransmitterHandle() : running(false), lastError("FM transmitter only works on Raspberry Pi (Linux)") {}
};

extern "C" {

FMTransmitterConfig fm_transmitter_default_config(void) {
    FMTransmitterConfig config;
    config.frequency = 100.0f;
    config.bandwidth = 200.0f;
    config.dmaChannel = 0;
    config.loop = false;
    return config;
}

FMTransmitterRef fm_transmitter_create(void) {
    return new FMTransmitterHandle();
}

void fm_transmitter_destroy(FMTransmitterRef transmitter) {
    if (transmitter) {
        delete transmitter;
    }
}

FMTransmitterError fm_transmitter_start_file(
    FMTransmitterRef handle,
    const char* filepath,
    const FMTransmitterConfig* config
) {
    (void)filepath;
    (void)config;
    if (!handle) {
        return FM_ERROR_INIT_FAILED;
    }
    handle->lastError = "FM transmitter only works on Raspberry Pi (Linux)";
    return FM_ERROR_PERMISSION_DENIED;
}

FMTransmitterError fm_transmitter_start_stdin(
    FMTransmitterRef handle,
    const FMTransmitterConfig* config
) {
    (void)config;
    if (!handle) {
        return FM_ERROR_INIT_FAILED;
    }
    handle->lastError = "FM transmitter only works on Raspberry Pi (Linux)";
    return FM_ERROR_PERMISSION_DENIED;
}

void fm_transmitter_stop(FMTransmitterRef handle) {
    if (handle) {
        handle->running = false;
    }
}

bool fm_transmitter_is_running(FMTransmitterRef handle) {
    return handle && handle->running;
}

const char* fm_transmitter_get_error(FMTransmitterRef handle) {
    if (!handle) {
        return "Invalid handle";
    }
    return handle->lastError.c_str();
}

} // extern "C"

#endif // __linux__
