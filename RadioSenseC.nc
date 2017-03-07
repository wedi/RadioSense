#include <Timer.h>
#include "RadioSense.h"
#include "printf.h"

module RadioSenseC {
  uses {
    interface Boot;
    interface SWReset;
    interface Leds;
    interface Timer<TMilli> as ErrorIndicatorResetTimer;


    interface SplitControl as AMControl;
    interface AMPacket;
    interface CC2420Packet;
    interface CC2420Config;
    interface RadioBackoff;
    interface PacketAcknowledgements;
    interface AMSend;
    interface Receive;
    interface Timer<TMilli> as WatchDogTimer;

    #if IS_SINK_NODE
      interface UartByte;
      interface Pool<serial_msg_t> as SerialMessagePool;
      interface Queue<serial_msg_t*> as SerialSendQueue;
    #endif
  }
}

implementation {

/* * Declare tasks & functions * * * * * * * * * * * * * * * * * * * */

  static inline void switch_channel();
  static inline void radio_failure(uint16_t const led_time);
  static inline void reset_radio_failure();
  task void send_broadcast();
  #if IS_SINK_NODE
    static inline void uart_sync();
    static inline void send_serial_message(serial_msg_t* msg);
    static serial_msg_t* serialAllocNewMessage();
    task void send_collected_data();
  #endif



  /* * Global variables  * * * * * * * * * * * * * * * * * * * * * * */

  message_t packet;
  msg_rssi_t* outgoingMsg;
  am_addr_t lastSeenNodeID;
  uint8_t rf_failure_counter;
  const uint8_t* channel = &channels[0];
  bool halted = FALSE;

  #if IS_SINK_NODE
    serial_msg_t* serial_msg;
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
    memcpy(outgoingMsg->rssi, rssi_template, NODE_COUNT + 1);

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

  async event void RadioBackoff.requestCca(message_t *msg){
    call RadioBackoff.setCca(FALSE);
  }

  async event void RadioBackoff.requestCongestionBackoff(message_t *msg){
    call RadioBackoff.setCongestionBackoff(0);
  }

  async event void RadioBackoff.requestInitialBackoff(message_t *msg){
    call RadioBackoff.setInitialBackoff(0);
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
  task void send_broadcast() {
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
      serial_msg = serialAllocNewMessage();
      if (serial_msg == NULL){
        return;
      }
      serial_msg->sender_id = TOS_NODE_ID;
      serial_msg->channel = *channel;
      memcpy(serial_msg->rss, &outgoingMsg->rssi, NODE_COUNT);
      send_serial_message(serial_msg);
    #endif

    DPRINTF(("Sending on channel %u...\n", *channel));
    call PacketAcknowledgements.noAck(&packet);
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
      msg_rssi_t* rcvd_msg;
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
        distanceToLast * SLOT_TIME + WATCHDOG_TOLERANCE);

      DPRINTF(("Distance: %u\n", distanceToLast));
      DPRINTF(("Watchdog timer: %u\n",
        distanceToLast * SLOT_TIME + WATCHDOG_TOLERANCE));

    #endif
    /* Save Rssi values to outgoing rssi msg */
    outgoingMsg->rssi[lastSeenNodeID-1] = rssi;

    // sink node sends RSS values via serial
    #if IS_SINK_NODE
      serial_msg = serialAllocNewMessage();
      if (serial_msg == NULL){
        return msg;
      }
      serial_msg->sender_id = lastSeenNodeID;
      serial_msg->channel = *channel;
      rcvd_msg = (msg_rssi_t*) payload;
      memcpy(serial_msg->rss, &rcvd_msg->rssi, NODE_COUNT);
      send_serial_message(serial_msg);
    #endif
    #if ! IS_SINK_NODE || ( IS_SINK_NODE && IS_PART_OF_CIRCLE)
      // send if it was my predecessor's turn
      if (lastSeenNodeID == TOS_NODE_ID - 1) {
        DPRINTF(("Yeah! It's me now!\n"));
        post send_broadcast();
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
        post send_broadcast();
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
        NODE_COUNT / 2 * SLOT_TIME + WATCHDOG_TOLERANCE);
    }

    #if IS_ROOT_NODE
      // switching before root node sends => it's always its term here.
      post send_broadcast();
    #endif
  }


  /**
   * Fires if waited too long for receiving a message from another node.
   * Fires on startup after WATCHDOG_INIT_TIME is elapsed.
   */
  event void WatchDogTimer.fired() {
    DPRINTF(("Watchdog fired! Last node seen %u\n", lastSeenNodeID));
    post send_broadcast();
  }

  event void ErrorIndicatorResetTimer.fired() {
    call Leds.led0Off();
    call Leds.led1On();
  }


  /* * Sink node only: serial writing  * * * * * * * * * * * * * * * */
  #if IS_SINK_NODE


  /* This function is called after the new message has been created
   *  by the monitoringEvent() and it is ready to be sent over the serial.
   *  It checks if the send quene is not exhausted and posts logSendTask
   */
  static inline void send_serial_message(serial_msg_t* msg) {
    if (call SerialSendQueue.enqueue(msg) == SUCCESS) {
      post send_collected_data();
      return;
    }
    else {
      call SerialMessagePool.put(msg);
      return;
    }
  }

  /*
   * This function allocates a new empty message.
   * It checks if there is memory left in the pool and the queue is not exhausted
   */
  static serial_msg_t* serialAllocNewMessage() {
    if (call SerialMessagePool.empty()) {
      return NULL;
    }
    serial_msg = call SerialMessagePool.get();

    memcpy(serial_msg, &serial_msg_template, sizeof(serial_msg_t));

    return serial_msg;
  }


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
  task void send_collected_data() {
    int8_t i;

    if (call SerialSendQueue.empty())

      return;

    else {
      serial_msg = call SerialSendQueue.head();

      // data length (+ 1 for NODE_COUNT)
      call UartByte.send(sizeof(serial_msg_t) + 1);
      call UartByte.send(NODE_COUNT);
      call UartByte.send(serial_msg->sender_id);
      call UartByte.send(serial_msg->channel);
      // RSSI
      for (i = 0; i < NODE_COUNT; ++i) {
        call UartByte.send(serial_msg->rss[i]);
      }
      // send sync bytes
      uart_sync();

      call SerialSendQueue.dequeue();
      call SerialMessagePool.put(serial_msg);

      post send_collected_data();
    }

    DPRINTF(("Reporting home...\n"));
    DPRINTF(("NODE_COUNT %u\n", NODE_COUNT));
    DPRINTF(("NodeID %u\n", recvdMsgSenderID));
    DPRINTF(("LastSeenNodeID %u\n", lastSeenNodeID));

    DPRINTF(("RSSI["));
    for (i = 0; i < NODE_COUNT; ++i) {
      DPRINTF(("%i ", recvdMsg.rssi[i]));
    }
    DPRINTF(("]RSSI_END\n"));

  }

  #endif /* IS_SINK_NODE */

}
