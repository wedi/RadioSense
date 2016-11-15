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
  components new TimerMilliC() as SendDelayTimer;
  components new TimerMilliC() as WatchDogTimer;
  components LocalTimeMilliC as LocalTime;
  components PrintfC;
  components SerialStartC;
  components PlatformSerialC;

  App.Boot -> MainC;
  App.Leds -> LedsC;
  App.AMControl -> ActiveMessageC;
  App.AMPacket -> ActiveMessageC;
  App.CC2420Packet -> CC2420PacketC;
  App.AMSend -> AMSenderC;
  App.Receive -> AMReceiverC;
  App.SendDelayTimer -> SendDelayTimer;
  App.WatchDogTimer -> WatchDogTimer;
  App.LocalTime -> LocalTime;
  App.UartByte -> PlatformSerialC;
}
