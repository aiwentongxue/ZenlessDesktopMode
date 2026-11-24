#import "MachOImage.hpp"

#include <algorithm>
#include <cstring>
#include <libkern/OSCacheControl.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>

namespace zzz {
namespace {

template<class Visitor>
void VisitCommands(const mach_header_64 &header, Visitor visit) {
    if (header.magic != MH_MAGIC_64 || header.cputype != CPU_TYPE_ARM64) return;
    const auto *cursor = reinterpret_cast<const uint8_t *>(&header + 1);
    size_t remaining = header.sizeofcmds;
    for (unsigned i = 0; i < header.ncmds && remaining >= sizeof(load_command); ++i) {
        const auto &command = *reinterpret_cast<const load_command *>(cursor);
        if (command.cmdsize < sizeof(command) || command.cmdsize > remaining) return;
        if (!visit(command)) return;
        cursor += command.cmdsize;
        remaining -= command.cmdsize;
    }
}

// Each change is a single aligned instruction in the current process.
bool Replace(uintptr_t address, uint32_t expected, uint32_t value) {
    auto *word = reinterpret_cast<uint32_t *>(address);
    if (*word != expected) return false;
    const mach_vm_address_t page = address & ~(mach_vm_address_t(vm_page_size) - 1);
    auto task = mach_task_self();
    if (mach_vm_protect(task, page, vm_page_size, false, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY) != KERN_SUCCESS) {
        return false;
    }
    __atomic_store_n(word, value, __ATOMIC_RELAXED);
    sys_icache_invalidate(word, sizeof(*word));
    if (mach_vm_protect(task, page, vm_page_size, false, VM_PROT_READ | VM_PROT_EXECUTE) == KERN_SUCCESS) {
        return true;
    }
    __atomic_store_n(word, expected, __ATOMIC_RELAXED);
    sys_icache_invalidate(word, sizeof(*word));
    mach_vm_protect(task, page, vm_page_size, false, VM_PROT_READ | VM_PROT_EXECUTE);
    return false;
}

} // namespace

bool MachOImage::hasUUID(const ImageUUID &uuid) const {
    bool matches = false;
    VisitCommands(header_, [&](const load_command &command) {
        if (command.cmd != LC_UUID || command.cmdsize < sizeof(uuid_command)) return true;
        const auto &info = reinterpret_cast<const uuid_command &>(command);
        matches = std::equal(uuid.begin(), uuid.end(), info.uuid);
        return false;
    });
    return matches;
}

bool MachOImage::contains(const char *segmentName, const char *sectionName, uintptr_t offset, size_t size) const {
    bool found = false;
    VisitCommands(header_, [&](const load_command &command) {
        if (command.cmd != LC_SEGMENT_64 || command.cmdsize < sizeof(segment_command_64)) return true;
        const auto &segment = reinterpret_cast<const segment_command_64 &>(command);
        if (std::strncmp(segment.segname, segmentName, sizeof(segment.segname)) != 0) return true;
        if (segment.nsects > (segment.cmdsize - sizeof(segment)) / sizeof(section_64)) return false;
        const auto *sections = reinterpret_cast<const section_64 *>(&segment + 1);
        for (uint32_t i = 0; i < segment.nsects; ++i) {
            const auto &section = sections[i];
            if (std::strncmp(section.sectname, sectionName, sizeof(section.sectname)) != 0) continue;
            found = offset >= section.addr && size <= section.size && offset - section.addr <= section.size - size;
            break;
        }
        return false;
    });
    return found;
}

bool MachOImage::matchesCode(uint32_t offset, std::span<const uint32_t> words) const {
    return offset % alignof(uint32_t) == 0 && contains("__TEXT", "__text", offset, words.size_bytes()) &&
        std::memcmp(reinterpret_cast<const void *>(address(offset)), words.data(), words.size_bytes()) == 0;
}

bool MachOImage::changeCode(std::span<const InstructionChange> changes) const {
    for (const auto &change : changes) {
        if (!matchesCode(change.offset, {&change.before, 1})) return false;
    }
    size_t count = 0;
    for (const auto &change : changes) {
        if (!Replace(address(change.offset), change.before, change.after)) {
            while (count) {
                const auto &applied = changes[--count];
                Replace(address(applied.offset), applied.after, applied.before);
            }
            return false;
        }
        ++count;
    }
    return true;
}

} // namespace zzz
