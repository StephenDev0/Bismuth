#ifndef BISMUTH_SHIM_H
#define BISMUTH_SHIM_H

#include "libretro.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Device ids exposed by the core. */
#define BISMUTH_DEVICE_NONE     RETRO_DEVICE_NONE
#define BISMUTH_DEVICE_GAMEPAD  RETRO_DEVICE_JOYPAD
#define BISMUTH_DEVICE_ZAPPER   RETRO_DEVICE_SUBCLASS(RETRO_DEVICE_LIGHTGUN, 0)

/* Static tables that must outlive the calls that hand them to the frontend. */
const struct retro_variable *bismuth_core_variables(void);
const struct retro_input_descriptor *bismuth_input_descriptors(void);
const struct retro_controller_info *bismuth_controller_info(void);

const char *bismuth_library_name(void);
const char *bismuth_library_version(void);
const char *bismuth_valid_extensions(void);
const char *bismuth_addrspace_ram(void);
const char *bismuth_addrspace_wram(void);

/* libretro's log callback is variadic, which Swift cannot call directly. */
void bismuth_log(retro_log_printf_t callback, enum retro_log_level level, const char *message);

#ifdef __cplusplus
}
#endif

#endif
