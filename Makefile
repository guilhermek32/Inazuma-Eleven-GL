CXX := g++
CC := gcc

TARGET := InazumaElevenGL
OBJ_DIR := obj

CXXFLAGS := -std=c++17 -Iinclude -MMD -MP
CFLAGS := -Iinclude -MMD -MP
LDFLAGS := -lglfw -lGL -ldl -pthread -lm

CPP_SOURCES := \
	src/main.cpp \
	src/game.cpp \
	src/game_logic.cpp \
	src/input.cpp \
	src/audio.cpp \
	src/player.cpp \
	src/ball.cpp \
	src/particle.cpp \
	src/field.cpp \
	src/stadium.cpp \
	src/stb_image_impl.cpp \
	src/utils.cpp

C_SOURCES := src/glad.c

CPP_OBJECTS := $(patsubst src/%.cpp,$(OBJ_DIR)/%.o,$(CPP_SOURCES))
C_OBJECTS := $(patsubst src/%.c,$(OBJ_DIR)/%.o,$(C_SOURCES))
OBJECTS := $(CPP_OBJECTS) $(C_OBJECTS)
DEPS := $(OBJECTS:.o=.d)

.PHONY: all clean

all: $(TARGET)

$(TARGET): $(OBJECTS)
	$(CXX) $(OBJECTS) $(LDFLAGS) -o $(TARGET)

$(OBJ_DIR):
	mkdir -p $(OBJ_DIR)

$(OBJ_DIR)/%.o: src/%.cpp | $(OBJ_DIR)
	$(CXX) $(CXXFLAGS) -c $< -o $@

$(OBJ_DIR)/%.o: src/%.c | $(OBJ_DIR)
	$(CC) $(CFLAGS) -c $< -o $@

clean:
	rm -rf $(OBJ_DIR) $(TARGET)

-include $(DEPS)
