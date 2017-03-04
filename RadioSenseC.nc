#include <Timer.h>
#include "RadioSense.h"
#include "printf.h"

module RadioSenseC {
  uses interface Boot;
  uses interface SWReset;
  uses interface Leds;
  uses interface SplitControl as AMControl;
  uses interface AMPacket;
  uses interface CC2420Packet;
  uses interface CC2420Config;
  uses interface AMSend;
  uses interface Receive;
  uses interface Timer<TMilli> as WatchDogTimer;
  uses interface Timer<TMilli> as ErrorIndicatorResetTimer;
  #if IS_SINK_NODE
    uses interface UartByte;
  #endif
}

implementation {

/* * Declare tasks & functions * * * * * * * * * * * * * * * * * * * */

  static inline void switch_channel();
  static inline void radio_failure(uint16_t const led_time);
  static inline void reset_radio_failure();
  task void sendRssi();
  #if IS_SINK_NODE
    static inline void uart_sync();
    task void printCollectedData();
  #endif



  /* * Global variables  * * * * * * * * * * * * * * * * * * * * * * */

  message_t packet;
  msg_rssi_t* outgoingMsg;
  am_addr_t lastSeenNodeID;
  uint8_t rf_failure_counter;
  const uint8_t* channel = &channels[0];
  bool halted = FALSE;

  #if IS_SINK_NODE
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
      #if IS_SINK_NODE && ! DEBUG
          // send sync bytes
          uart_sync();
      #endif

      #if IS_ROOT_NODE
        // Wait for the other nodes to start up, then send.
        call WatchDogTimer.startOneShot(WATCHDOG_INIT_TIME);
      #endif

      // reset failure counter
      rf_failure_counter = 0;

      call Leds.set(0b010);  // red/green/blue
      DPRINTF(("Mote ready to rumble!\n"));

    } else {
      // error during radio startup, keep trying
      DPRINTF(("Couldn't start the radio. (Code: %u)\n", err));
      call Leds.led2On();
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
    /* Just in case... */
    call Leds.set(0b001);
    call AMControl.start();
  }


