// Shim root for the build.zig translateC step: exposes the system
// libsystemd sd-bus API as the Zig module `@import("sd_bus")`.
// Linked by name (`-lsystemd`); no vendored sources.
#pragma once

#include <systemd/sd-bus.h>
