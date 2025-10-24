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

// ============================
// SPIFFS image slot management
// ============================
static const char* IMAGE1_PATH = "/Image_1";
static const char* IMAGE2_PATH = "/Image_2";
static const char* IMAGE3_PATH = "/Image_3";
static const char* CURRENT_IMAGE_FILE = "/current.txt";

int currentImageIndex = 1; // 1..3

static const char* getImagePathForIndex(int idx) {
  switch (idx) {
    case 1: return IMAGE1_PATH;
    case 2: return IMAGE2_PATH;
    case 3: return IMAGE3_PATH;
    default: return IMAGE1_PATH;
  }
}

const char* getCurrentImagePath() {
  return getImagePathForIndex(currentImageIndex);
}

void saveCurrentImageIndex(int index) {
  if (!spiffsReady) return;
  File f = SPIFFS.open(CURRENT_IMAGE_FILE, FILE_WRITE);
  if (f) {
    f.printf("%d\n", index);
    f.close();
  }
}

int loadCurrentImageIndex() {
  if (!spiffsReady) return 1;
  if (!SPIFFS.exists(CURRENT_IMAGE_FILE)) return 1;
  File f = SPIFFS.open(CURRENT_IMAGE_FILE, FILE_READ);
  if (!f) return 1;
  int idx = f.parseInt();
  f.close();
  if (idx < 1 || idx > 3) idx = 1;
  return idx;
}

static bool createImageFileFilled(const char* path, uint8_t fillByte) {
  if (!spiffsReady) return false;
  File f = SPIFFS.open(path, FILE_WRITE);
  if (!f) return false;
  const size_t total = BLE_IMAGE_SIZE; // 800*480/2 = 192000 bytes
  const size_t chunk = 4096;
  uint8_t buf[chunk];
  memset(buf, fillByte, sizeof(buf));
  size_t written = 0;
  while (written < total) {
    size_t n = (total - written) < chunk ? (total - written) : chunk;
    size_t w = f.write(buf, n);
    if (w != n) { f.close(); return false; }
    written += w;
  }
  f.close();
  return true;
}

static bool ensureDefaultImagesCreated() {
  if (!spiffsReady) return false;
  bool needCreate = !SPIFFS.exists(IMAGE1_PATH) || !SPIFFS.exists(IMAGE2_PATH) || !SPIFFS.exists(IMAGE3_PATH);
  if (!needCreate) return false;
  Serial.println("Creating default SPIFFS images (first boot)...");
  bool ok1 = createImageFileFilled(IMAGE1_PATH, 0x33); // Red
  bool ok2 = createImageFileFilled(IMAGE2_PATH, 0x55); // Blue
  bool ok3 = createImageFileFilled(IMAGE3_PATH, 0x02); // Yellow
  if (ok1 && ok2 && ok3) {
    currentImageIndex = 1;
    saveCurrentImageIndex(currentImageIndex);
    Serial.println("Default images created successfully.");
    return true;
  } else {
    Serial.println("Failed to create default images.");
    return false;
  }
}

