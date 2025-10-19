 // 30 seconds branch
//#define TEST_IMAGE

// Firmware version - update this when you create new OTA files
const char* FIRMWARE_VERSION = "1.2.0";

// GPIO pin definitions
#define CALIBRATION_BUTTON_PIN 27  // GPIO 27 for threshold calibration

#include <SPI.h>
#include <ArduinoBLE.h>
#include <FS.h>
#include <SPIFFS.h>
#include "esp_sleep.h"  // For deep sleep timer wake
#include "SPICom.h"
#include "W21.h"
#include "image.h"
#include "BLE.h"
void handleLedBlinking();
// Print touch reading every 500ms
static unsigned long lastTouchPrint = 0;

// Shared battery percent helper (ADC pin 1.60V ->0%, 2.00V ->100%)
uint8_t getBatteryPercent() {
  analogReadResolution(12);
  int raw = analogRead(BATTERY_PIN);
  float vAdc = (raw / 4095.0f) * 3.3f; // ADC pin voltage
  const float VADC_EMPTY = 1.60f;
  const float VADC_FULL  = 2.00f;
  float percent = (vAdc - VADC_EMPTY) * 100.0f / (VADC_FULL - VADC_EMPTY);
  return (uint8_t)(percent + 0.5f);
}

// Single function to read and print battery status at startup
static void printBatteryStatus() {
  uint8_t percent = getBatteryPercent();
  Serial.printf("Battery: %u%%\n", percent);
}

// Simple threshold save/load
void saveThreshold(int value) {
  File file = SPIFFS.open("/thresh.txt", "w");
  if (file) {
    file.println(value);
    file.close();
  }
}

int loadThreshold() {
  File file = SPIFFS.open("/thresh.txt", "r");
  if (file) {
    int value = file.parseInt();
    file.close();
    return (value > 0) ? value : 70;
  }
  return 70;
}

// Forward declarations from W21.cpp
extern unsigned char Color_get(unsigned char color);

// Flag to use BLE received image
bool useBleImage = false;

// Simple threshold management
int touchThreshold = 70;  // Default threshold

// Variables for LED blinking
unsigned long previousMillis = 0;
const long blinkInterval = 1000;  // Blink every 1 second
const long blinkDuration = 50;    // LED on for 50ms

// Variables for idle timeout (sleep after 30s unless actively receiving image)
unsigned long connectionStartTime = 0;
const long connectionTimeout = 30000;  // 30 seconds timeout for inactivity
bool bleConnected = false;

// Periodic refresh interval: 5 days in microseconds
static const uint64_t REFRESH_INTERVAL_US = 5ULL * 24ULL * 60ULL * 60ULL * 1000000ULL;


