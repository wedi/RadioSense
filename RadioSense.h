#ifndef RADIOSENSE_H
#define RADIOSENSE_H

// Enable debug logging?
// This is actually not needed but Python tought me
// "explicit is better than implicit." :)
#ifndef DEBUG
  #define DEBUG 0
#endif

enum {
  // ActiveMessage type identifier
  AM_MSG_T_RSSI = 1,

  // Watchdog time settings in milliseconds

  // Time to wait per node before watchdog hits
  WATCHDOG_TOLERANCE_PER_NODE = 35,

  #if IS_ROOT_NODE
    // Time to wait after startup to make sure all nodes are ready
    WATCHDOG_INIT_TIME = 5000,

    // Additional fixed time before watchdog hits
    // root node needs some more time for the channel switching
    WATCHDOG_TOLERANCE = 25,
  #else
    WATCHDOG_TOLERANCE = 0,
  #endif
};

// set channels to switch through
static const uint8_t channels[] = {CHANNEL_LIST};

// Template to initialize rssi array with
// https://gcc.gnu.org/onlinedocs/gcc/Designated-Inits.html#Designated-Inits
// Chose a number well above possible RSSI values.
// Not using 127 here as that might have a different meaning somewhere else.
// Not using 126 as it might be used as package delimiter on the serial line later
static const int8_t rssi_template[NODE_COUNT] = { [0 ... NODE_COUNT-1] = 81 };

typedef nx_struct msg_rssi_t {
  nx_int8_t rssi[NODE_COUNT];
} msg_rssi_t;

#if DEBUG
  #define DPRINTF(x) printf x; printfflush()
#else
  #define DPRINTF(x)
#endif

#endif
