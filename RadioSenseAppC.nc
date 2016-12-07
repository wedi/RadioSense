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
  components CC2420ControlC;
  components new AMSenderC(AM_MSG_T_RSSI);
  components new AMReceiverC(AM_MSG_T_RSSI);
  components new TimerMilliC() as WatchDogTimer;

  #if IS_ROOT_NODE
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
  App.CC2420Config -> CC2420ControlC.CC2420Config;
  App.AMSend -> AMSenderC;
  App.Receive -> AMReceiverC;
  App.WatchDogTimer -> WatchDogTimer;

  #if IS_ROOT_NODE
    App.UartByte -> PlatformSerialC;
  #endif
}
