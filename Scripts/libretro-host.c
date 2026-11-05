/*
 * Minimal libretro frontend used to smoke-test the Bismuth core the way RetroArch loads it.
 *
 *   clang -O2 -I Sources/CLibretro/include Scripts/libretro-host.c -o .build/libretro-host
 *   .build/libretro-host <core.dylib> <rom.nes> [frames] [out.ppm] [--zapper x,y,fireFrame] [--press frame:button]
 *
 * Prints environment calls the core makes, the memory map rcheevos would see, the audio rate,
 * and verifies serialize/unserialize round trips.
 */
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include "libretro.h"

#define LOAD(name) do { name##_p = dlsym(lib, #name); if (!name##_p) { fprintf(stderr, "missing %s\n", #name); return 1; } } while (0)

static void (*retro_init_p)(void);
static void (*retro_deinit_p)(void);
static unsigned (*retro_api_version_p)(void);
static void (*retro_get_system_info_p)(struct retro_system_info *);
static void (*retro_get_system_av_info_p)(struct retro_system_av_info *);
static void (*retro_set_environment_p)(retro_environment_t);
static void (*retro_set_video_refresh_p)(retro_video_refresh_t);
static void (*retro_set_audio_sample_p)(retro_audio_sample_t);
static void (*retro_set_audio_sample_batch_p)(retro_audio_sample_batch_t);
static void (*retro_set_input_poll_p)(retro_input_poll_t);
static void (*retro_set_input_state_p)(retro_input_state_t);
static void (*retro_set_controller_port_device_p)(unsigned, unsigned);
static void (*retro_run_p)(void);
static void (*retro_reset_p)(void);
static size_t (*retro_serialize_size_p)(void);
static bool (*retro_serialize_p)(void *, size_t);
static bool (*retro_unserialize_p)(const void *, size_t);
static bool (*retro_load_game_p)(const struct retro_game_info *);
static void (*retro_unload_game_p)(void);
static void *(*retro_get_memory_data_p)(unsigned);
static size_t (*retro_get_memory_size_p)(unsigned);
static void (*retro_cheat_set_p)(unsigned, bool, const char *);

static unsigned frame_w, frame_h;
static unsigned char frame[256 * 240 * 4];
static long audio_frames;
static int current_frame;
static int press_frame = -1;
static unsigned press_id = RETRO_DEVICE_ID_JOYPAD_START;
static int zapper_x = -1, zapper_y = -1, zapper_fire = -1;
static bool achievements_flag;
static int memory_map_count;

static void log_cb(enum retro_log_level level, const char *fmt, ...) {
    va_list ap; va_start(ap, fmt); vfprintf(stdout, fmt, ap); va_end(ap);
}

static bool env_cb(unsigned cmd, void *data) {
    switch (cmd) {
    case RETRO_ENVIRONMENT_GET_LOG_INTERFACE:
        ((struct retro_log_callback *)data)->log = log_cb; return true;
    case RETRO_ENVIRONMENT_SET_PIXEL_FORMAT:
        return *(enum retro_pixel_format *)data == RETRO_PIXEL_FORMAT_XRGB8888;
    case RETRO_ENVIRONMENT_GET_INPUT_BITMASKS: return true;
    case RETRO_ENVIRONMENT_SET_VARIABLES: {
        const struct retro_variable *v = data; int n = 0;
        for (; v->key; v++) n++;
        printf("env: %d core options\n", n); return true;
    }
    case RETRO_ENVIRONMENT_GET_VARIABLE: return false;   /* use defaults */
    case RETRO_ENVIRONMENT_GET_VARIABLE_UPDATE: *(bool *)data = false; return true;
    case RETRO_ENVIRONMENT_SET_MEMORY_MAPS: {
        const struct retro_memory_map *m = data;
        memory_map_count = m->num_descriptors;
        for (unsigned i = 0; i < m->num_descriptors; i++) {
            const struct retro_memory_descriptor *d = &m->descriptors[i];
            printf("env: memory map %u: start=$%04zX len=$%04zX flags=%llu space=%s ptr=%s\n", i, d->start, d->len,
                   (unsigned long long)d->flags, d->addrspace ? d->addrspace : "-", d->ptr ? "yes" : "no");
        }
        return true;
    }
    case RETRO_ENVIRONMENT_SET_SUPPORT_ACHIEVEMENTS:
        achievements_flag = *(bool *)data; printf("env: achievements supported = %d\n", achievements_flag); return true;
    case RETRO_ENVIRONMENT_SET_CONTROLLER_INFO: {
        const struct retro_controller_info *c = data; int n = 0;
        for (; c->types; c++) n++;
        printf("env: controller info for %d ports\n", n); return true;
    }
    case RETRO_ENVIRONMENT_SET_INPUT_DESCRIPTORS:
    case RETRO_ENVIRONMENT_SET_SUPPORT_NO_GAME:
    case RETRO_ENVIRONMENT_SET_GEOMETRY:
    case RETRO_ENVIRONMENT_SET_SYSTEM_AV_INFO:
        return true;
    case RETRO_ENVIRONMENT_SET_MESSAGE:
        printf("env: message: %s\n", ((const struct retro_message *)data)->msg); return true;
    default:
        return false;
    }
}

