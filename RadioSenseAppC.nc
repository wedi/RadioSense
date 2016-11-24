#include <Timer.h>
#include "RadioSense.h"
#include "printf.h"

configuration RadioSenseAppC {
}

implementation {
  components RadioSenseC as App;
  components MainC;
  components LedsC;
  components ActiveMessageC;
  components CC2420PacketC;
  components new AMSenderC(AM_MSG_T_RSSI);
  components new AMReceiverC(AM_MSG_T_RSSI);

  #if IS_ROOT_NODE
    components new TimerMilliC() as WatchDogTimer;
    components PlatformSerialC;
    components SerialStartC;
  #endif

  #if DEBUG
    components SerialPrintfC;
  #endif

  App.Boot -> MainC;
  App.Leds -> LedsC;
  App.AMControl -> ActiveMessageC;
  App.AMPacket -> ActiveMessageC;
  App.CC2420Packet -> CC2420PacketC;
  App.AMSend -> AMSenderC;
  App.Receive -> AMReceiverC;

  #if IS_ROOT_NODE
    App.WatchDogTimer -> WatchDogTimer;
    App.UartByte -> PlatformSerialC;
  #endif
}
