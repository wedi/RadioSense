#include <Timer.h>
#include "RadioSense.h"
#include "printf.h"

module RadioSenseC {
  uses interface Boot;
  uses interface Leds;
  uses interface SplitControl as AMControl;
  uses interface AMPacket;
  uses interface CC2420Packet;
  uses interface CC2420Config;
  uses interface AMSend;
  uses interface Receive;
  #if IS_ROOT_NODE
    uses interface Timer<TMilli> as WatchDogTimer;
    uses interface UartByte;
  #endif
}

implementation {

/* * Declare tasks & functions * * * * * * * * * * * * * * * * * * * */

  inline void switch_channel();
  task void sendRssi();
  #if IS_ROOT_NODE
    task void printCollectedData();
  #endif



  /* * Global variables  * * * * * * * * * * * * * * * * * * * * * * */

  message_t packet;
  msg_rssi_t* rssiMsg;
  //uint32_t seq = 0;
  am_addr_t lastSeenNodeID;
  const uint8_t* channel = &channels[0];

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
  }


  /**
   * Radio started, start watchdog timer on the root node to wait for others.
   */
  event void AMControl.startDone(error_t err) {
    #if DEBUG
      uint8_t i;
    #endif

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

    #if DEBUG
      DPRINTF(("Channel list: "));
      for (i=0; i < (sizeof(channels) / sizeof (channels[0])); i++) {
        DPRINTF(("%u ",channels[i]));
      }
      DPRINTF(("\n"));
    #endif
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
      printMsgId = TOS_NODE_ID;
      printMsg = *rssiMsg;
      post printCollectedData();
    #endif

    DPRINTF(("Sending on channel %u.\n", *channel));
    result = call AMSend.send(AM_BROADCAST_ADDR, &packet, sizeof(msg_rssi_t));
    if (result != SUCCESS) {
      DPRINTF(("Radio did not accept message. Code: %u.\n", result));
      // not resending, accept failure of cycle to avoid other problems
    } else {
      DPRINTF(("Sending...\n"));
    }
  }


  /**
   * Broadcast sent
   */
  event void AMSend.sendDone(message_t* msg, error_t result) {
    if (result != SUCCESS) {
      DPRINTF(("Error sending data. Code: %u.\n", result));
    }
    if(TOS_NODE_ID == NODE_COUNT) {
      // last node switches right after sending
      DPRINTF(("Switching channel...\n"));
      switch_channel();
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
      printMsg = *pl;
      post printCollectedData();
      call WatchDogTimer.startOneShot(WATCHDOG_TOLERANCE);

    #else
      // send if it was my predecessor's turn
      if (lastSeenNodeID == TOS_NODE_ID - 1) {
        DPRINTF(("Yeah! It's me now!\n"));
        post sendRssi();
      }

    #endif

    if (lastSeenNodeID == NODE_COUNT) {
      DPRINTF(("Switching channel...\n"));
      // last node switches in AMSend.sendDone
      switch_channel();
    }

    return msg;
  }



  /* * Channel switching * * * * * * * * * * * * * * * * * * * * * * */


  /**
   * Switch radio to next channel.
   */
  inline void switch_channel() {
    // Bail out if there is just one channel in the list
    // Attention! See comment about sizeof below!
    if (sizeof(channels) == 1)
      return;

    DPRINTF(("Old channel: %u\n", *channel));

    // Attention! This only works because uint8_t has 1 byte!
    // Generic alternative: sizeof(channels) / sizeof(channels[0])
    if (channel == &channels[sizeof(channels) - 1]) {
      channel = &channels[0];
    } else {
      ++channel;
    }

    DPRINTF(("Next channel: %u\n", *channel));

    call CC2420Config.setChannel(*channel);
    call CC2420Config.sync();
  }


  /**
   * Event fired when channel switching is complete.
   */
  event void CC2420Config.syncDone(error_t result) {
    if (result != SUCCESS) {
      DPRINTF(("Channel switching failed with code '%u'.\n", result));
      // on error switch to first channel and wait
      call CC2420Config.setChannel(channels[0]);
      call CC2420Config.sync();
      return;
    }

    DPRINTF(("Switched channel to '%u'\n", *channel));

    #if IS_ROOT_NODE
      // switching before root node sends => it's always its term here.
      post sendRssi();
    #endif
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
   * Prints a nodes RSSI array.
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
