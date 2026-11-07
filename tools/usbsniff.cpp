// usbsniff.c — in-process shim for ApogeeGlue (phase 11.5b):
//  1. learn the static IOUSBLib vtables from our own QI objects,
//  2. hook the daemon's device/interface objects (vptr swap, logging thunks),
//  3. OBJECT-GRAPH WALK: find the QuartetGlueServerDevice (scan for its static
//     vtable pointer), read the embedded Messenger's vtable at +0x230, and log
//     the sendCommand/framer function address (vtbl slot 3) so it can be
//     disassembled statically.
// Build: clang -dynamiclib -framework IOKit -framework CoreFoundation usbsniff.c -o usbsniff.dylib
// Run:   DYLD_INSERT_LIBRARIES=/tmp/usbsniff.dylib ApogeeGlue
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/usb/IOUSBLib.h>
#include <IOKit/usb/USBSpec.h>
#include <CoreFoundation/CoreFoundation.h>
#include <MacTypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <pthread.h>
#include <mach/mach.h>
#include <sys/mman.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>

static FILE *g_log;
static uintptr_t g_load0;      // daemon main image load address

static void log_init(void) {
    if (g_log) return;
    g_log = fopen("/tmp/usbsniff.log", "a");
    if (g_log) { setvbuf(g_log, NULL, _IOLBF, 0); fprintf(g_log, "=== sniff attach pid=%d ===\n", getpid()); }
}

static void hexlog(const char *dir, const void *buf, UInt32 len) {
    UInt32 n = len > 256 ? 256 : len;
    const unsigned char *p = (const unsigned char *)buf;
    for (UInt32 i = 0; i < n; i++) fprintf(g_log, "%02x", p[i]);
    fprintf(g_log, "\n");
}

static void log_devreq(const char *dir, void *req) {
    unsigned char *r = (unsigned char *)req;
    UInt16 wValue, wIndex, wLength; void *pData;
    memcpy(&wValue, r + 2, 2); memcpy(&wIndex, r + 4, 2); memcpy(&wLength, r + 6, 2);
    memcpy(&pData, r + 8, 8);
    log_init();
    fprintf(g_log, "%s %ld bmReq=%02x bReq=%02x wVal=%04x wIdx=%04x wLen=%u data=", dir,
            (long)time(NULL), r[0], r[1], wValue, wIndex, wLength);
    if (pData && (r[0] & 0x80) == 0 && wLength) hexlog(dir, pData, wLength);
    else fprintf(g_log, "(in)\n");
}

typedef IOReturn (*DeviceRequest_t)(void *self, void *req);
typedef IOReturn (*DeviceRequestTO_t)(void *self, void *req, UInt32 ndt, UInt32 cto);
typedef IOReturn (*WritePipeTO_t)(void *self, UInt8 pipeRef, void *buf, UInt32 len, UInt32 ndt, UInt32 cto);
typedef IOReturn (*ReadPipe_t)(void *self, UInt8 pipeRef, void *buf, UInt32 *len);
typedef IOReturn (*WritePipeAsyncTO_t)(void *self, UInt8 pipeRef, void *buf, UInt32 len, UInt32 ndt, UInt32 cto, void *cb, void *ref);
typedef IOReturn (*ReadPipeAsyncTO_t)(void *self, UInt8 pipeRef, void *buf, UInt32 len, UInt32 ndt, UInt32 cto, void *cb, void *ref);
typedef IOReturn (*Open_t)(void *self);
typedef IOReturn (*OpenSeize_t)(void *self, UInt32 how);

static DeviceRequest_t   real_DeviceRequest;
static DeviceRequestTO_t real_DeviceRequestTO;
static WritePipeTO_t real_WritePipeTO;
static ReadPipe_t    real_ReadPipe;
static WritePipeAsyncTO_t real_WritePipeAsyncTO;
static ReadPipeAsyncTO_t  real_ReadPipeAsyncTO;
static Open_t   real_DeviceOpen;
static Open_t   real_InterfaceOpen;
static unsigned char g_last_poll[64];
static uint32_t g_last_poll_len = 0;
static void *g_iface_vtable;
static void *g_device_vtable;
static volatile int g_found_both = 0;
static void *g_own_obj1 = NULL, *g_own_obj2 = NULL;
static uintptr_t g_iface_obj_addr = 0;   // daemon's live interface object address

