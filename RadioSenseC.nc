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
  uses interface Timer<TMilli> as WatchDogTimer;
  #if IS_ROOT_NODE
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
  msg_rssi_t* outgoingMsg;
  am_addr_t lastSeenNodeID;
  const uint8_t* channel = &channels[0];

  #if IS_ROOT_NODE
    am_addr_t recvdMsgSenderID;
    msg_rssi_t recvdMsg;
    uint8_t recvdChannel;
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

    // make outgoingMsg pointing to the payload of the ActiveMessage being send via radio
    outgoingMsg = (msg_rssi_t*) call AMSend.getPayload(&packet, sizeof(msg_rssi_t));

    // Initialize RSSI values
    memcpy(outgoingMsg->rssi, rssi_template, NODE_COUNT+1);

    // set to next node in circle
    //   * makes sure the node will not believe it's his turn
    //   * will correctly calculate the initial wachdog period
    lastSeenNodeID = (TOS_NODE_ID + 1) % NODE_COUNT;
  }


  /**
   * Radio started, start watchdog timer on the root node to wait for others.
   */
  event void AMControl.startDone(error_t err) {

    if (err == SUCCESS) {
      #if IS_ROOT_NODE
        // Wait for the other nodes to start up, then send.
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
      do {
        DPRINTF(("%u ",*channel));
        ++channel;
      } while(channel < &channels[NODE_COUNT]);
      DPRINTF(("\n"));
      channel = &channels[0];
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

    // Stop watchdog. Prevents destroying the circle when the group
    // comes back after a node was lost.
    call WatchDogTimer.stop();

    #if IS_ROOT_NODE
      // root node prints its own RSSI array
      recvdMsgSenderID = TOS_NODE_ID;
      recvdMsg = *outgoingMsg;
      recvdChannel = *channel;
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
    memcpy(outgoingMsg->rssi, rssi_template, NODE_COUNT+1);
    call Leds.led2Off();
  }



  /* * Message recieving * * * * * * * * * * * * * * * * * * * * * */

  /**
   * Event fires on new message recieved.
   */
  event message_t* Receive.receive(message_t* msg, void* payload, uint8_t len) {
    int8_t rssi;
    uint8_t distanceToLast;
    #if IS_ROOT_NODE
      msg_rssi_t* pl;
    #endif

    rssi = call CC2420Packet.getRssi(msg);
    lastSeenNodeID = call AMPacket.source(msg);
    DPRINTF(("Received message from %u with RSSI %d.\n", lastSeenNodeID, rssi));

    // reset watchdog
    distanceToLast = (
      TOS_NODE_ID - lastSeenNodeID + NODE_COUNT - 1) % NODE_COUNT;
    call WatchDogTimer.startOneShot(
      distanceToLast * WATCHDOG_TOLERANCE_PER_NODE + WATCHDOG_TOLERANCE);

    DPRINTF(("Distance: %u\n", distanceToLast));
    DPRINTF(("Watchdog timer: %u\n",
      distanceToLast * WATCHDOG_TOLERANCE_PER_NODE + WATCHDOG_TOLERANCE));

    /* Save Rssi values to outgoing rssi msg */
    outgoingMsg->rssi[lastSeenNodeID-1] = rssi;

    // root node prints RSSI
    #if IS_ROOT_NODE
      recvdMsgSenderID = lastSeenNodeID;
      pl = (msg_rssi_t*) payload;
      recvdMsg = *pl;
      recvdChannel = *channel;
      post printCollectedData();

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
    if (sizeof(channels) == 1) {
      #if IS_ROOT_NODE
        // root node sends after channel switching
        // no channel switching so we do it here
        post sendRssi();
      #endif
      return;
    }
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


  /**
   * Fires if waited too long for receiving a message from another node.
   * Fires on startup after WATCHDOG_INIT_TIME is elapsed.
   */
  event void WatchDogTimer.fired() {
    DPRINTF(("Watchdog fired! Last node seen %u\n", lastSeenNodeID));
    post sendRssi();
  }


  /* * Root node only: serial writing  * * * * * * * * * * * * * * * */
  #if IS_ROOT_NODE

  /**
   * Sends collected data to the serial.
   */
  task void printCollectedData() {
    int8_t i;

    call Leds.led0On();

    #if DEBUG
      DPRINTF(("Reporting home...\n"));
      DPRINTF(("NodeID %u\n", recvdMsgSenderID));
      DPRINTF(("LastSeenNodeID %u\n", lastSeenNodeID));
      DPRINTF(("NODE_COUNT %u\n", NODE_COUNT));
      DPRINTF(("RSSI["));
      for (i = 0; i < NODE_COUNT; ++i) {
        DPRINTF(("%i ", recvdMsg.rssi[i]));
      }
      DPRINTF(("]RSSI_END\n"));

    #else

    // ID + channel
    call UartByte.send(recvdMsgSenderID);
    call UartByte.send(recvdChannel);

    // RSSI
    for (i = 0; i < NODE_COUNT; ++i) {
      call UartByte.send(recvdMsg.rssi[i]);
    }

    // sync bytes (0xC0DE)
    call UartByte.send(0xC);
    call UartByte.send(0x0);
    call UartByte.send(0xD);
    call UartByte.send(0xE);

    #endif /* DEBUG else */

    call Leds.led0Off();
  }

  #endif /* IS_ROOT_NODE */

}
