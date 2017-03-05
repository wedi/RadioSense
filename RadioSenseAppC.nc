#include <Timer.h>
#include "RadioSense.h"
#include "printf.h"

configuration RadioSenseAppC {
}

implementation {
  components RadioSenseC as App;
  components MainC;
  components SWResetC;
  components LedsC;
  components ActiveMessageC;
  components CC2420PacketC;
  components CC2420ControlC;
  components new AMSenderC(AM_MSG_T_RSSI);
  components new AMReceiverC(AM_MSG_T_RSSI);
  components new TimerMilliC() as WatchDogTimer;
  components new TimerMilliC() as ErrorIndicatorResetTimer;

  #if IS_SINK_NODE
    components PlatformSerialC;
    components SerialStartC;
    components new PoolC(serial_msg_t, 10) as SerialMessagePool;
    components new QueueC(serial_msg_t*, 10) as SerialSendQueue;
  #endif

  #if DEBUG
    components SerialPrintfC;
  #endif

  App.Boot -> MainC;
  App.SWReset -> SWResetC;
  App.Leds -> LedsC;
  App.AMControl -> ActiveMessageC;
  App.AMPacket -> ActiveMessageC;
  App.CC2420Packet -> CC2420PacketC;
  App.CC2420Config -> CC2420ControlC.CC2420Config;
  App.AMSend -> AMSenderC;
  App.Receive -> AMReceiverC;
  App.WatchDogTimer -> WatchDogTimer;
  App.ErrorIndicatorResetTimer -> ErrorIndicatorResetTimer;

  #if IS_SINK_NODE
    App.UartByte -> PlatformSerialC;
    App.SerialMessagePool -> SerialMessagePool;
    App.SerialSendQueue -> SerialSendQueue;
  #endif
}
