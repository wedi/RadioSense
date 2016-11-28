#ifndef RADIOSENSE_H
#define RADIOSENSE_H

// Enable debug logging?
#ifndef DEBUG
  #define DEBUG 0
#endif

enum {
  AM_MSG_T_RSSI = 1,

  #if IS_ROOT_NODE
    // Milliseconds. Set higher than necessary to be able to see the watchdog
    // hitting from looking at the nodes. Could be as small as ~15 * NODE_COUNT.
    WATCHDOG_TOLERANCE = 500 * NODE_COUNT,
    WATCHDOG_INIT_TIME = 2000
  #endif
};

// chose a number well above possible RSSI values but not 127
// as that might have a different meaning somewhere else.
static const int8_t rssi_template[32] = {81, 81, 81, 81, 81, 81, 81, 81, 81, 81, 81, 81, 81, 81, 81, 81, 81, 81, 81, 81, 81, 81, 81, 81, 81, 81, 81, 81, 81, 81, 81, 81};
#if NODE_COUNT > 32
 #error You need to extend `rssi_template` when using more than 32 nodes!
#endif

typedef nx_struct msg_rssi_t {
  //nx_uint32_t seq;
  nx_int8_t rssi[NODE_COUNT];
} msg_rssi_t;

#if DEBUG
  #define DPRINTF(x) printf x; printfflush()
#else
  #define DPRINTF(x)
#endif

#endif