static IOReturn my_DeviceRequest(void *self, void *req) {
    log_devreq("D", req);
    IOReturn r = real_DeviceRequest(self, req);
    log_devreq("d", req);
    return r;
}
static IOReturn my_DeviceRequestTO(void *self, void *req, UInt32 ndt, UInt32 cto) {
    log_devreq("D", req);
    IOReturn r = real_DeviceRequestTO(self, req, ndt, cto);
    log_devreq("d", req);
    return r;
}
static IOReturn my_WritePipeTO(void *self, UInt8 pipe, void *buf, UInt32 len, UInt32 ndt, UInt32 cto) {
    IOReturn r = real_WritePipeTO(self, pipe, buf, len, ndt, cto);
    log_init(); fprintf(g_log, "T %ld pipe=%u len=%u r=0x%x data=", (long)time(NULL), pipe, len, r);
    hexlog("t", buf, len);
    return r;
}
static IOReturn my_ReadPipe(void *self, UInt8 pipe, void *buf, UInt32 *len) {
    IOReturn r = real_ReadPipe(self, pipe, buf, len);
    log_init(); fprintf(g_log, "R %ld pipe=%u len=%u r=0x%x data=", (long)time(NULL), pipe, len ? *len : 0, r);
    hexlog("r", buf, len ? *len : 0);
    return r;
}
static IOReturn my_WritePipeAsyncTO(void *self, UInt8 pipe, void *buf, UInt32 len, UInt32 ndt, UInt32 cto, void *cb, void *ref) {
    log_init(); fprintf(g_log, "W %ld pipe=%u len=%u data=", (long)time(NULL), pipe, len);
    hexlog("w", buf, len);
    return real_WritePipeAsyncTO(self, pipe, buf, len, ndt, cto, cb, ref);
}
static IOReturn my_ReadPipeAsyncTO(void *self, UInt8 pipe, void *buf, UInt32 len, UInt32 ndt, UInt32 cto, void *cb, void *ref) {
    log_init(); fprintf(g_log, "Q %ld pipe=%u len=%u (rx submission)\n", (long)time(NULL), pipe, len);
    return real_ReadPipeAsyncTO(self, pipe, buf, len, ndt, cto, cb, ref);
}
static IOReturn my_DeviceOpen(void *self) {
    IOReturn r = real_DeviceOpen(self);
    log_init(); fprintf(g_log, "OPEN device -> 0x%x\n", r);
    return r;
}
static IOReturn my_InterfaceOpen(void *self) {
    IOReturn r = real_InterfaceOpen(self);
    log_init(); fprintf(g_log, "OPEN interface -> 0x%x\n", r);
    return r;
}

static void *g_hooked_slots[64];
static int g_hooked_n = 0;
static bool already_hooked(void *slot) {
    for (int i = 0; i < g_hooked_n; i++) if (g_hooked_slots[i] == slot) return true;
    if (g_hooked_n < 64) g_hooked_slots[g_hooked_n++] = slot;
    return false;
}
static void hook_interface_object(void **objslot) {
    if (already_hooked((void *)objslot)) return;
    void **vtable = *(void***)objslot;
    void **copy = (void **)malloc(320 * 8);
    if (!copy) return;
    memcpy(copy, vtable, 320 * 8);
    real_WritePipeTO      = (WritePipeTO_t)     vtable[0x140 / 8];
    real_ReadPipe         = (ReadPipe_t)        vtable[0xf8 / 8];
    real_WritePipeAsyncTO = (WritePipeAsyncTO_t)vtable[0x150 / 8];
    real_ReadPipeAsyncTO  = (ReadPipeAsyncTO_t) vtable[0x148 / 8];
    real_InterfaceOpen    = (Open_t)            vtable[0x40 / 8];
    copy[0x140 / 8] = (void *)my_WritePipeTO;
    copy[0xf8 / 8]  = (void *)my_ReadPipe;
    copy[0x150 / 8] = (void *)my_WritePipeAsyncTO;
    copy[0x148 / 8] = (void *)my_ReadPipeAsyncTO;
    copy[0x40 / 8]  = (void *)my_InterfaceOpen;
    *objslot = copy;
    g_iface_obj_addr = (uintptr_t)objslot;
    log_init();
    fprintf(g_log, "hooked INTERFACE object at %p\n", (void *)objslot);
}

