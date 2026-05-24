#ifdef __linux__
/*
    FM Transmitter - use Raspberry Pi as FM transmitter

    Copyright (c) 2021, Marcin Kondej
    All rights reserved.

    See https://github.com/markondej/fm_transmitter

    Redistribution and use in source and binary forms, with or without modification, are
    permitted provided that the following conditions are met:

    1. Redistributions of source code must retain the above copyright notice, this list
    of conditions and the following disclaimer.

    2. Redistributions in binary form must reproduce the above copyright notice, this
    list of conditions and the following disclaimer in the documentation and/or other
    materials provided with the distribution.

    3. Neither the name of the copyright holder nor the names of its contributors may be
    used to endorse or promote products derived from this software without specific
    prior written permission.

    THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY
    EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
    OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT
    SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT,
    INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED
    TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR
    BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
    CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY
    WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
*/

#include "wave_reader.hpp"
#include <stdexcept>
#include <cstring>
#include <thread>
#include <chrono>
#include <unistd.h>
#include <fcntl.h>
#include <climits>
#include <cerrno>

namespace {

bool ChunkIdEquals(const uint8_t id[4], const char *expected)
{
    return std::memcmp(id, expected, 4) == 0;
}

void CopyChunkId(uint8_t destination[4], const uint8_t source[4])
{
    std::memcpy(destination, source, 4);
}

}

Sample::Sample(uint8_t *data, unsigned channels, unsigned bitsPerChannel)
    : value(0.f)
{
    int sum = 0;
    int16_t *channelValues = new int16_t[channels];
    for (unsigned i = 0; i < channels; i++) {
        switch (bitsPerChannel >> 3) {
        case 2:
            channelValues[i] = (data[((i + 1) << 1) - 1] << 8) | data[((i + 1) << 1) - 2];
            break;
        case 1:
            channelValues[i] = (static_cast<int16_t>(data[i]) - 0x80) << 8;
            break;
        }
        sum += channelValues[i];
    }
    value = 2 * sum / (static_cast<float>(USHRT_MAX) * channels);
    delete[] channelValues;
}

float Sample::GetMonoValue() const
{
    return value;
}

