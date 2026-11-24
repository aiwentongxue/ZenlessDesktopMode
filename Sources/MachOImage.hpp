#pragma once

#include <mach-o/loader.h>
#include <array>
#include <cstddef>
#include <cstdint>
#include <span>

namespace zzz {

using ImageUUID = std::array<uint8_t, 16>;

struct InstructionChange {
    uint32_t offset;
    uint32_t before;
    uint32_t after;
};

class MachOImage {
public:
    MachOImage(const mach_header_64 &header, intptr_t slide) : header_(header), slide_(slide) {}

    bool hasUUID(const ImageUUID &uuid) const;
    bool contains(const char *segment, const char *section, uintptr_t offset, size_t size) const;
    bool matchesCode(uint32_t offset, std::span<const uint32_t> words) const;
    bool changeCode(std::span<const InstructionChange> changes) const;

    uintptr_t address(uintptr_t offset) const { return offset + slide_; }
    uintptr_t offset(uintptr_t address) const { return address - slide_; }

private:
    const mach_header_64 &header_;
    intptr_t slide_;
};

} // namespace zzz
