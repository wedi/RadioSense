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
  #if IS_ROOT_NODE
    uses interface Timer<TMilli> as WatchDogTimer;
    uses interface UartByte;
  #endif
}

implementation {

/* * Declare tasks & functions * * * * * * * * * * * * * * * * * * * */

  inline void initPacket();
  task void sendRssi();
  #if IS_ROOT_NODE
    task void printCollectedData();
  #endif



  /* * Global variables  * * * * * * * * * * * * * * * * * * * * * * */

  message_t packet;
  msg_rssi_t* rssiMsg;
  //uint32_t seq = 0;
  am_addr_t lastSeenNodeID;
  uint8_t channel;

  #if IS_ROOT_NODE
    am_addr_t printMsgId;
    msg_rssi_t printMsg;
  #endif



  /* * Boot sequence events  * * * * * * * * * * * * * * * * * * * * */

  /**
   * Device is booted and ready, start radio.
   */
  event void Boot.booted() {
    // Red LED0 indicates the startup process
    call Leds.led0On();
    // start radio
    call AMControl.start();

    rssiMsg = (msg_rssi_t*) call AMSend.getPayload(&packet, sizeof(msg_rssi_t));
    // init packet
    // reset RSSI values
    memcpy(rssiMsg->rssi, rssi_template, NODE_COUNT+1);
    // make sure the node will not believe it's his turn
    // Neat: Setting unsigned var to -1 sets it to MAX
    lastSeenNodeID = -1;
    channel = CC2420_DEF_CHANNEL;
  }


  /**
   * Radio started, start watchdog timer on the root node.
   */
  event void AMControl.startDone(error_t err) {
    if (err == SUCCESS) {
      #if IS_ROOT_NODE
        // Wait for the other nodes to start up
        call WatchDogTimer.startOneShot(WATCHDOG_INIT_TIME);
      #endif
      call Leds.set(0b010);  // red/green/blue
      DPRINTF(("Mote ready to rumble!\n"));
    } else {
      // error during radio startup, keep trying
      DPRINTF(("Couldn't start the radio. (Code: %u)\n", err));
      call AMControl.start();
    }
  }


  /**
   * Radio stopped. Unused.
   */
  event void AMControl.stopDone(error_t result) {
    /* nothing. will not happen */
  }



  /* * Message sending * * * * * * * * * * * * * * * * * * * * * * * */

  /**
   * Send out our message
   */
  task void sendRssi() {
    error_t result;

    // indicate with blue LED
    call Leds.led2On();

    #if IS_ROOT_NODE
      // root node prints its own RSSI array
      printMsgId = ROOT_NODE_ADDR;
      printMsg = *rssiMsg;
      post printCollectedData();
    #endif

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
    // reset RSSI values
    memcpy(rssiMsg->rssi, rssi_template, NODE_COUNT+1);
    call Leds.led2Off();
  }



  /* * Message recieving * * * * * * * * * * * * * * * * * * * * * */

  /**
   * Event fires on new message recieved.
   */
  event message_t* Receive.receive(message_t* msg, void* payload, uint8_t len) {
    int8_t rssi;
    #if IS_ROOT_NODE
      msg_rssi_t* pl;
    #endif

    rssi = call CC2420Packet.getRssi(msg);
    lastSeenNodeID = call AMPacket.source(msg);

    DPRINTF(("Received message from %u with RSSI %d.\n", lastSeenNodeID, rssi));

    /* Save Rssi values to outgoing rssi msg */
    rssiMsg->rssi[lastSeenNodeID-1] = rssi;

    // root node prints RSSI
    #if IS_ROOT_NODE
      printMsgId = lastSeenNodeID;
      pl = (msg_rssi_t*) payload;
      printMsg = (msg_rssi_t) *pl;
      post printCollectedData();
      call WatchDogTimer.startOneShot(WATCHDOG_TOLERANCE);
      if (lastSeenNodeID == NODE_COUNT) {
        DPRINTF(("Yeah! It's me now! The ROOT NODE! hehehe.\n"));
        post sendRssi();
      }
    #else
    // if this was my predecessor, turn off watchdog and start SendDelayTimer
    if (lastSeenNodeID == TOS_NODE_ID - 1) {
      DPRINTF(("Yeah! It's me now!\n"));
      post sendRssi();
    }
    #endif
    return msg;
  }



  /* * Root node only: Watchdog / serial * * * * * * * * * * * * * * */
  #if IS_ROOT_NODE

  /**
   * Fires if waited too long for receiving a message from another node.
   */
  event void WatchDogTimer.fired() {
    DPRINTF(("Watchdog fired! Last node seen %u\n", lastSeenNodeID));
    post sendRssi();
    call WatchDogTimer.startOneShot(WATCHDOG_TOLERANCE);
  }


  /**
   * Prints a nodes RSSI array
   */
  task void printCollectedData() {
    int8_t i;
    call Leds.led0On();

    //am_addr_t id, uint32_t pkgSeq, nx_int8_t rssi[]
    DPRINTF(("Reporting home...\n"));
    #if DEBUG
    DPRINTF(("NodeID %u\n", lastSeenNodeID));
    DPRINTF(("NODE_COUNT %u\n", NODE_COUNT));
    //DPRINTF(("SEQ %lu\n", printMsg.seq));
    DPRINTF(("RSSI["));
    for (i = 0; i < NODE_COUNT; ++i) {
      DPRINTF(("%i ", printMsg.rssi[i]));
    }
    DPRINTF(("]RSSI_END\n"));
    #else

    // ID + node count
    call UartByte.send(printMsgId);
    call UartByte.send(NODE_COUNT);
    // can be used to determine packet loss
    //call UartByte.send(printMsg.seq);

    // RSSI
    for (i = 0; i < NODE_COUNT; ++i) {
      call UartByte.send(printMsg.rssi[i]);
    }

    // sync bytes (0xC0DE)
    call UartByte.send(0xC);
    call UartByte.send(0x0);
    call UartByte.send(0xD);
    call UartByte.send(0xE);
    #endif
    call Leds.led0Off();
  }

  #endif /* IS_ROOT_NODE */

}
