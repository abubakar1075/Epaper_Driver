 // 30 seconds branch
 //#define TEST_IMAGE
#include <SPI.h>
#include <ArduinoBLE.h>
#include <FS.h>
#include <SPIFFS.h>
#include "SPICom.h"
#include "W21.h"
#include "image.h"
#include "BLE.h"
void handleLedBlinking();

// Single function to read and print battery status at startup
static void printBatteryStatus() {
  const int BATTERY_PIN = 34; // ADC1 channel; assumes 2:1 divider from battery to ADC
  analogReadResolution(12);   // 12-bit ADC (0–4095)
  int raw = analogRead(BATTERY_PIN);
  float voltage = (raw / 4095.0f) * 3.3f * 2.0f; // Adjust multiplier if your divider is different
  float percent = -100.0f * voltage * voltage + 840.0f * voltage - 1680.0f; // 3.2V=0%, 3.7V=50%, 4.2V=100%
  if (percent < 0) percent = 0; if (percent > 100) percent = 100;
  Serial.printf("Battery Voltage: %.2f V | Charge: %.0f%%\n", voltage, percent);
}

// Forward declarations from W21.cpp
extern unsigned char Color_get(unsigned char color);

// Flag to use BLE received image
bool useBleImage = false;

const int GND = 12;   // GPIO12
const int LED2 = 4;   // GPIO13
const int TOUCH_PIN = 15;   // GPIO15 for touch
const int TOUCH_THRESHOLD = 69;

// Variables for LED blinking
unsigned long previousMillis = 0;
const long blinkInterval = 1000;  // Blink every 1 second
const long blinkDuration = 50;    // LED on for 50ms

// Variables for idle timeout (sleep after 30s unless actively receiving image)
unsigned long connectionStartTime = 0;
const long connectionTimeout = 30000;  // 30 seconds timeout for inactivity
bool bleConnected = false;


void setup() {
  pinMode(GND, OUTPUT);
  pinMode(LED2, OUTPUT);
  digitalWrite(GND, LOW);   // GPIO12 = 0
  digitalWrite(LED2, HIGH);  // LED off initially
  Serial.begin(115200);
  delay(1000);
 // while (!Serial && millis() < 5000); // Wait for serial or timeout
  
  Serial.println("Going to deep sleep... touch GPIO15 to wake up");
  touchSleepWakeUpEnable(T3, TOUCH_THRESHOLD);

  Serial.println("E-Paper Display + BLE Example");
  Serial.println("==============================");
  // Print battery status once at startup
  printBatteryStatus();
  
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
  
  #ifdef TEST_IMAGE
     /************Full display*******************/
    EPD_init_fast(); //Full screen refresh initialization.
    PIC_display(gImage_1);//To Display one image using full screen refresh.
    EPD_sleep();//Enter the sleep mode and please do not delete it, otherwise it will reduce the lifespan of the screen.
    delay(5000); //Delay for 5s.
  #endif
  
  // Start BLE services
  startBLE();
  bleActive = true;
  
  // Start connection timeout
  connectionStartTime = millis();
  
  Serial.println("Setup complete. Waiting for BLE connection...");
  Serial.println("Device will go to sleep if no connection in 30 seconds");
}

void loop() {
  // Handle LED2 blinking
  handleLedBlinking();
  
  // Check for BLE connection status
  if (BLE.connected() && !bleConnected) {
    bleConnected = true;
    Serial.println("BLE device connected!");
  } else if (!BLE.connected() && bleConnected) {
    bleConnected = false;
    Serial.println("BLE device disconnected!");
  }
  
  // Hold/reset the 30s idle timer while image data is actively being received
  // receivingSize == false means we're currently in the image payload phase
  if (!receivingSize) {
    connectionStartTime = millis();
  }

  // Sleep after 30s of idle (no active image transfer), regardless of BLE connection state
  if ((millis() - connectionStartTime > connectionTimeout) && receivingSize && !dataReceived) {
    Serial.println("Idle for 30 seconds without image activity. Going to sleep...");
    goToSleep();
  }
  
  // Poll BLE for events
  BLE.poll();
  
  // If we have new data received via BLE, display it
  if (dataReceived) {
    Serial.println("New data received via BLE. Turning off BLE to save power, then displaying...");

    // Turn off BLE before driving the e-paper to save battery
    if (bleActive) {
      BLE.end();
      bleActive = false;
      Serial.println("BLE turned off.");
    }

    // Now display the image from SPIFFS
    displayImageFromSPIFFS();
    dataReceived = false; // Reset flag
    Serial.println("Going to sleep...");
    delay(1000);
    goToSleep();
  }
  
  // Small delay to avoid hogging CPU
  delay(10);
}

/**
 * Put the device into deep sleep mode
 */
void goToSleep() {
  // Ensure the e-paper display is in sleep mode
  EPD_sleep();
  
  // Shut down BLE to save power
  if (bleActive) {
    BLE.end();
    bleActive = false;
  }
  
  // Flash LED2 to indicate going to sleep
  for (int i = 0; i < 5; i++) {
    digitalWrite(LED2, HIGH);
    delay(100);
    digitalWrite(LED2, LOW);
    delay(100);
  }
  
  Serial.println("Entering deep sleep mode. Touch GPIO15 to wake up again.");
  Serial.flush();
  
  // Configure touchpad as wakeup source
  touchSleepWakeUpEnable(T3, TOUCH_THRESHOLD);
  
  // Go to deep sleep
  esp_deep_sleep_start();
}


/**
 * Handle the blinking of LED2 (50ms on, every second)
 */
void handleLedBlinking() {
  unsigned long currentMillis = millis();
  
  // Check if it's time to turn the LED on
  if (currentMillis - previousMillis >= blinkInterval) {
    // Save the time when we started the blink cycle
    previousMillis = currentMillis;
    
    // Turn LED on for blinkDuration
    digitalWrite(LED2, HIGH);
  } 
  // Check if it's time to turn the LED off
  else if (currentMillis - previousMillis >= blinkDuration && 
           currentMillis - previousMillis < blinkInterval) {
    digitalWrite(LED2, LOW);
  }
}