static inline void radio_failure(uint16_t const led_time) {
    call Leds.led0On();
    call ErrorIndicatorResetTimer.startOneShot(led_time);
    ++rf_failure_counter;
    if (rf_failure_counter >= RF_FAILURE_THRESHOLD) {
      halted = TRUE;
      call WatchDogTimer.stop();
      call AMControl.stop();
      call ErrorIndicatorResetTimer.stop();
      call Leds.set(0b001);
      call SWReset.reset();
    }
  }

  static inline void reset_radio_failure() {
    call ErrorIndicatorResetTimer.stop();
    call Leds.led0Off();
    call Leds.led2Off();
    rf_failure_counter = 0;
    halted = FALSE;
  }



  /* * Message sending * * * * * * * * * * * * * * * * * * * * * * * */

  /**
   * Send out our message
   */
  task void sendRssi() {
    error_t result;

    if (halted) {
      return;
    }

    // indicate with blue LED
    call Leds.led2On();

    // Stop watchdog. Prevents destroying the circle when the group
    // comes back after a node was lost.
    call WatchDogTimer.stop();

    #if IS_SINK_NODE && defined IS_PART_OF_CIRCLE
      // root node prints its own RSSI array
      recvdMsgSenderID = TOS_NODE_ID;
      recvdMsg = *outgoingMsg;
      recvdChannel = *channel;
      post printCollectedData();
    #endif

    DPRINTF(("Sending on channel %u...\n", *channel));
    result = call AMSend.send(AM_BROADCAST_ADDR, &packet, sizeof(msg_rssi_t));
    if (result != SUCCESS) {
      if (result == FAIL) {
        rf_failure_counter = rf_failure_counter + 100;
      }
      DPRINTF(("Radio did not accept message. Code: %u.\n", result));
      radio_failure(400);
      // not resending, accept failure of cycle to avoid other problems
    } else {
      DPRINTF(("Sent!\n"));
    }
  }


  /**
   * Broadcast sent
   */
  event void AMSend.sendDone(message_t* msg, error_t result) {
    if (result != SUCCESS) {
      radio_failure(2200);
      DPRINTF(("Error sending data. Code: %u.\n", result));
    } else {
      reset_radio_failure();
    }
    if(TOS_NODE_ID == NODE_COUNT) {
      // last node switches right after sending
      DPRINTF(("Switching channel...\n"));
      switch_channel();
    }
    // reset RSSI values
    memcpy(outgoingMsg->rssi, rssi_template, NODE_COUNT + 1);
    call Leds.led2Off();
  }



  /* * Message recieving * * * * * * * * * * * * * * * * * * * * * */

  /**
   * Event fires on new message recieved.
   */
  event message_t* Receive.receive(message_t* msg, void* payload, uint8_t len) {
    #if IS_SINK_NODE
      msg_rssi_t* pl;
    #else
      uint8_t distanceToLast;
    #endif

    int8_t rssi;

    if (halted) {
      return msg;
    }

    rssi = call CC2420Packet.getRssi(msg);
    lastSeenNodeID = call AMPacket.source(msg);
    DPRINTF(("Received message from %u with RSSI %d.\n", lastSeenNodeID, rssi));

    #if ! IS_SINK_NODE
      // reset watchdog
      distanceToLast = (
        TOS_NODE_ID - lastSeenNodeID + NODE_COUNT - 1) % NODE_COUNT;
      call WatchDogTimer.startOneShot(
        distanceToLast * WATCHDOG_TOLERANCE_PER_NODE + WATCHDOG_TOLERANCE);

      DPRINTF(("Distance: %u\n", distanceToLast));
      DPRINTF(("Watchdog timer: %u\n",
        distanceToLast * WATCHDOG_TOLERANCE_PER_NODE + WATCHDOG_TOLERANCE));

    #endif
    /* Save Rssi values to outgoing rssi msg */
    outgoingMsg->rssi[lastSeenNodeID-1] = rssi;

    // sink node prints RSSI
    #if IS_SINK_NODE
      recvdMsgSenderID = lastSeenNodeID;
      pl = (msg_rssi_t*) payload;
      recvdMsg = *pl;
      recvdChannel = *channel;
      post printCollectedData();
    #endif
    #if ! IS_SINK_NODE || ( IS_SINK_NODE && IS_PART_OF_CIRCLE)
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
  static inline void switch_channel() {
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
      radio_failure(100);
      // Stay here and wait on error...
      return;
    }

    DPRINTF(("Switched channel to '%u'\n", *channel));

    // start watchdog on last node to make sure it's node waiting there forever
    if (TOS_NODE_ID == NODE_COUNT) {
      call WatchDogTimer.startOneShot(
        // dividing by two to speed up the time till channel switching
        // continues. This is possible because it is very unlikely all
        // messages of prevoius nodes get lost.
        NODE_COUNT / 2 * WATCHDOG_TOLERANCE_PER_NODE + WATCHDOG_TOLERANCE);
    }

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

  event void ErrorIndicatorResetTimer.fired() {
    call Leds.led0Off();
    call Leds.led1On();
  }


  /* * Sink node only: serial writing  * * * * * * * * * * * * * * * */
  #if IS_SINK_NODE


  /**
   * Sends sync bytes
   */

  static inline void uart_sync() {
    call UartByte.send(0xFE);
    call UartByte.send(0xFF);
  }

  /**
   * Sends collected data to the serial.
   */
  task void printCollectedData() {
    int8_t i;
    uint8_t node_count = NODE_COUNT;

    #if DEBUG
      DPRINTF(("Reporting home...\n"));
      DPRINTF(("NODE_COUNT %u\n", NODE_COUNT));
      DPRINTF(("NodeID %u\n", recvdMsgSenderID));
      DPRINTF(("LastSeenNodeID %u\n", lastSeenNodeID));

      DPRINTF(("RSSI["));
      for (i = 0; i < NODE_COUNT; ++i) {
        DPRINTF(("%i ", recvdMsg.rssi[i]));
      }
      DPRINTF(("]RSSI_END\n"));

    #else

    // data length
    call UartByte.send(node_count + 3);
    // NODE_COUNT + ID + channel
    // these vars are actually uint16_t but
    // they will never grow bigger than uint8_t
    call UartByte.send(node_count);
    call UartByte.send(recvdMsgSenderID);
    call UartByte.send(recvdChannel);

    // RSSI
    for (i = 0; i < NODE_COUNT; ++i) {
      call UartByte.send(recvdMsg.rssi[i]);
    }

    // send sync bytes
    uart_sync();

    #endif /* DEBUG else */

  }

  #endif /* IS_SINK_NODE */

}