static void video_cb(const void *data, unsigned w, unsigned h, size_t pitch) {
    if (!data) return;
    frame_w = w; frame_h = h;
    for (unsigned y = 0; y < h; y++) memcpy(frame + y * w * 4, (const char *)data + y * pitch, w * 4);
}
static void audio_cb(int16_t l, int16_t r) { audio_frames++; }
static size_t audio_batch_cb(const int16_t *d, size_t frames) { audio_frames += frames; return frames; }
static void poll_cb(void) {}
static int16_t input_cb(unsigned port, unsigned device, unsigned index, unsigned id) {
    if (device == RETRO_DEVICE_JOYPAD && port == 0) {
        bool down = press_frame >= 0 && current_frame >= press_frame && current_frame < press_frame + 5;
        if (id == RETRO_DEVICE_ID_JOYPAD_MASK) return down ? (1 << press_id) : 0;
        return down && id == press_id;
    }
    if (device == RETRO_DEVICE_POINTER && port == 1 && zapper_x >= 0) {
        if (id == RETRO_DEVICE_ID_POINTER_X) return (int16_t)(zapper_x * 0xFFFE / 256 - 0x7FFF);
        if (id == RETRO_DEVICE_ID_POINTER_Y) return (int16_t)(zapper_y * 0xFFFE / 224 - 0x7FFF);
        if (id == RETRO_DEVICE_ID_POINTER_PRESSED) return current_frame >= zapper_fire && current_frame < zapper_fire + 4;
    }
    return 0;
}

static unsigned char *read_file(const char *path, size_t *size) {
    FILE *f = fopen(path, "rb"); if (!f) return NULL;
    fseek(f, 0, SEEK_END); *size = ftell(f); fseek(f, 0, SEEK_SET);
    unsigned char *buf = malloc(*size); fread(buf, 1, *size, f); fclose(f); return buf;
}

