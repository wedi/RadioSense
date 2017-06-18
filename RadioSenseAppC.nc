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
  components TimeSyncMessageC;
  components CC2420PacketC;
  components CC2420ControlC;
  components CC2420CsmaC;
  components CC2420ActiveMessageC;
  components new AlarmMilli32C() as SwitchTimer;
  components new TimerMilliC() as WatchDogTimer;
  components new TimerMilliC() as ErrorIndicatorResetTimer;

  #if IS_SINK_NODE
    components PlatformSerialC;
    components SerialStartC;
    components new PoolC(serial_msg_t, 25) as SerialMessagePool;
    components new QueueC(serial_msg_t*, 25) as SerialSendQueue;
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
  App.PacketAcknowledgements -> CC2420ActiveMessageC;
  App.RadioBackoff -> CC2420CsmaC;
  App.CC2420Config -> CC2420ControlC.CC2420Config;
  App.PacketTime -> TimeSyncMessageC;
  App.RadioSend -> TimeSyncMessageC.TimeSyncAMSendMilli[AM_MSG_T_RSSI];
  App.RadioReceive -> TimeSyncMessageC.Receive[AM_MSG_T_RSSI];
  App.WatchDogTimer -> WatchDogTimer;
  App.SwitchTimer -> SwitchTimer;
  App.ErrorIndicatorResetTimer -> ErrorIndicatorResetTimer;

  #if IS_SINK_NODE
    App.UartByte -> PlatformSerialC;
    App.SerialMessagePool -> SerialMessagePool;
    App.SerialSendQueue -> SerialSendQueue;
  #endif
}