WaveReader::WaveReader(const std::string &filename, bool &enable, std::mutex &mtx) :
    filename(filename), headerOffset(0), currentDataOffset(0)
{
    if (!filename.empty()) {
        fileDescriptor = open(filename.c_str(), O_RDONLY);
    } else {
        fcntl(STDIN_FILENO, F_SETFL, fcntl(STDIN_FILENO, F_GETFL, 0) | O_NONBLOCK);
        fileDescriptor = STDIN_FILENO;
    }

    if (fileDescriptor == -1) {
        throw std::runtime_error(std::string("Cannot open ") + GetFilename() + std::string(", file does not exist"));
    }

    try {
        std::memset(&header, 0, sizeof(header));

        std::vector<uint8_t> riffHeader = ReadRawData(
            sizeof(WaveHeader::chunkID) + sizeof(WaveHeader::chunkSize) + sizeof(WaveHeader::format),
            true,
            enable,
            mtx
        );
        std::memcpy(header.chunkID, riffHeader.data(), sizeof(WaveHeader::chunkID));
        std::memcpy(&header.chunkSize, riffHeader.data() + sizeof(WaveHeader::chunkID), sizeof(WaveHeader::chunkSize));
        std::memcpy(header.format, riffHeader.data() + sizeof(WaveHeader::chunkID) + sizeof(WaveHeader::chunkSize), sizeof(WaveHeader::format));
        if (!ChunkIdEquals(header.chunkID, "RIFF") || !ChunkIdEquals(header.format, "WAVE")) {
            throw std::runtime_error(std::string("Error while opening ") + GetFilename() + std::string(", WAVE file expected"));
        }

        unsigned subchunk1MinSize = sizeof(WaveHeader::audioFormat) + sizeof(WaveHeader::channels) +
            sizeof(WaveHeader::sampleRate) + sizeof(WaveHeader::byteRate) + sizeof(WaveHeader::blockAlign) +
            sizeof(WaveHeader::bitsPerSample);
        bool formatChunkFound = false;
        bool dataChunkFound = false;

        while (!dataChunkFound) {
            std::vector<uint8_t> chunkHeader = ReadRawData(
                sizeof(WaveHeader::subchunk1ID) + sizeof(WaveHeader::subchunk1Size),
                true,
                enable,
                mtx
            );

            uint8_t chunkID[4];
            uint32_t chunkSize;
            std::memcpy(chunkID, chunkHeader.data(), sizeof(chunkID));
            std::memcpy(&chunkSize, chunkHeader.data() + sizeof(chunkID), sizeof(chunkSize));

            if (ChunkIdEquals(chunkID, "fmt ")) {
                if (chunkSize < subchunk1MinSize) {
                    throw std::runtime_error(std::string("Error while opening ") + GetFilename() + std::string(", data corrupted"));
                }

                std::vector<uint8_t> formatData = ReadRawData(chunkSize, true, enable, mtx);
                CopyChunkId(header.subchunk1ID, chunkID);
                header.subchunk1Size = chunkSize;
                std::memcpy(&header.audioFormat, formatData.data(), sizeof(header.audioFormat));
                std::memcpy(&header.channels, formatData.data() + 2, sizeof(header.channels));
                std::memcpy(&header.sampleRate, formatData.data() + 4, sizeof(header.sampleRate));
                std::memcpy(&header.byteRate, formatData.data() + 8, sizeof(header.byteRate));
                std::memcpy(&header.blockAlign, formatData.data() + 12, sizeof(header.blockAlign));
                std::memcpy(&header.bitsPerSample, formatData.data() + 14, sizeof(header.bitsPerSample));

                if ((header.audioFormat != WAVE_FORMAT_PCM) ||
                    (header.byteRate != (header.bitsPerSample >> 3) * header.channels * header.sampleRate) ||
                    (header.blockAlign != (header.bitsPerSample >> 3) * header.channels) ||
                    (((header.bitsPerSample >> 3) != 1) && ((header.bitsPerSample >> 3) != 2))) {
                    throw std::runtime_error(std::string("Error while opening ") + GetFilename() + std::string(", unsupported WAVE format"));
                }

                if (chunkSize % 2) {
                    SkipData(1, enable, mtx);
                }
                formatChunkFound = true;
            } else if (ChunkIdEquals(chunkID, "data")) {
                if (!formatChunkFound) {
                    throw std::runtime_error(std::string("Error while opening ") + GetFilename() + std::string(", data corrupted"));
                }

                CopyChunkId(header.subchunk2ID, chunkID);
                header.subchunk2Size = chunkSize;
                dataChunkFound = true;
            } else {
                SkipData(chunkSize + (chunkSize % 2), enable, mtx);
            }
        }
    } catch (...) {
        if (fileDescriptor != STDIN_FILENO) {
            close(fileDescriptor);
        }
        throw;
    }

    if (fileDescriptor != STDIN_FILENO) {
        off_t offset = lseek(fileDescriptor, 0, SEEK_CUR);
        dataOffset = (offset == -1) ? 0 : static_cast<unsigned>(offset);
    }
}

WaveReader::~WaveReader()
{
    if (fileDescriptor != STDIN_FILENO) {
        close(fileDescriptor);
    }
}

std::string WaveReader::GetFilename() const
{
    return fileDescriptor != STDIN_FILENO ? filename : "STDIN";
}

const WaveHeader &WaveReader::GetHeader() const
{
    return header;
}

