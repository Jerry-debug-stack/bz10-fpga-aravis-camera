CC ?= cc
CFLAGS ?= -O3 -std=c11 -Wall -Wextra -Werror
ARAVIS_CFLAGS ?= $(shell pkg-config --cflags aravis-0.8)
ARAVIS_LIBS ?= $(shell pkg-config --libs aravis-0.8)

.PHONY: all test clean
all: bz10_gige_wrapper bz10_control_agent

bz10_gige_wrapper: bz10_gige_wrapper.c frame_core.c frame_core.h
	$(CC) $(CFLAGS) $(ARAVIS_CFLAGS) -o $@ bz10_gige_wrapper.c frame_core.c $(ARAVIS_LIBS) -lm -pthread

bz10_control_agent: bz10_control_agent.c
	$(CC) $(CFLAGS) -o $@ bz10_control_agent.c

test_frame_core: test_frame_core.c frame_core.c frame_core.h
	$(CC) $(CFLAGS) -D_POSIX_C_SOURCE=200809L -o $@ test_frame_core.c frame_core.c -lm

test: test_frame_core
	./test_frame_core

clean:
	rm -f bz10_gige_wrapper bz10_control_agent test_frame_core