static void hook_device_object(void **objslot) {
    if (already_hooked((void *)objslot)) return;
    void **vtable = *(void***)objslot;
    void **copy = (void **)malloc(320 * 8);
    if (!copy) return;
    memcpy(copy, vtable, 320 * 8);
    real_DeviceRequest   = (DeviceRequest_t)  vtable[0xd0 / 8];
    real_DeviceRequestTO = (DeviceRequestTO_t)vtable[0xf0 / 8];
    real_DeviceOpen      = (Open_t)           vtable[0x40 / 8];
    copy[0xd0 / 8] = (void *)my_DeviceRequest;
    copy[0xf0 / 8] = (void *)my_DeviceRequestTO;
    copy[0x40 / 8] = (void *)my_DeviceOpen;
    *objslot = copy;
    log_init();
    fprintf(g_log, "hooked DEVICE object at %p\n", (void *)objslot);
}

static int learn_vtables(void) {
    CFMutableDictionaryRef match = IOServiceMatching("IOUSBHostDevice");
    if (!match) return -1;
    io_iterator_t iter = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, match, &iter) != KERN_SUCCESS) return -1;
    io_service_t dev, found = 0;
    while ((dev = IOIteratorNext(iter)) != 0) {
        CFStringRef name = (CFStringRef)IORegistryEntryCreateCFProperty(dev, CFSTR("USB Product Name"), kCFAllocatorDefault, 0);
        if (name && CFStringCompare(name, CFSTR("Quartet"), 0) == kCFCompareEqualTo) found = dev;
        if (name) CFRelease(name);
        if (found) break;
        IOObjectRelease(dev);
    }
    IOObjectRelease(iter);
    if (!found) { log_init(); fprintf(g_log, "no Quartet device found\n"); return -1; }

    IOCFPlugInInterface **plug = NULL;
    SInt32 score = 0;
    IOReturn r = IOCreatePlugInInterfaceForService(found, kIOUSBDeviceUserClientTypeID, kIOCFPlugInInterfaceID, &plug, &score);
    if (r != kIOReturnSuccess || !plug) { log_init(); fprintf(g_log, "device CPPIFS failed 0x%x\n", r); return -1; }
    void *devobj = NULL;
    r = (*plug)->QueryInterface(plug, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID100), (LPVOID *)&devobj);
    IODestroyPlugInInterface(plug);
    if (r != kIOReturnSuccess || !devobj) { log_init(); fprintf(g_log, "device QI failed 0x%x\n", r); return -1; }
    g_device_vtable = *(void***)devobj;
    g_own_obj1 = devobj;
    void **dvt = *(void***)devobj;
    ((void *(*)(void *))dvt[3])(devobj);   // Release

    io_iterator_t kids = 0;
    if (IORegistryEntryGetChildIterator(found, kIOServicePlane, &kids) != KERN_SUCCESS) return -1;
    io_service_t kid, ifsvc = 0;
    int idx = 0;
    while ((kid = IOIteratorNext(kids)) != 0) {
        io_name_t cls = "";
        IOObjectGetClass(kid, cls);
        if (strncmp(cls, "IOUSBHostInterface", 18) == 0 && idx == 0) { ifsvc = kid; break; }
        if (strncmp(cls, "IOUSBHostInterface", 18) == 0) idx++;
        IOObjectRelease(kid);
    }
    IOObjectRelease(kids);
    if (!ifsvc) { log_init(); fprintf(g_log, "no interface child\n"); return -1; }

    r = IOCreatePlugInInterfaceForService(ifsvc, kIOUSBInterfaceUserClientTypeID, kIOCFPlugInInterfaceID, &plug, &score);
    IOObjectRelease(ifsvc);
    if (r != kIOReturnSuccess || !plug) { log_init(); fprintf(g_log, "iface CPPIFS failed 0x%x\n", r); return -1; }
    void *ifobj = NULL;
    r = (*plug)->QueryInterface(plug, CFUUIDGetUUIDBytes(kIOUSBInterfaceInterfaceID100), (LPVOID *)&ifobj);
    IODestroyPlugInInterface(plug);
    if (r != kIOReturnSuccess || !ifobj) { log_init(); fprintf(g_log, "iface QI failed 0x%x\n", r); return -1; }

    g_iface_vtable = *(void***)ifobj;
    g_own_obj2 = ifobj;
    void **ivt = *(void***)ifobj;
    ((void *(*)(void *))ivt[3])(ifobj);   // Release

    log_init();
    fprintf(g_log, "learned: device vtable %p, interface vtable %p\n", g_device_vtable, g_iface_vtable);
    return 0;
}

