#ifndef _SPICOM_H_
#define _SPICOM_H_
#include "Arduino.h"

// IO settings (focused on XIAO ESP32C3)
// Original sketch used A14..A17 (not present on XIAO boards). We now define explicit GPIOs.
// Pinout Definitions (as requested):
// ePaper  -> XIAO ESP32C3
// RST     -> D0 (GPIO2)
// CS      -> D1 (GPIO3)
// DC      -> D3 (GPIO5)
// BUSY    -> D2 (GPIO4)
// SCK     -> D8 (GPIO10)
// MOSI    -> D10 (GPIO0)
// 3V3     -> 3V3
// GND     -> GND
// (MISO not used by most ePaper panels)
// If you need a different wiring, define PIN_EPD_* / EPD_SPI_* before including this header.
// Power:
//   VCC  -> 3V3 (DO NOT use 5V if panel is 3.3V logic)
//   GND  -> GND
//   If panel needs a separate ENABLE pin, tie according to its datasheet.

// Board selection preprocessor directives
// Uncomment ONE of these defines to select your board
//#define BOARD_ESP32E  // ESP32E board (default) FireBeatle
//#define BOARD_FRAME   // Frame board
//#define BOARD_C3      // C3 board XIAO
#define BOARD_ESP32E // LOLIN LITE board (uncomment to use)
//#define BOARD_FIRSTPCB // FirstPCB custom board

#if defined(BOARD_FRAME)
    // Frame board pin definitions
    #define PIN_EPD_RST   4   // D0
    #define PIN_EPD_CS    2   // D1
    #define PIN_EPD_BUSY  5   // D2
    #define PIN_EPD_DC    3   // D3
    #define EPD_SPI_SCK   12  // D8 (SCK)
    #define EPD_SPI_MOSI  11  // D10 (MOSI)
    #define EPD_SPI_MISO  -1  // not used
#elif defined(BOARD_C3)
    // C3 board pin definitions
    #define PIN_EPD_RST   D0  // D0
    #define PIN_EPD_CS    D1  // D1
    #define PIN_EPD_BUSY  D2  // D2
    #define PIN_EPD_DC    D3  // D3
    #define EPD_SPI_SCK   D8  // D8 (SCK)
    #define EPD_SPI_MOSI  D10 // D10 (MOSI)
    #define EPD_SPI_MISO  -1  // not used
#elif defined(BOARD_LOLIN_LITE)
    // LOLIN LITE board pin definitions (user supplied)
    #define PIN_EPD_RST   16   // D0
    #define PIN_EPD_CS    5    // D1
    #define PIN_EPD_BUSY  4    // D2
    #define PIN_EPD_DC    17   // D3
    #define EPD_SPI_SCK   18   // D8 (SCK)
    #define EPD_SPI_MOSI  23   // D10 (MOSI)
    #define EPD_SPI_MISO  -1   // not used
    const int BATTERY_PIN = 33; // ADC1 channel; 2:1 divider (two 1MΩ resistors)
    const int GND = 27;   // GPIO35 (requested) NOTE: GPIO35 is input-only on classic ESP32
    const int LED2 = 26;  // GPIO34 (requested) NOTE: GPIO34 is input-only; LED drive will not work on classic ESP32
    const int TOUCH_PIN = 32;   // GPIO32 for touch (was 15)
#elif defined(BOARD_FIRSTPCB)
    // FirstPCB custom board pin definitions
    #define PIN_EPD_RST   21   // RES
    #define PIN_EPD_CS    2    // CS
    #define PIN_EPD_BUSY  22   // BUSY
    #define PIN_EPD_DC    15   // C/D
    #define EPD_SPI_SCK   18   // CLK (SCK)
    #define EPD_SPI_MOSI  23   // SDI (MOSI)
    #define EPD_SPI_MISO  -1   // not used.
    //Changed for FirstPCB board
    const int BATTERY_PIN = 34; // ADC1 channel; 2:1 divider (two 1MΩ resistors)
    const int GND = 12;   
    const int LED2 = 4;   
    const int TOUCH_PIN = 27;   // GPIO32 for touch (was 15)
#else // BOARD_ESP32E (default)
    #define PIN_EPD_RST   2   // D0
    #define PIN_EPD_CS    22  // D1
    #define PIN_EPD_BUSY  13  // D2
    #define PIN_EPD_DC    21  // D3
    #define EPD_SPI_SCK   18  // D8 (SCK)
    #define EPD_SPI_MOSI  23  // D10 (MOSI)
    #define EPD_SPI_MISO  -1  // not used
    const int BATTERY_PIN = 34; // ADC1 channel; 2:1 divider (two 1MΩ resistors)
    const int GND = 12;   // GPIO12
    const int LED2 = 4;   // GPIO13
    const int TOUCH_PIN = 15;   // GPIO32 for touch (was 15)
#endif




#define isEPD_W21_BUSY digitalRead(PIN_EPD_BUSY)
#define EPD_W21_RST_0 digitalWrite(PIN_EPD_RST,LOW)
#define EPD_W21_RST_1 digitalWrite(PIN_EPD_RST,HIGH)
#define EPD_W21_DC_0  digitalWrite(PIN_EPD_DC,LOW)
#define EPD_W21_DC_1  digitalWrite(PIN_EPD_DC,HIGH)
#define EPD_W21_CS_0  digitalWrite(PIN_EPD_CS,LOW)
#define EPD_W21_CS_1  digitalWrite(PIN_EPD_CS,HIGH)


void SPI_Write(unsigned char value);
void EPD_W21_WriteDATA(unsigned char datas);
void EPD_W21_WriteCMD(unsigned char command);


#endif