// Shared battery percent helper (ADC pin 1.60V ->0%, 1.909V ->100%)
uint8_t getBatteryPercent() {
  analogReadResolution(12);
  
  // Take 10 samples and calculate average for stable reading
  const int numSamples = 10;
  long rawSum = 0;
  for (int i = 0; i < numSamples; i++) {
    rawSum += analogRead(BATTERY_PIN);
    delay(1); // Small delay between readings for stability
  }
  float rawAverage = rawSum / (float)numSamples;
  
  float vAdc = (rawAverage / 4095.0f) * 3.3f; // ADC pin voltage from average
  const float VADC_EMPTY = 1.60f;
  const float VADC_FULL  = 1.909f;  // Adjusted to show 100% at current full battery voltage (was 1.936f, showing 86%)
  float percent = (vAdc - VADC_EMPTY) * 100.0f / (VADC_FULL - VADC_EMPTY);
  // Cap at 100% to prevent overcharge indication
  if (percent > 100.0f) percent = 100.0f;
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

// Serial command buffer
String serialCommand = "";

// Touch tap detection variables
const unsigned long TAP_TIMEOUT = 500;  // Maximum time between taps (ms)
const unsigned long TAP_DURATION = 200; // Maximum duration of a single tap (ms)
unsigned long lastTapTime = 0;
int tapCount = 0;
bool touchActive = false;
unsigned long touchStartTime = 0;

/**
 * Detect double and triple taps on the capacitive touch sensor
 */
void handleTapDetection() {
  uint16_t touchVal = touchRead(TOUCH_PIN);
  unsigned long currentTime = millis();
  
  // Check if touch is currently active (below threshold)
  bool isTouched = (touchVal < touchThreshold);
  
  // Detect touch press (transition from not touched to touched)
  if (isTouched && !touchActive) {
    touchActive = true;
    touchStartTime = currentTime;
    
    // Check if this tap is within the timeout window from last tap
    if (currentTime - lastTapTime < TAP_TIMEOUT) {
      tapCount++;
    } else {
      // Too much time passed, start new tap sequence
      tapCount = 1;
    }
    
    lastTapTime = currentTime;
  }
  
  // Detect touch release (transition from touched to not touched)
  if (!isTouched && touchActive) {
    touchActive = false;
    unsigned long tapDuration = currentTime - touchStartTime;
    
    // Only count as valid tap if it was quick enough
    if (tapDuration > TAP_DURATION) {
      // Too long - this was a hold, not a tap. Reset sequence.
      tapCount = 0;
    }
  }
  
  // Check if tap sequence has completed (timeout expired after last tap)
  if (tapCount > 0 && !touchActive && (currentTime - lastTapTime > TAP_TIMEOUT)) {
    // Tap sequence complete - process it
    if (tapCount == 2) {
      Serial.println("*** DOUBLE TAP DETECTED ***");
      // Next image (1->2->3->1)
      currentImageIndex = (currentImageIndex % 3) + 1;
      saveCurrentImageIndex(currentImageIndex);
      Serial.print("Switching to Image_"); Serial.println(currentImageIndex);
      displayImageFromSPIFFS();
    } else if (tapCount == 3) {
      Serial.println("*** TRIPLE TAP DETECTED ***");
      // Remaining image (skip next): +2 modulo 3
      currentImageIndex = ((currentImageIndex + 1) % 3) + 1;
      saveCurrentImageIndex(currentImageIndex);
      Serial.print("Switching to Image_"); Serial.println(currentImageIndex);
      displayImageFromSPIFFS();
    } else if (tapCount > 3) {
      Serial.print("*** ");
      Serial.print(tapCount);
      Serial.println(" TAPS DETECTED ***");
    }
    
    // Reset tap counter
    tapCount = 0;
  }
}

/**
 * Process serial commands received from terminal
 */
void handleSerialCommands() {
  while (Serial.available() > 0) {
    char inChar = (char)Serial.read();
    
    // Check for newline (Enter key)
    if (inChar == '\n' || inChar == '\r') {
      // Trim whitespace
      serialCommand.trim();
      
      if (serialCommand.length() > 0) {
        // Convert to lowercase for case-insensitive matching
        serialCommand.toLowerCase();
        
        // Process commands
        if (serialCommand == "status") {
          Serial.println("\n========== DEVICE STATUS ==========");
          
          // Battery voltage and percentage (using existing function)
          uint8_t battPercent = getBatteryPercent();
          Serial.printf("Battery: %u%%\n", battPercent);
          
          // Capacitive touch threshold from SPIFFS (already loaded in touchThreshold variable)
          Serial.printf("Touch Threshold (from SPIFFS): %d\n", touchThreshold);
          Serial.printf("Current Touch Reading: %u\n", (uint16_t)touchRead(TOUCH_PIN));
          
          // 5-day refresh timer (configured interval for deep sleep)
          uint64_t refreshDays = REFRESH_INTERVAL_US / (24ULL * 60ULL * 60ULL * 1000000ULL);
          uint64_t refreshHours = (REFRESH_INTERVAL_US / (60ULL * 60ULL * 1000000ULL)) % 24ULL;
          Serial.printf("5-Day Refresh Timer: %llu days %llu hours\n", refreshDays, refreshHours);
          Serial.printf("  (Interval: %llu seconds)\n", REFRESH_INTERVAL_US / 1000000ULL);
          // Current image slot
          Serial.printf("Current Image: Image_%d (%s)\n", currentImageIndex, getCurrentImagePath());
          
          // Additional useful info
          Serial.printf("Firmware Version: %s\n", FIRMWARE_VERSION);
          Serial.printf("BLE Status: %s\n", BLE.connected() ? "Connected" : "Disconnected");
          Serial.printf("SPIFFS: %s\n", spiffsReady ? "Mounted" : "Not Mounted");
          
          Serial.println("===================================\n");
          
        } else if (serialCommand == "spiffs") {
          Serial.println("\n========== SPIFFS INFORMATION ==========");
          
          if (!spiffsReady) {
            Serial.println("ERROR: SPIFFS not mounted!");
            Serial.println("========================================\n");
          } else {
            // Get filesystem info
            size_t totalBytes = SPIFFS.totalBytes();
            size_t usedBytes = SPIFFS.usedBytes();
            size_t freeBytes = totalBytes - usedBytes;
            float usedPercent = (totalBytes > 0) ? (usedBytes * 100.0f / totalBytes) : 0.0f;
            
            Serial.printf("Total Size: %u bytes (%.2f KB)\n", totalBytes, totalBytes / 1024.0f);
            Serial.printf("Used: %u bytes (%.2f KB) [%.1f%%]\n", usedBytes, usedBytes / 1024.0f, usedPercent);
            Serial.printf("Free: %u bytes (%.2f KB)\n", freeBytes, freeBytes / 1024.0f);
            Serial.println("----------------------------------------");
            
            // List all files in SPIFFS
            Serial.println("Files in SPIFFS:");
            File root = SPIFFS.open("/");
            if (!root) {
              Serial.println("ERROR: Failed to open root directory");
            } else if (!root.isDirectory()) {
              Serial.println("ERROR: Root is not a directory");
            } else {
              int fileCount = 0;
              size_t totalFileSize = 0;
              
              File file = root.openNextFile();
              while (file) {
                fileCount++;
                size_t fileSize = file.size();
                totalFileSize += fileSize;
                
                Serial.printf("  [%d] %s\n", fileCount, file.name());
                Serial.printf("      Size: %u bytes (%.2f KB)\n", fileSize, fileSize / 1024.0f);
                
                // Show content preview for small text files
                if (fileSize > 0 && fileSize < 200 && String(file.name()).endsWith(".txt")) {
                  Serial.print("      Content: ");
                  while (file.available()) {
                    char c = file.read();
                    if (c == '\n' || c == '\r') {
                      Serial.print(" ");
                    } else {
                      Serial.print(c);
                    }
                  }
                  Serial.println();
                }
                
                file = root.openNextFile();
              }
              
              Serial.println("----------------------------------------");
              Serial.printf("Total Files: %d\n", fileCount);
              Serial.printf("Total File Size: %u bytes (%.2f KB)\n", totalFileSize, totalFileSize / 1024.0f);
              
              if (fileCount == 0) {
                Serial.println("(No files found in SPIFFS)");
              }
            }
          }
          
          Serial.println("========================================\n");
        } else if (serialCommand == "cleanspiffs") {
          Serial.println("\n========== CLEAN SPIFFS ==========");
          if (!spiffsReady) {
            Serial.println("SPIFFS not mounted, attempting to mount...");
            spiffsReady = SPIFFS.begin(true);
          }
          // Avoid formatting while an image payload is in progress
          if (!receivingSize) {
            Serial.println("ERROR: Image transfer in progress. Try again after it completes.");
            Serial.println("===================================\n");
          } else {
            // Optionally unmount before format
            Serial.println("Formatting SPIFFS partition (this may take a few seconds)...");
            bool ok = SPIFFS.format();
            if (!ok) {
              Serial.println("ERROR: SPIFFS.format() failed.");
              Serial.println("===================================\n");
            } else {
              // Re-mount and recreate defaults
              spiffsReady = SPIFFS.begin(true);
              if (!spiffsReady) {
                Serial.println("ERROR: SPIFFS mount failed after format.");
                Serial.println("===================================\n");
              } else {
                Serial.println("SPIFFS formatted and mounted.");
                bool created = ensureDefaultImagesCreated();
                currentImageIndex = loadCurrentImageIndex();
                Serial.printf("Current Image after clean: Image_%d (%s)\n", currentImageIndex, getCurrentImagePath());
                if (created) {
                  Serial.println("Default images recreated.");
                }
                // Display the current image
                displayImageFromSPIFFS();
                Serial.println("===================================\n");
              }
            }
          }
          
        } else if (serialCommand == "help") {
          Serial.println("\n========== AVAILABLE COMMANDS ==========");
          Serial.println("status  - Display device status");
          Serial.println("spiffs  - Show SPIFFS filesystem info");
          Serial.println("help    - Show this help message");
          Serial.println("cleanspiffs - Format SPIFFS and recreate default images");
          Serial.println("========================================\n");
          
        } else {
          Serial.print("Unknown command: ");
          Serial.println(serialCommand);
          Serial.println("Type 'help' for available commands");
        }
        
        // Clear the command buffer
        serialCommand = "";
      }
    } else {
      // Add character to command buffer
      serialCommand += inChar;
    }
  }
}

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

  // Print firmware version with asterisks
  Serial.println("*************************************************************************");
  Serial.print("***************** ");
  Serial.print(FIRMWARE_VERSION);
  Serial.println(" *****************");
  Serial.println("*************************************************************************");

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
    // Setup default images if not present and load current slot
    bool createdDefaults = ensureDefaultImagesCreated();
    currentImageIndex = loadCurrentImageIndex();
    Serial.print("Current image slot: Image_"); Serial.println(currentImageIndex);
    if (createdDefaults) {
      // Show the first image after initial programming
      displayImageFromSPIFFS();
    }
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
  // Handle serial commands from terminal
  handleSerialCommands();
  
  // Handle tap detection (double tap / triple tap)
  handleTapDetection();
  
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

  // Note: SPIFFS cleanup is now done in BLE.cpp before writing new image
  // This ensures old files are removed before new transfer starts, not at sleep time
  
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