// ---- resolve REAL IOConnectCall* addresses by parsing IOKit's export trie
//      from the mapped shared cache (dlsym is poisoned by the interpose map) ----
// ---- resolve REAL IOConnectCall* addresses ----
// dlsym is poisoned by the interpose map for interposed symbols, and the
// binary's pages are immutable. IOKit lives in the shared cache; its symbol
// table (in the .dyldlinkedit sub-file, mapped with the cache) has the real
// addresses. Cache vmaddrs for this OS build (macOS 27, IOKit __TEXT at
// 0x184E6E000): runtime = vmaddr + IOKit slide.
static uintptr_t resolve_iokit_symbol(const char *want) {
    struct { const char *name; uint64_t vmaddr; } table[] = {
        {"_IOConnectCallStructMethod",        0x184e71db0},
        {"_IOConnectCallAsyncStructMethod",   0x184e9601c},
        {"_IOConnectCallAsyncScalarMethod",   0x184e72ce8},
        {"_IOConnectCallScalarMethod",        0x184e79784},
    };
    for (auto &e : table) {
        if (strcmp(e.name, want) == 0) {
            uint32_t n = _dyld_image_count();
            for (uint32_t i = 0; i < n; i++) {
                const char *nm = _dyld_get_image_name(i);
                if (!nm || !strstr(nm, "IOKit.framework")) continue;
                uint64_t slide = _dyld_get_image_vmaddr_slide(i);
                return (uintptr_t)(e.vmaddr + slide);
            }
        }
    }
    return 0;
}

static int read_qword(uintptr_t addr, void *out) {
    vm_size_t got = 0;
    return vm_read_overwrite(mach_task_self(), addr, 8, (vm_address_t)out, &got) == KERN_SUCCESS;
}