void setup() {

  
  // If woken by 5-minute RTC timer, quickly refresh image and return to deep sleep.
  esp_sleep_wakeup_cause_t wakeCause = esp_sleep_get_wakeup_cause();
  if (wakeCause == ESP_SLEEP_WAKEUP_TIMER) {
    Serial.println("Wake cause: RTC timer. Refreshing image from SPIFFS...");
    // Ensure board GPIOs are configured (power rails, indicator LED)
    if (!spiffsReady) {
      spiffsReady = SPIFFS.begin(true);
      if (!spiffsReady) {
        Serial.println("SPIFFS mount failed during timer wake.");
      }
    }
    // Ensure EPD pins and SPI are initialized before driving the display
    pinMode(PIN_EPD_BUSY, INPUT);  // BUSY (panel drives this)
    pinMode(PIN_EPD_RST, OUTPUT);  // RES
    pinMode(PIN_EPD_DC, OUTPUT);   // DC  
    pinMode(PIN_EPD_CS, OUTPUT);   // CS  
    digitalWrite(PIN_EPD_CS, HIGH); // deselect
    digitalWrite(PIN_EPD_DC, HIGH);
    digitalWrite(PIN_EPD_RST, HIGH);
    
#if defined(ARDUINO_XIAO_ESP32C3)
    SPI.begin(EPD_SPI_SCK, EPD_SPI_MISO, EPD_SPI_MOSI, PIN_EPD_CS);
#else
    SPI.begin();
#endif
    SPI.beginTransaction(SPISettings(8000000, MSBFIRST, SPI_MODE0));

    // Display from SPIFFS if available, then sleep again
    displayImageFromSPIFFS();
    Serial.println("Refresh complete. Going back to deep sleep for next cycle...");
    // Keep both timer and touch as wake sources
    touchSleepWakeUpEnable(TOUCH_PIN, touchThreshold);
    esp_sleep_enable_timer_wakeup(REFRESH_INTERVAL_US);
    Serial.flush();
    esp_deep_sleep_start();
  }

  pinMode(GND, OUTPUT); // Will be ignored if GPIO35 is input-only
  pinMode(LED2, OUTPUT); // Will be ignored if GPIO34 is input-only
  digitalWrite(GND, LOW);
  digitalWrite(LED2, HIGH);
  Serial.begin(115200);
  delay(1000);
 // while (!Serial && millis() < 5000); // Wait for serial or timeout

  Serial.printf("Going to deep sleep... touch GPIO%d to wake up\n", TOUCH_PIN);
  touchSleepWakeUpEnable(TOUCH_PIN, touchThreshold);

  Serial.println("E-Paper Display + BLE Example");
  #if (LED2 == 34)
    Serial.println("[Warning] LED2 assigned to GPIO34 (input-only on standard ESP32) - blinking will not function.");
  #endif
  Serial.println("==============================");
  // Print battery status once at startup
  printBatteryStatus();
  
  // Initialize SPIFFS (format on fail)
  spiffsReady = SPIFFS.begin(true);
  if(!spiffsReady) {
    Serial.println("SPIFFS mount failed!");
  } else {
    Serial.println("SPIFFS mounted successfully.");
    touchThreshold = loadThreshold();
    Serial.printf("Touch threshold: %d\n", touchThreshold);
  }
  
  // Setup calibration button for threshold calibration
  pinMode(CALIBRATION_BUTTON_PIN, INPUT_PULLUP);
  Serial.printf("GPIO %d configured as INPUT_PULLUP for threshold calibration\n", CALIBRATION_BUTTON_PIN);
  Serial.printf("Connect GPIO %d to GND to calibrate threshold\n", CALIBRATION_BUTTON_PIN);
   
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

  // Simple calibration button check for threshold calibration
  static bool lastButtonState = HIGH;
  static unsigned long lastDebugPrint = 0;
  bool buttonState = digitalRead(CALIBRATION_BUTTON_PIN);
  
  // Debug: Print calibration button state every 2 seconds
  if (millis() - lastDebugPrint > 2000) {
    lastDebugPrint = millis();
    Serial.printf("GPIO%d state: %d\n", CALIBRATION_BUTTON_PIN, buttonState);
  }
  
  if (lastButtonState == HIGH && buttonState == LOW) {
    Serial.printf("GPIO%d pressed! Calibrating...\n", CALIBRATION_BUTTON_PIN);
    // Button pressed - calibrate threshold
    uint16_t currentTouch = touchRead(TOUCH_PIN);
    touchThreshold = currentTouch - 2;
    if (touchThreshold < 10) touchThreshold = 10;
    saveThreshold(touchThreshold);
    Serial.printf("Threshold calibrated to: %d (was reading: %u)\n", touchThreshold, currentTouch);
    // Flash LED 3 times
    for(int i=0; i<3; i++) {
      digitalWrite(LED2, HIGH); delay(100);
      digitalWrite(LED2, LOW); delay(100);
    }
  }
  lastButtonState = buttonState;

  // Periodically print capacitive touch reading for TOUCH_PIN
  if (millis() - lastTouchPrint >= 500) {
    lastTouchPrint = millis();
    uint16_t touchVal = touchRead(TOUCH_PIN);
    uint8_t battInline = getBatteryPercent();
    Serial.print("Touch(");
    Serial.print(TOUCH_PIN);
    Serial.print(") = ");
    Serial.print(touchVal);
    Serial.print("  Battery=");
    Serial.print(battInline);
    Serial.println("%");
    // BLE transmission of touch messages removed to avoid interfering with app status
  }
  
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
  // Ensure the e-paper display is commanded to sleep. Use non-blocking variant
  // so that the ESP32 will still go to sleep even if the display is not present
  // or its BUSY pin is floating.
  EPD_sleep_no_wait();
  
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
  
  Serial.printf("Entering deep sleep mode. Touch GPIO%d to wake up again.\n", TOUCH_PIN);
  Serial.flush();

  // CLEANUP: remove any stored image or OTA file so the device wakes up in a clean state.
  // Only do this when not in the middle of a transfer.
  if (spiffsReady && receivingSize) {
    // Remove image file if present
    if (SPIFFS.exists(IMAGE_PATH)) {
      Serial.println("Removing stored image from SPIFFS before sleep...");
      SPIFFS.remove(IMAGE_PATH);
      Serial.println("Image removed.");

    }
    // Remove OTA file if present
    if (SPIFFS.exists(OTA_PATH)) {
      Serial.println("Removing stored OTA file from SPIFFS before sleep...");
      SPIFFS.remove(OTA_PATH);
      Serial.println("OTA file removed.");
    }
  } else if (!spiffsReady) {
    Serial.println("SPIFFS not mounted; skipping cleanup before sleep.");
  } else {
    Serial.println("Transfer in progress; skipping SPIFFS cleanup before sleep.");
  }
  
  // Configure touchpad as wakeup source
  // Use touch channel T9 which maps to GPIO32 on classic ESP32
  touchSleepWakeUpEnable(TOUCH_PIN, touchThreshold);
  // Also configure periodic 5-day RTC timer wake for image refresh
  esp_sleep_enable_timer_wakeup(REFRESH_INTERVAL_US);
  
  // Go to deep sleep
  esp_deep_sleep_start();
}


/**
 * Handle the blinking of LED2 (50ms on, every second)
 * If touch value is below threshold, keep LED ON continuously
 * Otherwise, continue normal blinking behavior
 */
void handleLedBlinking() {
  unsigned long currentMillis = millis();
  uint16_t touchVal = touchRead(TOUCH_PIN);
  
  // If touch value is less than threshold, keep LED ON continuously
  if (touchVal < touchThreshold) {
    digitalWrite(LED2, HIGH);
    return; // Exit early, no blinking needed
  }
  
  // Otherwise, continue normal blinking behavior
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