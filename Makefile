 COMPONENT = RadioSenseAppC

TINYOS_ROOT_DIR ?= /usr/local/src/tinyos
include $(TINYOS_ROOT_DIR)/Makefile.include

CFLAGS += -I$(TINYOS_OS_DIR)/lib/printf
CFLAGS += -DNEW_PRINTF_SEMANTICS

TOSH_DATA_LENGTH ?= 100
CFLAGS += -DTOSH_DATA_LENGTH=$(TOSH_DATA_LENGTH)

# Debug mode requested?
DEBUG ?= 0
CFLAGS += -DDEBUG=$(DEBUG)

# IEEE802.15.4: the channel is between 11-26, TinyOS default is 26
CHANNEL ?= 26
CFLAGS += -DCC2420_DEF_CHANNEL=$(CHANNEL)

# Transmit power between 1-31, TinyOS default is 31
POWER ?= 31
CFLAGS += -DCC2420_DEF_RFPOWER=$(POWER)

# Number of nodes in the setup
NODE_COUNT ?= 10
CFLAGS += -DNODE_COUNT=$(NODE_COUNT)

# Set the root node ID
ROOT_NODE_ADDR ?= 1

CFLAGS += -DROOT_NODE_ADDR=$(ROOT_NODE_ADDR)

NODEID ?= 1   # is only set on make telosb install.NODEID
ifeq ($(NODEID),$(ROOT_NODE_ADDR))
    CFLAGS += -DIS_ROOT_NODE=1
    TOSMAKE_BUILD_DIR=build_root/$(TARGET)
else
    CFLAGS += -DIS_ROOT_NODE=0
endif
