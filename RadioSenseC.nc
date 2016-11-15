#include <Timer.h>
#include "RadioSense.h"
#include "printf.h"

module RadioSenseC {
  uses interface Boot;
  uses interface Leds;
  uses interface SplitControl as AMControl;
  uses interface AMPacket;
  uses interface CC2420Packet;
  uses interface AMSend;
  uses interface Receive;
  uses interface Timer<TMilli> as SendDelayTimer;
  uses interface Timer<TMilli> as WatchDogTimer;
  uses interface LocalTime<TMilli> as LocalTime;
  uses interface UartByte;
}

implementation {

  void initPacket();
  bool itsMyTurn();
  void printRssiMsg(am_addr_t id, uint32_t seq, nx_int8_t rssi[]);
  void saveRssi(am_addr_t id, int8_t rssi);
  task void sendRssi();
  void startSending();


  message_t packet;
  uint32_t seq = 0;
  am_addr_t lastSeenNodeID;

  #if DEBUG
    uint32_t timestampLastPacket = 0;
  #endif


  /**
   * Device is booted and ready, start radio.
   */
  event void Boot.booted() {
    // Red LED0 indicates the startup process
    call Leds.led0On();
    // start radio
    call AMControl.start();
    initPacket();
    lastSeenNodeID = TOS_NODE_ID + 1;
  }


  /**
   * Radio started, start watchdog timer on the root node.
   */
  event void AMControl.startDone(error_t result) {
    // on successful radio startup, reset LEDs
    if (result == SUCCESS) {
      if (TOS_NODE_ID == ROOT_NODE_ADDR) {
        // Wait for the other nodes to start up
        call WatchDogTimer.startOneShot(WATCHDOG_INIT_TIME);
      }
      call Leds.set(0b010);  // red/green/blue
      DPRINTF(("Mote ready to rumble!\n"));
    } else {
      DPRINTF(("Couldn't start the radio. (Code: %u)\n", result));
      // on error during radio startup, keep trying with red LED on
      call Leds.led0On();
      call AMControl.start();
    }
  }


  /**
   * Radio stopped.
   */
  event void AMControl.stopDone(error_t result) {
    call Leds.set(0);
  }


  /**
   * Fires if send delay is over.
   */
  event void SendDelayTimer.fired() {
    DPRINTF(("SendDelayTimer fired! Let's do it.\n"));
    post sendRssi();
  }


  /**
   * Send out our message
   */
  task void sendRssi() {
    error_t result;
    msg_rssi_t* rssiMsg;
    rssiMsg = (msg_rssi_t*) call AMSend.getPayload(&packet, sizeof(msg_rssi_t));

    # indicate with blue LED
    call Leds.led2On();
    if (TOS_NODE_ID == ROOT_NODE_ADDR) {
      // root node prints its own RSSI array
      printRssiMsg(ROOT_NODE_ADDR, rssiMsg->seq, rssiMsg->rssi);
    }
    result = call AMSend.send(AM_BROADCAST_ADDR, &packet, sizeof(msg_rssi_t));
    if (result != SUCCESS) {
      DPRINTF(("Radio did not accept message. Code: %u.\n", result));
    } else {
      DPRINTF(("Sending...\n"));
    }
  }


  /**
   * Broadcast sent, increase sequenz number
   */
  event void AMSend.sendDone(message_t* msg, error_t result) {
    if (result != SUCCESS) {
      DPRINTF(("Error sending data. Code: %u.\n", result));
    }
    seq++;
    // reset RSSI values
    initPacket();
    call Leds.led2Off();
  }


  /**
   * Event fires on new message recieved
   */
  event message_t* Receive.receive(message_t* msg, void* payload, uint8_t len) {
    msg_rssi_t* rssiMsg;
    int8_t rssi;
    am_addr_t source;

    #if DEBUG
      uint32_t newPacketTimestamp = call LocalTime.get();
      uint32_t timeSinceLast = newPacketTimestamp - timestampLastPacket;
      DPRINTF(("Time since last package from %u is %lu.\n", lastSeenNodeID,
             timeSinceLast));
      timestampLastPacket = newPacketTimestamp;
    #endif

    rssiMsg = (msg_rssi_t*) payload;
    rssi = call CC2420Packet.getRssi(msg);
    source = call AMPacket.source(msg);

    DPRINTF(("Received a message from %u with RSSI %d.\n", source, rssi));
    saveRssi(source, rssi);

    // root node prints RSSI
    if (TOS_NODE_ID == ROOT_NODE_ADDR) {
      printRssiMsg(source, rssiMsg->seq, rssiMsg->rssi);
    }

    lastSeenNodeID = source;

    // activate watchdog, if necessary
    if (TOS_NODE_ID == ROOT_NODE_ADDR) {
      call WatchDogTimer.startOneShot(WATCHDOG_TOLERANCE_MILLI);
    }

    // if this was my predecessor, turn off watchdog and start SendDelayTimer
    if (itsMyTurn()) {
      call SendDelayTimer.startOneShot(SEND_DELAY);
    }
    return msg;
  }


  /**
   * Fires if waited long enough receiving a message from another node.
   */
  event void WatchDogTimer.fired() {
    DPRINTF(("Watchdog fired! Last node seen %u\n", lastSeenNodeID));
    post sendRssi();
    call WatchDogTimer.startOneShot(WATCHDOG_TOLERANCE_MILLI);
  }


  /**
   * Initialize msg Packet
   */
  void initPacket() {
    int8_t i;
    msg_rssi_t* rssiMsg;
    rssiMsg = (msg_rssi_t*) call AMSend.getPayload(&packet, sizeof(msg_rssi_t));

    rssiMsg->seq = seq;
    for (i = 0; i <= NODE_COUNT; i++) {
      rssiMsg->rssi[i] = INVALID_RSSI;
    }
  }


  /**
   * Calculates if it's the currents node turn to send the next message.
   * @return TRUE if node should send, FALSE if not.
   */
  bool itsMyTurn() {
    if (lastSeenNodeID + 1 == TOS_NODE_ID ||
          (TOS_NODE_ID == 1 && lastSeenNodeID == NODE_COUNT)) {
      DPRINTF(("Yeah! It's me now!\n"));
      return TRUE;
    } else {
      DPRINTF(("It's not me now!\n"));
      return FALSE;
    }
  }


  /**
   * Saves new RSSI value to our own rssiMsg
   */
  void saveRssi(am_addr_t id, int8_t rssi) {
    msg_rssi_t* rssiMsg;
    rssiMsg = (msg_rssi_t*) call AMSend.getPayload(&packet, sizeof(msg_rssi_t));
    DPRINTF(("Saving RSSI %d for node %u! => ", rssi, id));
    rssiMsg->rssi[id] = rssi;
    DPRINTF(("Result is RSSI %d.\n", rssiMsg->rssi[id]));
    //printRssiMsg(TOS_NODE_ID, rssiMsg);
  }


  /**
   * Prints a nodes RSSI array
   */
  void printRssiMsg(am_addr_t id, uint32_t pkgSeq, nx_int8_t rssi[]) {
    uint8_t i;

    // sync bytes (0xC0DE)
    call UartByte.send(0xC);
    call UartByte.send(0x0);
    call UartByte.send(0xD);
    call UartByte.send(0xE);

    // ID + node count
    call UartByte.send(id);
    call UartByte.send(NODE_COUNT);

    // RSSI
    for (i = 1; i <= NODE_COUNT; i++) {
      call UartByte.send(rssi[i]);
    }

    // trailer bytes (0xED0C)
    call UartByte.send(0xE);
    call UartByte.send(0xD);
    call UartByte.send(0x0);
    call UartByte.send(0xC);
  }
}
