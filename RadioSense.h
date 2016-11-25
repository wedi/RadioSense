#ifndef RADIOSENSE_H
#define RADIOSENSE_H

// Enable debug logging?
#ifndef DEBUG
  #define DEBUG 0
#endif

enum {
  AM_MSG_T_RSSI = 1,

  #if IS_ROOT_NODE
    WATCHDOG_TOLERANCE = 500 * NODE_COUNT,
    WATCHDOG_INIT_TIME = 2000
  #endif
};

static const int rssi_template[32] = {-1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1};

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
