# minimize-requests plugin — see src/main.cpp for what and why.

CXX ?= g++
CXXFLAGS = -fPIC -g -O2 -std=c++23 -MMD -MP
LDFLAGS = -shared
INCLUDES = $(shell pkg-config --cflags hyprland pixman-1 libdrm)
LIBS = $(shell pkg-config --libs hyprland)

ifeq ($(basename $(CXX)),g++)
	CXXFLAGS += --no-gnu-unique
endif

TARGET = minimize-requests.so
SOURCES = src/main.cpp
OBJ = $(SOURCES:.cpp=.o)
DEPS = $(OBJ:.o=.d)

all: $(TARGET)

%.o : %.cpp
	@echo "[$(CXX)] $<"
	@$(CXX) -c $(CXXFLAGS) $(INCLUDES) $< -o $@

$(TARGET): $(OBJ)
	@$(CXX) $(LDFLAGS) $(OBJ) -o $@.tmp $(LIBS)
	@mv -f $@.tmp $@

clean:
	rm -f $(OBJ) $(DEPS) $(TARGET) $(TARGET).tmp

-include $(DEPS)

.PHONY: all clean