// the object-graph walk — backwards from the hooked USB objects:
//   interface object (hooked) -> USBDeviceMacOS (+0x90 slot) -> GlueServerDevice
//   (member offset discovered via the messenger self-pointer at +0x428/+0x230)
static void walk_object_graph(void) {
    if (!g_iface_obj_addr) { log_init(); fprintf(g_log, "WALK: no interface object hooked\n"); return; }
    task_t task = mach_task_self();
    uintptr_t usbdev_obj = 0, usbdev_slot = 0;

    // step 1: find slots containing the interface object pointer
    vm_address_t addr = 0;
    vm_size_t size = 0;
    natural_t depth = 1;
    for (;;) {
        struct vm_region_submap_info_64 info;
        mach_msg_type_number_t cnt = VM_REGION_SUBMAP_INFO_COUNT_64;
        kern_return_t kr = vm_region_recurse_64(task, &addr, &size, &depth, (vm_region_recurse_info_t)&info, &cnt);
        if (kr != KERN_SUCCESS) break;
        if (info.is_submap) { depth++; continue; }
        int prot = info.protection;
        if ((prot & (PROT_READ | PROT_WRITE)) == (PROT_READ | PROT_WRITE) && size >= 0x1000 && size < 0x10000000) {
            vm_address_t p = addr;
            while (p < addr + size) {
                vm_size_t chunk = 0x100000;
                if (p + chunk > addr + size) chunk = addr + size - p;
                static unsigned char buf[0x100000];
                vm_size_t got = 0;
                if (vm_read_overwrite(task, p, chunk, (vm_address_t)buf, &got) != KERN_SUCCESS) { p += chunk; continue; }
                for (vm_size_t off = 0; off + 8 <= got; off += 8) {
                    uintptr_t v;
                    memcpy(&v, buf + off, 8);
                    if (v != g_iface_obj_addr) continue;
                    uintptr_t slot = p + off;
                    if (slot == (uintptr_t)g_iface_obj_addr) continue;   // the object's own vptr slot
                    uintptr_t cand = slot - 0x90;                        // USBDeviceMacOS base candidate
                    uintptr_t vp = 0;
                    if (!read_qword(cand, &vp)) continue;
                    // vptr must point into the daemon's own __DATA_CONST vtable area
                    if (vp < g_load0 + 0x2ac000 || vp >= g_load0 + 0x2c5000) continue;
                    usbdev_obj = cand; usbdev_slot = slot;
                    log_init();
                    fprintf(g_log, "WALK: USBDeviceMacOS at %p (iface slot %p)\n", (void *)cand, (void *)slot);
                    goto step2;
                }
                p += chunk;
            }
        }
        addr += size;
    }
    log_init(); fprintf(g_log, "WALK: USBDeviceMacOS not found\n"); return;

step2:
    // step 2: find slots containing the USBDeviceMacOS pointer; discover the
    // member offset M by testing the messenger self-pointer *(A-M+0x428)==A-M+0x230
    addr = 0; size = 0; depth = 1;
    for (;;) {
        struct vm_region_submap_info_64 info2;
        mach_msg_type_number_t cnt2 = VM_REGION_SUBMAP_INFO_COUNT_64;
        kern_return_t kr = vm_region_recurse_64(task, &addr, &size, &depth, (vm_region_recurse_info_t)&info2, &cnt2);
        if (kr != KERN_SUCCESS) break;
        if (info2.is_submap) { depth++; continue; }
        int prot = info2.protection;
        if ((prot & (PROT_READ | PROT_WRITE)) == (PROT_READ | PROT_WRITE) && size >= 0x1000 && size < 0x10000000) {
            vm_address_t p = addr;
            while (p < addr + size) {
                vm_size_t chunk = 0x100000;
                if (p + chunk > addr + size) chunk = addr + size - p;
                static unsigned char buf[0x100000];
                vm_size_t got = 0;
                if (vm_read_overwrite(task, p, chunk, (vm_address_t)buf, &got) != KERN_SUCCESS) { p += chunk; continue; }
                for (vm_size_t off = 0; off + 8 <= got; off += 8) {
                    uintptr_t v;
                    memcpy(&v, buf + off, 8);
                    if (v != usbdev_obj) continue;
                    uintptr_t slotA = p + off;
                    if (slotA == usbdev_slot) continue;
                    for (uintptr_t M = 0; M <= 0x800; M += 8) {
                        uintptr_t base = slotA - M;
                        uintptr_t mp = 0;
                        if (!read_qword(base + 0x428, &mp)) break;
                        if (mp == base + 0x230) {
                            // validated: GlueServerDevice base
                            uintptr_t messenger = mp, mvt = 0, framer = 0;
                            read_qword(messenger, &mvt);
                            if (mvt) read_qword(mvt + 0x18, &framer);
                            log_init();
                            fprintf(g_log, "WALK: GlueServerDevice at %p (M=%#llx) messenger=%p mvt=%p framer=%p fileoff=%#llx\n",
                                    (void *)base, (unsigned long long)M, (void *)messenger, (void *)mvt,
                                    (void *)framer, framer ? (unsigned long long)(framer - g_load0) : 0ULL);
                            for (int i = 0; i < 16; i++) {
                                uintptr_t fp = 0;
                                if (read_qword(mvt + i * 8, &fp) && fp >= g_load0 && fp < g_load0 + 0x400000)
                                    fprintf(g_log, "WALK:   mvt[%d] = +%#llx\n", i, (unsigned long long)(fp - g_load0));
                            }
                            return;
                        }
                    }
                }
                p += chunk;
            }
        }
        addr += size;
    }
    log_init(); fprintf(g_log, "WALK: GlueServerDevice not found\n");
}

