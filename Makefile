COMPONENT = RadioSenseAppC

TINYOS_ROOT_DIR ?= /usr/local/src/tinyos
include $(TINYOS_ROOT_DIR)/Makefile.include

CFLAGS += -I$(TINYOS_OS_DIR)/lib/printf
CFLAGS += -DNEW_PRINTF_SEMANTICS

# reset component from 
# https://github.com/tp-freeforall/prod/tree/163cc239d0da65040398b804cb7b381489e85e59/tos/chips/msp430
CFLAGS += -I./swreset

TOSH_DATA_LENGTH ?= 100
CFLAGS += -DTOSH_DATA_LENGTH=$(TOSH_DATA_LENGTH)

# Debug mode requested?
DEBUG ?= 0
CFLAGS += -DDEBUG=$(DEBUG)

# IEEE802.15.4: the channel is between 11-26, TinyOS default is 26
# Starting channel when channel switching is enabled.
CHANNEL ?= 24
CFLAGS += -DCC2420_DEF_CHANNEL=$(CHANNEL)

# Transmit power between 1-31, TinyOS default is 31
# Reducing power to 27. Manufacturer recommends it according to Matteo.
# Update: Reducing power massively increases package drops.
POWER ?= 31
CFLAGS += -DCC2420_DEF_RFPOWER=$(POWER)

# Number of nodes in the setup
NODE_COUNT ?= 10
CFLAGS += -DNODE_COUNT=$(NODE_COUNT)

# List of channels to switch between
# format: comma separated list (c array declaration without {})
CHANNEL_LIST ?= $(CHANNEL)
CFLAGS += -DCHANNEL_LIST=$(CHANNEL_LIST)

# Set the root node ID
ROOT_NODE_ADDR ?= 1

# Set the sink node ID
# defaults to ROOT_NODE
SINK_NODE_ADDR ?= ROOT_NODE_ADDR


# NODEID is only set on `make telosb install.NODEID`
# Add NODEID=1 as argument to your make call to test the successfull
#   compilation of the root/sink node's code without installing it.
ifeq ($(NODEID),$(SINK_NODE_ADDR))
    CFLAGS += -DIS_SINK_NODE=1
    TOSMAKE_BUILD_DIR=build_sink/$(TARGET)
    ifeq ($(shell test $(SINK_NODE_ADDR) -ge $(ROOT_NODE_ADDR); echo $$?),0)
        CFLAGS += -DIS_PART_OF_CIRCLE
    endif
else
    CFLAGS += -DIS_SINK_NODE=0
endif



ifeq ($(NODEID),$(ROOT_NODE_ADDR))
    CFLAGS += -DIS_ROOT_NODE=1
    TOSMAKE_BUILD_DIR=build_root/$(TARGET)
else
    CFLAGS += -DIS_ROOT_NODE=0
endif
