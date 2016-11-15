#ifndef RADIOSENSE_H
#define RADIOSENSE_H

// Enable debug logging?
#ifndef DEBUG
#define DEBUG 0
#endif

enum {
  AM_MSG_T_RSSI = 1,
  ROOT_NODE_ADDR = 1,
  #if DEBUG
    SEND_DELAY = 50,
    WATCHDOG_TOLERANCE_MILLI = 100,
  #else
    SEND_DELAY = 5,
    WATCHDOG_TOLERANCE_MILLI = 500,
  #endif
  WATCHDOG_INIT_TIME = 2000,
  INVALID_RSSI = 127,
};

typedef nx_struct msg_rssi_t {
  nx_uint32_t seq;
  nx_int8_t rssi[NODE_COUNT+1];
} msg_rssi_t;

#endif

#if DEBUG
# define DPRINTF(x) printf x; printfflush()
#else
# define DPRINTF(x) do {} while (0)
#endif