// ---- scanner: hook daemon USB objects + run the graph walk ----
static void *scanner(void *arg) {
    (void)arg;
    // small delay so the daemon's own ctor finishes creating its objects
    for (int pass = 0; pass < 600; pass++) {
        int hooked_now = 0;
        vm_address_t addr = 0;
        vm_size_t size = 0;
        natural_t depth = 1;
        task_t task = mach_task_self();
        for (;;) {
            struct vm_region_submap_info_64 info;
            mach_msg_type_number_t cnt = VM_REGION_SUBMAP_INFO_COUNT_64;
            kern_return_t kr = vm_region_recurse_64(task, &addr, &size, &depth, (vm_region_recurse_info_t)&info, &cnt);
            if (kr != KERN_SUCCESS) break;
            if (info.is_submap) { depth++; continue; }   // descend, do not skip
            int prot = info.protection;
            if ((prot & (PROT_READ | PROT_WRITE)) == (PROT_READ | PROT_WRITE) && size >= 0x1000 && size < 0x10000000) {
                vm_address_t p = addr;
                while (p < addr + size) {
                    vm_size_t chunk = 0x100000;
                    if (p + chunk > addr + size) chunk = addr + size - p;
                    static unsigned char buf[0x100000];
                    vm_size_t got = 0;
                    if (vm_read_overwrite(task, p, chunk, (vm_address_t)buf, &got) != KERN_SUCCESS) { p += chunk; continue; }
                    for (vm_size_t off = 0; off + 8 <= got; off += 8) {
                        void *v;
                        memcpy(&v, buf + off, 8);
                        if (v == g_iface_vtable) {
                            void **objslot = (void **)(p + off);
                            if (objslot == (void **)g_own_obj2) continue;
                            hook_interface_object(objslot);
                            hooked_now++;
                        } else if (v == g_device_vtable) {
                            void **objslot = (void **)(p + off);
                            if (objslot == (void **)g_own_obj1) continue;
                            hook_device_object(objslot);
                            hooked_now++;
                        }
                    }
                    p += chunk;
                }
            }
            addr += size;
        }
        if (hooked_now) continue;   // keep scanning: the daemon opens multiple interfaces (iAP = interface #5!)
        usleep(100 * 1000);
    }
    // give the daemon a moment, then run the graph walk once
    sleep(3);
    walk_object_graph();
    return NULL;
}

// forward decls for the modern-API real pointers (resolved via export trie)
typedef kern_return_t (*CCSM_t)(mach_port_t, uint32_t, const void *, vm_size_t, void *, vm_size_t *);
typedef kern_return_t (*CCASM_t)(mach_port_t, uint32_t, mach_port_t, uint64_t *, uint32_t, const void *, size_t, void *, size_t *);
typedef kern_return_t (*CCASCM_t)(mach_port_t, uint32_t, mach_port_t, uint64_t *, uint32_t, const uint64_t *, uint32_t, uint64_t *, uint32_t *);
typedef kern_return_t (*CCSCM_t)(mach_port_t, uint32_t, const uint64_t *, uint32_t, uint64_t *, uint32_t *);
static CCSM_t real_CCSM;
static CCASM_t real_CCASM;
static CCASCM_t real_CCASCM;
static CCSCM_t real_CCSCM;