std::vector<Sample> WaveReader::GetSamples(unsigned quantity, bool &enable, std::mutex &mtx) {
    unsigned bytesPerSample = (header.bitsPerSample >> 3) * header.channels;
    unsigned bytesToRead = quantity * bytesPerSample;
    unsigned bytesLeft = header.subchunk2Size - currentDataOffset;
    if (bytesToRead > bytesLeft) {
        bytesToRead = bytesLeft - bytesLeft % bytesPerSample;
        quantity = bytesToRead / bytesPerSample;
    }

    std::vector<uint8_t> data = ReadData(bytesToRead, false, enable, mtx);
    if (data.size() < bytesToRead) {
        quantity = data.size() / bytesPerSample;
    }

    std::vector<Sample> samples;
    samples.reserve(quantity);
    for (unsigned i = 0; i < quantity; i++) {
        samples.push_back(Sample(&data[bytesPerSample * i], header.channels, header.bitsPerSample));
    }
    return samples;
}

bool WaveReader::SetSampleOffset(unsigned offset) {
    if (fileDescriptor != STDIN_FILENO) {
        currentDataOffset = offset * (header.bitsPerSample >> 3) * header.channels;
        if (lseek(fileDescriptor, dataOffset + currentDataOffset, SEEK_SET) == -1) {
            return false;
        }
    }
    return true;
}

std::vector<uint8_t> WaveReader::ReadRawData(unsigned bytesToRead, bool requireFull, bool &enable, std::mutex &mtx)
{
    unsigned bytesRead = 0;
    std::vector<uint8_t> data;
    data.resize(bytesToRead);
    timeval timeout = {
        .tv_sec = 1,
    };
    fd_set fds;
    while (bytesRead < bytesToRead) {
        {
            std::lock_guard<std::mutex> lock(mtx);
            if (!enable) {
                break;
            }
        }
        ssize_t bytes = read(fileDescriptor, &data[bytesRead], bytesToRead - bytesRead);
        if (bytes == -1 && errno == EINTR) {
            continue;
        }
        if ((bytes == -1) && ((fileDescriptor != STDIN_FILENO) || (errno != EAGAIN))) {
            throw std::runtime_error(std::string("Error while opening ") + GetFilename() + std::string(", data corrupted"));
        }
        if (bytes == 0) {
            break;
        }
        if (bytes > 0) {
            bytesRead += bytes;
        }
        if (bytesRead < bytesToRead && fileDescriptor == STDIN_FILENO) {
            FD_ZERO(&fds);
            FD_SET(STDIN_FILENO, &fds);
            select(STDIN_FILENO + 1, &fds, nullptr, nullptr, &timeout);
            if (FD_ISSET(STDIN_FILENO, &fds)) {
                FD_CLR(STDIN_FILENO, &fds);
            }
        }
    }

    data.resize(bytesRead);
    if (requireFull && bytesRead < bytesToRead) {
        {
            std::lock_guard<std::mutex> lock(mtx);
            if (!enable) {
                throw std::runtime_error("Cannot obtain header, program interrupted");
            }
        }
        throw std::runtime_error(std::string("Error while opening ") + GetFilename() + std::string(", data corrupted"));
    }

    return data;
}

std::vector<uint8_t> WaveReader::ReadData(unsigned bytesToRead, bool headerBytes, bool &enable, std::mutex &mtx)
{
    std::vector<uint8_t> data = ReadRawData(bytesToRead, headerBytes, enable, mtx);

    if (headerBytes) {
        std::memcpy(&(reinterpret_cast<uint8_t *>(&header))[headerOffset], data.data(), data.size());
        headerOffset += data.size();
    } else {
        currentDataOffset += data.size();
    }

    return data;
}

void WaveReader::SkipData(unsigned bytesToSkip, bool &enable, std::mutex &mtx)
{
    const unsigned bufferSize = 4096;
    unsigned bytesLeft = bytesToSkip;
    while (bytesLeft > 0) {
        unsigned bytesToRead = bytesLeft > bufferSize ? bufferSize : bytesLeft;
        ReadRawData(bytesToRead, true, enable, mtx);
        bytesLeft -= bytesToRead;
    }
}

#endif // __linux__