int main(int argc, char **argv) {
    if (argc < 3) { fprintf(stderr, "usage: %s core rom [frames] [out.ppm] [--zapper x,y,fire] [--press frame]\n", argv[0]); return 2; }
    int frames = argc > 3 ? atoi(argv[3]) : 300;
    const char *out = argc > 4 && argv[4][0] != '-' ? argv[4] : NULL;
    for (int i = 3; i < argc; i++) {
        if (!strcmp(argv[i], "--zapper") && i + 1 < argc) sscanf(argv[i + 1], "%d,%d,%d", &zapper_x, &zapper_y, &zapper_fire);
        if (!strcmp(argv[i], "--press") && i + 1 < argc) press_frame = atoi(argv[i + 1]);
    }

    void *lib = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (!lib) { fprintf(stderr, "dlopen: %s\n", dlerror()); return 1; }
    LOAD(retro_init); LOAD(retro_deinit); LOAD(retro_api_version); LOAD(retro_get_system_info);
    LOAD(retro_get_system_av_info); LOAD(retro_set_environment); LOAD(retro_set_video_refresh);
    LOAD(retro_set_audio_sample); LOAD(retro_set_audio_sample_batch); LOAD(retro_set_input_poll);
    LOAD(retro_set_input_state); LOAD(retro_set_controller_port_device); LOAD(retro_run); LOAD(retro_reset);
    LOAD(retro_serialize_size); LOAD(retro_serialize); LOAD(retro_unserialize); LOAD(retro_load_game);
    LOAD(retro_unload_game); LOAD(retro_get_memory_data); LOAD(retro_get_memory_size); LOAD(retro_cheat_set);

    struct retro_system_info si; memset(&si, 0, sizeof si);
    retro_get_system_info_p(&si);
    printf("core: %s %s (api %u) extensions=%s fullpath=%d\n", si.library_name, si.library_version,
           retro_api_version_p(), si.valid_extensions, si.need_fullpath);

    retro_set_environment_p(env_cb);
    retro_set_video_refresh_p(video_cb);
    retro_set_audio_sample_p(audio_cb);
    retro_set_audio_sample_batch_p(audio_batch_cb);
    retro_set_input_poll_p(poll_cb);
    retro_set_input_state_p(input_cb);
    retro_init_p();

    size_t size; unsigned char *rom = read_file(argv[2], &size);
    if (!rom) { fprintf(stderr, "cannot read rom\n"); return 1; }
    struct retro_game_info gi = { argv[2], rom, size, NULL };
    if (!retro_load_game_p(&gi)) { fprintf(stderr, "load failed\n"); return 1; }
    if (zapper_x >= 0) retro_set_controller_port_device_p(1, RETRO_DEVICE_SUBCLASS(RETRO_DEVICE_LIGHTGUN, 0));

    struct retro_system_av_info av; retro_get_system_av_info_p(&av);
    printf("av: %ux%u (max %ux%u) aspect %.4f fps %.4f rate %.0f\n", av.geometry.base_width, av.geometry.base_height,
           av.geometry.max_width, av.geometry.max_height, av.geometry.aspect_ratio, av.timing.fps, av.timing.sample_rate);
    printf("memory: system ram %zu bytes, save ram %zu bytes\n",
           retro_get_memory_size_p(RETRO_MEMORY_SYSTEM_RAM), retro_get_memory_size_p(RETRO_MEMORY_SAVE_RAM));

    for (current_frame = 0; current_frame < frames; current_frame++) retro_run_p();

    size_t ss = retro_serialize_size_p();
    void *a = malloc(ss), *b = malloc(ss);
    bool ok = retro_serialize_p(a, ss);
    for (int i = 0; i < 60; i++) retro_run_p();
    unsigned char snap[256 * 240 * 4]; memcpy(snap, frame, sizeof snap);
    ok = ok && retro_unserialize_p(a, ss);
    for (int i = 0; i < 60; i++) retro_run_p();
    bool same = memcmp(snap, frame, sizeof snap) == 0;
    retro_serialize_p(b, ss);
    printf("state: %zu bytes, roundtrip %s, replay deterministic %s, size stable %s\n", ss, ok ? "ok" : "FAILED",
           same ? "yes" : "NO", retro_serialize_size_p() == ss ? "yes" : "NO");
    printf("audio: %.1f frames per video frame\n", (double)audio_frames / (frames + 120));

    if (out) {
        FILE *f = fopen(out, "wb");
        fprintf(f, "P6\n%u %u\n255\n", frame_w, frame_h);
        for (unsigned i = 0; i < frame_w * frame_h; i++) {
            unsigned char px[3] = { frame[i * 4 + 2], frame[i * 4 + 1], frame[i * 4 + 0] };
            fwrite(px, 1, 3, f);
        }
        fclose(f);
    }
    unsigned char *ram = retro_get_memory_data_p(RETRO_MEMORY_SYSTEM_RAM);
    printf("ram[$0000..$000F]:"); for (int i = 0; i < 16; i++) printf(" %02X", ram[i]); printf("\n");

    retro_unload_game_p();
    retro_deinit_p();
    printf("result: %s\n", ok && same && achievements_flag && memory_map_count > 0 ? "PASS" : "FAIL");
    return 0;
}
