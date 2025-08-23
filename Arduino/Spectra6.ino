#include <SPI.h>
#include <ArduinoBLE.h>
#include <FS.h>
#include <SPIFFS.h>
#include "SPICom.h"
#include "W21.h"
#include "image.h"
#include "BLE.h"

// Forward declarations from W21.cpp
extern unsigned char Color_get(unsigned char color);

// Flag to use BLE received image
bool useBleImage = false;

void setup() {
  Serial.begin(115200);
  while (!Serial && millis() < 5000); // Wait for serial or timeout
  
  Serial.println("\n\nE-Paper Display + BLE Example");
  Serial.println("==============================");
  
  // Initialize SPIFFS (format on fail)
  spiffsReady = SPIFFS.begin(true);
  if(!spiffsReady) {
    Serial.println("SPIFFS mount failed!");
  } else {
    Serial.println("SPIFFS mounted successfully.");
  }
   
  // Initialize EPD pins - but don't run any display commands yet
  pinMode(PIN_EPD_BUSY, INPUT);  // BUSY (panel drives this)
  pinMode(PIN_EPD_RST, OUTPUT);  // RES
  pinMode(PIN_EPD_DC, OUTPUT);   // DC  
  pinMode(PIN_EPD_CS, OUTPUT);   // CS  
  digitalWrite(PIN_EPD_CS, HIGH); // deselect
  digitalWrite(PIN_EPD_DC, HIGH);
  digitalWrite(PIN_EPD_RST, HIGH);
   
  // SPI init (explicit pins for ESP32C3)
#if defined(ARDUINO_XIAO_ESP32C3)
  // Order: SCK, MISO, MOSI, SS
  SPI.begin(EPD_SPI_SCK, EPD_SPI_MISO, EPD_SPI_MOSI, PIN_EPD_CS);
  Serial.println("ESP32C3 detected - using explicit SPI pin configuration");
#else
  SPI.begin();
  Serial.println("Using default SPI pin configuration");
#endif
  SPI.beginTransaction(SPISettings(8000000, MSBFIRST, SPI_MODE0)); // 8MHz safer for large ePaper
  
  // Start BLE services
  startBLE();
  bleActive = true;
  
  Serial.println("Setup complete. Waiting for BLE connection...");
}

void loop() {
  // Poll BLE for events
  BLE.poll();
  
  // If we have new data received via BLE, display it
  if (dataReceived) {
    Serial.println("New data received via BLE. Displaying...");
    displayImageFromSPIFFS();
    dataReceived = false; // Reset flag
  }
  
  // Small delay to avoid hogging CPU
  delay(10);
}
