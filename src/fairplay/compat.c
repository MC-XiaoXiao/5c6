#include <fcntl.h>
#include <libkern/OSByteOrder.h>
#include <mach/mach.h>
#include <mach/mig.h>
#include <mach-o/arch.h>
#include <mach-o/dyld.h>
#include <mach-o/fat.h>
#include <mach-o/loader.h>
#include <stdint.h>
#include <string.h>
#include <sys/sysctl.h>
#include <unistd.h>

static mig_stub_routine_t original_unfreed;

static int executable_arch(const char *path, uint32_t cpu[2]) {
    struct mach_header header;
    int fd = open(path, O_RDONLY);
    if (fd < 0) return 0;
    int ok = 0;
    if (pread(fd, &header, sizeof(header), 0) != sizeof(header)) goto done;
    if (header.magic == MH_MAGIC && header.cputype == CPU_TYPE_ARM) {
        cpu[0] = header.cputype;
        cpu[1] = header.cpusubtype;
        ok = 1;
    } else if (header.magic == FAT_MAGIC || header.magic == FAT_CIGAM) {
        int swap = header.magic == FAT_CIGAM;
        uint32_t count = (uint32_t)header.cputype;
        if (swap) count = OSSwapInt32(count);
        struct fat_arch arches[128];
        if (!count || count > sizeof(arches) / sizeof(arches[0])) goto done;
        size_t bytes = count * sizeof(arches[0]);
        if (pread(fd, arches, bytes, sizeof(struct fat_header)) != (ssize_t)bytes) goto done;
        if (swap) {
            for (uint32_t i = 0; i < count; ++i) {
                arches[i].cputype = OSSwapInt32(arches[i].cputype);
                arches[i].cpusubtype = OSSwapInt32(arches[i].cpusubtype);
                arches[i].offset = OSSwapInt32(arches[i].offset);
                arches[i].size = OSSwapInt32(arches[i].size);
                arches[i].align = OSSwapInt32(arches[i].align);
            }
        }
        cpu_type_t type;
        cpu_subtype_t subtype;
        size_t size = sizeof(type);
        if (sysctlbyname("hw.cputype", &type, &size, NULL, 0)) goto done;
        size = sizeof(subtype);
        if (sysctlbyname("hw.cpusubtype", &subtype, &size, NULL, 0)) goto done;
        struct fat_arch *best = NXFindBestFatArch(type, subtype, arches, count);
        if (best && best->cputype == CPU_TYPE_ARM &&
            pread(fd, &header, sizeof(header), best->offset) == sizeof(header) &&
            header.magic == MH_MAGIC && header.cputype == best->cputype &&
            header.cpusubtype == best->cpusubtype) {
            cpu[0] = header.cputype;
            cpu[1] = header.cpusubtype;
            ok = 1;
        }
    }
done:
    close(fd);
    return ok;
}

static void compat_unfreed(mach_msg_header_t *request, mach_msg_header_t *reply) {
    if (request->msgh_id == 502 && !(request->msgh_bits & MACH_MSGH_BITS_COMPLEX) &&
        request->msgh_size >= 40 && request->msgh_size <= 1064) {
        const uint8_t *bytes = (const void *)request;
        uint32_t count;
        memcpy(&count, bytes + 36, sizeof(count));
        uint32_t cpu[2];
        if (count && count <= 1024 &&
            request->msgh_size == 40 + ((count + 3) & ~3u) &&
            memchr(bytes + 40, 0, count) &&
            executable_arch((const char *)bytes + 40, cpu)) {
            union { uint32_t alignment; uint8_t bytes[1072]; } translated;
            memcpy(translated.bytes, bytes, request->msgh_size);
            /* iOS 7 adds the selected Mach-O architecture after the inline path. */
            memcpy(translated.bytes + request->msgh_size, cpu, sizeof(cpu));
            mach_msg_header_t *message = (void *)translated.bytes;
            message->msgh_size += sizeof(cpu);
            original_unfreed(message, reply);
            return;
        }
    }
    original_unfreed(request, reply);
}

struct unfreed_subsystem {
    mig_server_routine_t server;
    mach_msg_id_t start, end;
    mach_msg_size_t maxsize;
    vm_address_t reserved;
    struct routine_descriptor routine[3];
};

__attribute__((constructor)) static void install_compat(void) {
    const struct mach_header *header = _dyld_get_image_header(0);
    if (!header || header->magic != MH_MAGIC) return;
    const char *image = _dyld_get_image_name(0);
    const char *name = image ? strrchr(image, '/') : NULL;
    if (!name || strcmp(name + 1, "fairplayd.H2")) return;
    intptr_t slide = _dyld_get_image_vmaddr_slide(0);
    const struct load_command *command = (const void *)(header + 1);
    for (uint32_t i = 0; i < header->ncmds; ++i) {
        if (command->cmd == LC_SEGMENT) {
            const struct segment_command *segment = (const void *)command;
            const struct section *section = (const void *)(segment + 1);
            for (uint32_t j = 0; j < segment->nsects; ++j, ++section) {
                if (strcmp(segment->segname, SEG_DATA) ||
                    strcmp(section->sectname, "__const")) continue;
                uint8_t *data = (void *)(slide + section->addr);
                for (uint32_t offset = 0; offset + sizeof(struct unfreed_subsystem) <= section->size; offset += 4) {
                    struct unfreed_subsystem *table = (void *)(data + offset);
                    if (table->start != 500 || table->end != 503 ||
                        table->maxsize != 184 || table->reserved || !table->server ||
                        table->routine[0].stub_routine || table->routine[1].stub_routine ||
                        table->routine[2].argc != 8 || table->routine[2].max_reply_msg != 184 ||
                        !table->routine[2].stub_routine) continue;
                    original_unfreed = table->routine[2].stub_routine;
                    table->routine[2].stub_routine = compat_unfreed;
                    return;
                }
            }
        }
        command = (const void *)((const char *)command + command->cmdsize);
    }
}
