COMPONENT=RadioSenseAppC
TINYOS_ROOT_DIR?=/usr/local/src/tinyos

include $(TINYOS_ROOT_DIR)/Makefile.include

CFLAGS += -I$(TINYOS_OS_DIR)/lib/printf
CFLAGS += -DNEW_PRINTF_SEMANTICS

# IEEE802.15.4: the channel is between 11-26, TinyOS default is 26
CHANNEL?=26
CFLAGS+=-DCC2420_DEF_CHANNEL=$(CHANNEL)

# Transmit power between 1-31, TinyOS default is 31
POWER?=31
CFLAGS+=-DCC2420_DEF_RFPOWER=$(POWER)

# Number of nodes in the setup
NODE_COUNT?=10
CFLAGS+=-DNODE_COUNT=$(NODE_COUNT)
