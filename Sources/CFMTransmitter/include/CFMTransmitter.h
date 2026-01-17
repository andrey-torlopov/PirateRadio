/*
 * CFMTransmitter - C interface for fm_transmitter library
 * Allows Swift to call the C++ FM transmitter functionality
 */

#ifndef CFMTRANSMITTER_H
#define CFMTRANSMITTER_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// Opaque handle to the transmitter
typedef struct FMTransmitterHandle* FMTransmitterRef;

// Error codes
typedef enum {
    FM_SUCCESS = 0,
    FM_ERROR_INIT_FAILED = -1,
    FM_ERROR_FILE_NOT_FOUND = -2,
    FM_ERROR_INVALID_FORMAT = -3,
    FM_ERROR_TRANSMISSION_FAILED = -4,
    FM_ERROR_PERMISSION_DENIED = -5,
    FM_ERROR_ALREADY_RUNNING = -6,
    FM_ERROR_NOT_RUNNING = -7
} FMTransmitterError;

// Configuration for transmission
typedef struct {
    float frequency;      // FM frequency in MHz (e.g., 100.0)
    float bandwidth;      // Bandwidth in kHz (default: 200.0)
    uint16_t dmaChannel;  // DMA channel (0-15, default: 0)
    bool loop;            // Loop playback
} FMTransmitterConfig;

// Create default configuration
FMTransmitterConfig fm_transmitter_default_config(void);

// Create a new transmitter instance
FMTransmitterRef fm_transmitter_create(void);

// Destroy transmitter instance
void fm_transmitter_destroy(FMTransmitterRef transmitter);

// Start transmitting a WAV file
// Returns FM_SUCCESS on success, error code on failure
FMTransmitterError fm_transmitter_start_file(
    FMTransmitterRef transmitter,
    const char* filepath,
    const FMTransmitterConfig* config
);

// Start transmitting from stdin (for piped audio)
FMTransmitterError fm_transmitter_start_stdin(
    FMTransmitterRef transmitter,
    const FMTransmitterConfig* config
);

// Stop current transmission
void fm_transmitter_stop(FMTransmitterRef transmitter);

// Check if transmitter is currently running
bool fm_transmitter_is_running(FMTransmitterRef transmitter);

// Get last error message
const char* fm_transmitter_get_error(FMTransmitterRef transmitter);

#ifdef __cplusplus
}
#endif

#endif // CFMTRANSMITTER_H