// __interpose: reroutes the daemon's IOConnectCall* bindings to our wrappers.
// replacee = the IOKit IMPORT (dyld binds + slides it, matching the daemon's
// bindings); real_* = shared-cache symtab addresses + slide (never bound =>
// never redirected => no recursion). The wrappers are separately named so
// they don't shadow the imports.
extern "C" kern_return_t usbsniff_CCSM(mach_port_t, uint32_t, const void *, vm_size_t, void *, vm_size_t *);
extern "C" kern_return_t usbsniff_CCASM(mach_port_t, uint32_t, mach_port_t, uint64_t *, uint32_t, const void *, size_t, void *, size_t *);
extern "C" kern_return_t usbsniff_CCASCM(mach_port_t, uint32_t, mach_port_t, uint64_t *, uint32_t, const uint64_t *, uint32_t, uint64_t *, uint32_t *);
extern "C" kern_return_t usbsniff_CCSCM(mach_port_t, uint32_t, const uint64_t *, uint32_t, uint64_t *, uint32_t *);
extern "C" {
kern_return_t IOConnectCallStructMethod(mach_port_t, uint32_t, const void *, vm_size_t, void *, vm_size_t *);
kern_return_t IOConnectCallAsyncStructMethod(mach_port_t, uint32_t, mach_port_t, uint64_t *, uint32_t, const void *, size_t, void *, size_t *);
kern_return_t IOConnectCallAsyncScalarMethod(mach_port_t, uint32_t, mach_port_t, uint64_t *, uint32_t, const uint64_t *, uint32_t, uint64_t *, uint32_t *);
kern_return_t IOConnectCallScalarMethod(mach_port_t, uint32_t, const uint64_t *, uint32_t, uint64_t *, uint32_t *);
}
__attribute__((used)) static struct { void *replacement; void *replacee; } interposers[]
__attribute__((section("__DATA,__interpose"))) = {
    { (void *)usbsniff_CCSM,  (void *)IOConnectCallStructMethod },
    { (void *)usbsniff_CCASM, (void *)IOConnectCallAsyncStructMethod },
    { (void *)usbsniff_CCASCM, (void *)IOConnectCallAsyncScalarMethod },
    { (void *)usbsniff_CCSCM, (void *)IOConnectCallScalarMethod },
};

__attribute__((constructor)) static void init(void) {
    log_init();
    g_load0 = (uintptr_t)_dyld_get_image_header(0);
    // resolve the REAL IOConnectCall* via IOKit's export trie (dlsym is poisoned)
    if (!real_CCSM)  real_CCSM  = (CCSM_t)resolve_iokit_symbol("_IOConnectCallStructMethod");
    if (!real_CCASM) real_CCASM = (CCASM_t)resolve_iokit_symbol("_IOConnectCallAsyncStructMethod");
    if (!real_CCASCM) real_CCASCM = (CCASCM_t)resolve_iokit_symbol("_IOConnectCallAsyncScalarMethod");
    if (!real_CCSCM) real_CCSCM = (CCSCM_t)resolve_iokit_symbol("_IOConnectCallScalarMethod");
    fprintf(g_log, "trie resolution: CCSM=%p CCASM=%p CCASCM=%p CCSCM=%p\n",
            (void *)real_CCSM, (void *)real_CCASM, (void *)real_CCASCM, (void *)real_CCSCM);
    if (learn_vtables() == 0) {
        pthread_t t;
        pthread_create(&t, NULL, scanner, NULL);
        pthread_detach(t);
        fprintf(g_log, "scanner started (load0=%p)\n", (void *)g_load0);
    }
}

// ---- modern-API wrappers (same-name definitions; engage under flat namespace) ----

__attribute__((visibility("default")))
extern "C" kern_return_t usbsniff_CCSM(mach_port_t conn, uint32_t sel, const void *inp, vm_size_t insz, void *outp, vm_size_t *outsz) {
    if (!real_CCSM) {
        void *iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
        real_CCSM = (CCSM_t)dlsym(RTLD_NEXT, "IOConnectCallStructMethod");
        if (!real_CCSM && iokit) real_CCSM = (CCSM_t)dlsym(iokit, "IOConnectCallStructMethod");
        log_init();
        fprintf(g_log, "resolved real CCSM: %p\n", (void *)real_CCSM);
    }
    log_init();
    fprintf(g_log, "S %ld sel=%u insz=%zu in=", (long)time(NULL), sel, (size_t)insz);
    hexlog("s", inp, (UInt32)insz);
    kern_return_t r = real_CCSM(conn, sel, inp, insz, outp, outsz);
    fprintf(g_log, "Sdone %ld sel=%u kr=%d outsz=%zu out=", (long)time(NULL), sel, r, outsz ? (size_t)*outsz : 0);
    hexlog("s2", outp, outsz ? (UInt32)*outsz : 0);
    return r;
}

