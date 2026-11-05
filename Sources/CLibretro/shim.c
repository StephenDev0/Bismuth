#include "bismuth_shim.h"
#include <stddef.h>

static const struct retro_variable variables[] = {
   { "bismuth_region",            "Region; Auto|NTSC|PAL|Dendy" },
   { "bismuth_palette",           "Palette; Composite (2C02)|Vivid|TV-accurate (muted)|RGB (2C03)|Composite PAL (2C07)|Greyscale" },
   { "bismuth_aspect",            "Aspect ratio; 8:7 PAR|4:3|1:1 PAR" },
   { "bismuth_overscan_v",        "Crop vertical overscan; enabled|disabled" },
   { "bismuth_overscan_h",        "Crop horizontal overscan; disabled|enabled" },
   { "bismuth_sprite_limit",      "Sprite limit (8 per line); enabled|disabled" },
   { "bismuth_four_score",        "Four Score (players 3-4); disabled|enabled" },
   { "bismuth_opposing",          "Allow opposing directions; disabled|enabled" },
   { "bismuth_zapper_tap",        "Tap screen to fire Zapper; enabled|disabled" },
   { "bismuth_zapper_input",      "Zapper aim input; Auto|Light gun|Pointer / touch" },
   { "bismuth_zapper_crosshair",  "Zapper crosshair; enabled|disabled" },
   { "bismuth_ram_init",          "Power-on RAM; Zeros|Ones|Alternating|Random" },
   { "bismuth_upscale",           "Upscaling; Off|Scale2x|Scale3x|Scale4x|Sharp 2x|Sharp 3x|Sharp 4x" },
   { "bismuth_audio_filter",      "Audio filter; NES (authentic)|Clean (brighter)" },
   { NULL, NULL },
};

#define PAD(port) \
   { port, RETRO_DEVICE_JOYPAD, 0, RETRO_DEVICE_ID_JOYPAD_LEFT,   "D-Pad Left" }, \
   { port, RETRO_DEVICE_JOYPAD, 0, RETRO_DEVICE_ID_JOYPAD_UP,     "D-Pad Up" }, \
   { port, RETRO_DEVICE_JOYPAD, 0, RETRO_DEVICE_ID_JOYPAD_DOWN,   "D-Pad Down" }, \
   { port, RETRO_DEVICE_JOYPAD, 0, RETRO_DEVICE_ID_JOYPAD_RIGHT,  "D-Pad Right" }, \
   { port, RETRO_DEVICE_JOYPAD, 0, RETRO_DEVICE_ID_JOYPAD_B,      "B" }, \
   { port, RETRO_DEVICE_JOYPAD, 0, RETRO_DEVICE_ID_JOYPAD_A,      "A" }, \
   { port, RETRO_DEVICE_JOYPAD, 0, RETRO_DEVICE_ID_JOYPAD_Y,      "Turbo B" }, \
   { port, RETRO_DEVICE_JOYPAD, 0, RETRO_DEVICE_ID_JOYPAD_X,      "Turbo A" }, \
   { port, RETRO_DEVICE_JOYPAD, 0, RETRO_DEVICE_ID_JOYPAD_SELECT, "Select" }, \
   { port, RETRO_DEVICE_JOYPAD, 0, RETRO_DEVICE_ID_JOYPAD_START,  "Start" }

static const struct retro_input_descriptor descriptors[] = {
   PAD(0), PAD(1), PAD(2), PAD(3),
   { 1, RETRO_DEVICE_LIGHTGUN, 0, RETRO_DEVICE_ID_LIGHTGUN_TRIGGER, "Zapper Trigger" },
   { 1, RETRO_DEVICE_LIGHTGUN, 0, RETRO_DEVICE_ID_LIGHTGUN_RELOAD,  "Zapper Off-screen Shot" },
   { 0, 0, 0, 0, NULL },
};

static const struct retro_controller_description main_ports[] = {
   { "Gamepad",     BISMUTH_DEVICE_GAMEPAD },
   { "Zapper",      BISMUTH_DEVICE_ZAPPER },
   { "None",        BISMUTH_DEVICE_NONE },
};

static const struct retro_controller_description extra_ports[] = {
   { "Gamepad (Four Score)", BISMUTH_DEVICE_GAMEPAD },
   { "None",                 BISMUTH_DEVICE_NONE },
};

static const struct retro_controller_info controller_info[] = {
   { main_ports, 3 },
   { main_ports, 3 },
   { extra_ports, 2 },
   { extra_ports, 2 },
   { NULL, 0 },
};

const struct retro_variable *bismuth_core_variables(void) { return variables; }
const struct retro_input_descriptor *bismuth_input_descriptors(void) { return descriptors; }
const struct retro_controller_info *bismuth_controller_info(void) { return controller_info; }

const char *bismuth_library_name(void) { return "Bismuth"; }
const char *bismuth_library_version(void) { return "1.0.0"; }
const char *bismuth_valid_extensions(void) { return "nes"; }
const char *bismuth_addrspace_ram(void) { return "RAM"; }
const char *bismuth_addrspace_wram(void) { return "WRAM"; }

void bismuth_log(retro_log_printf_t callback, enum retro_log_level level, const char *message)
{
   if (callback && message)
      callback(level, "[Bismuth] %s\n", message);
}