__attribute__((visibility("default")))
extern "C" kern_return_t usbsniff_CCASM(mach_port_t conn, uint32_t sel, mach_port_t wake, uint64_t *ref, uint32_t refcnt, const void *inp, size_t insz, void *outp, size_t *outsz) {
    if (!real_CCASM) {
        void *iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
        real_CCASM = (CCASM_t)dlsym(RTLD_NEXT, "IOConnectCallAsyncStructMethod");
        if (!real_CCASM && iokit) real_CCASM = (CCASM_t)dlsym(iokit, "IOConnectCallAsyncStructMethod");
        log_init();
        fprintf(g_log, "resolved real CCASM: %p\n", (void *)real_CCASM);
    }
    log_init();
    fprintf(g_log, "A %ld sel=%u insz=%zu in=", (long)time(NULL), sel, (size_t)insz);
    hexlog("a", inp, (UInt32)insz);
    return real_CCASM(conn, sel, wake, ref, refcnt, inp, insz, outp, outsz);
}

__attribute__((visibility("default")))
extern "C" kern_return_t usbsniff_CCASCM(mach_port_t conn, uint32_t sel, mach_port_t wake, uint64_t *ref, uint32_t refcnt, const uint64_t *in, uint32_t incnt, uint64_t *out, uint32_t *outcnt) {
    if (!real_CCASCM) {
        void *iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
        real_CCASCM = (CCASCM_t)dlsym(RTLD_NEXT, "IOConnectCallAsyncScalarMethod");
        if (!real_CCASCM && iokit) real_CCASCM = (CCASCM_t)dlsym(iokit, "IOConnectCallAsyncScalarMethod");
        log_init();
        fprintf(g_log, "resolved real CCASCM: %p\n", (void *)real_CCASCM);
    }
    log_init();
    fprintf(g_log, "B %ld sel=%u incnt=%u in0=%llu in1=%llu\n", (long)time(NULL), sel, incnt,
            incnt > 0 ? (unsigned long long)in[0] : 0, incnt > 1 ? (unsigned long long)in[1] : 0);
    return real_CCASCM(conn, sel, wake, ref, refcnt, in, incnt, out, outcnt);
}

__attribute__((visibility("default")))
extern "C" kern_return_t usbsniff_CCSCM(mach_port_t conn, uint32_t sel, const uint64_t *in, uint32_t incnt, uint64_t *out, uint32_t *outcnt) {
    if (!real_CCSCM) {
        void *iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
        real_CCSCM = (CCSCM_t)dlsym(RTLD_NEXT, "IOConnectCallScalarMethod");
        if (!real_CCSCM && iokit) real_CCSCM = (CCSCM_t)dlsym(iokit, "IOConnectCallScalarMethod");
        log_init();
        fprintf(g_log, "resolved real CCSCM: %p\n", (void *)real_CCSCM);
    }
    log_init();
    fprintf(g_log, "M %ld sel=%u incnt=%u", (long)time(NULL), sel, incnt);
    for (uint32_t i = 0; i < incnt && i < 10; i++)
        fprintf(g_log, " s%u=%llu", i, (unsigned long long)in[i]);
    fprintf(g_log, "\n");
    // if any scalar looks like a userspace pointer, dump 64 bytes there
    for (uint32_t i = 0; i < incnt && i < 10; i++) {
        uint64_t v = in[i];
        if (v > 0x100000000ULL && v < 0x800000000000ULL) {
            fprintf(g_log, "  m%u @%llx: ", i, (unsigned long long)v);
            hexlog("m", (const void *)(uintptr_t)v, 64);
        }
    }
    kern_return_t r = real_CCSCM(conn, sel, in, incnt, out, outcnt);
    if (outcnt && *outcnt) {
        fprintf(g_log, "Mdone %ld sel=%u kr=%d outcnt=%u out0=%llu\n", (long)time(NULL), sel, r, *outcnt,
                *outcnt > 0 ? (unsigned long long)out[0] : 0);
    }
    // sel=7 = the state poll (IN vendor request): dump the response AFTER the
    // call, deduped to changes only
    if (sel == 7 && incnt >= 6 && r == 0) {
        uint32_t len = (uint32_t)in[5];
        unsigned char *buf = (unsigned char *)(uintptr_t)in[6];
        if (buf && len && len <= 64) {
            if (memcmp(buf, g_last_poll, len) != 0) {
                memcpy(g_last_poll, buf, len);
                g_last_poll_len = len;
                fprintf(g_log, "POLL %ld kr=%d len=%u data=", (long)time(NULL), r, len);
                hexlog("poll", buf, len);
            }
        }
    }
    return r;
}
