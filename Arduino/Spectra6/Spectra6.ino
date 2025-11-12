 // 30 seconds branch
//#define TEST_IMAGE

// Firmware version - update this when you create new OTA files
const char* FIRMWARE_VERSION = "1.36.0";

// GPIO pin definitions
#define CALIBRATION_BUTTON_PIN 0  // GPIO 27 for threshold calibration

#include <SPI.h>
#include <ArduinoBLE.h>
#include <FS.h>
#include <LittleFS.h>
#define SPIFFS LittleFS  // Compatibility alias for seamless migration
#include "esp_sleep.h"  // For deep sleep timer wake
#include "SPICom.h"
#include "W21.h"
#include "image.h"
#include "BLE.h"
void handleLedBlinking();
// LED aliases for readability
const int pcbLED = LED2;   // board LED (e.g., GPIO4 on FirstPCB)
const int userLED = 26;    // user LED on GPIO32 (mirrors pcbLED)

// ============================
// LittleFS image slot management
// ============================
static const char* IMAGE1_PATH = "/Image_1";
static const char* IMAGE2_PATH = "/Image_2";
static const char* IMAGE3_PATH = "/Image_3";
static const char* CURRENT_IMAGE_FILE = "/current.txt";

int currentImageIndex = 1; // 1..3

const char* getImagePathForIndex(int idx) {
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
  
  // Check each slot individually and only recreate missing ones
  bool anyCreated = false;
  
  if (!SPIFFS.exists(IMAGE1_PATH)) {
    Serial.println("Creating default image for Image_1 (Red)...");
    if (createImageFileFilled(IMAGE1_PATH, 0x33)) {
      Serial.println("Image_1 created successfully.");
      anyCreated = true;
    } else {
      Serial.println("Failed to create Image_1.");
    }
  }
  
  if (!SPIFFS.exists(IMAGE2_PATH)) {
    Serial.println("Creating default image for Image_2 (Blue)...");
    if (createImageFileFilled(IMAGE2_PATH, 0x55)) {
      Serial.println("Image_2 created successfully.");
      anyCreated = true;
    } else {
      Serial.println("Failed to create Image_2.");
    }
  }
  
  if (!SPIFFS.exists(IMAGE3_PATH)) {
    Serial.println("Creating default image for Image_3 (Yellow)...");
    if (createImageFileFilled(IMAGE3_PATH, 0x02)) {
      Serial.println("Image_3 created successfully.");
      anyCreated = true;
    } else {
      Serial.println("Failed to create Image_3.");
    }
  }
  
  if (anyCreated) {
    // Only reset currentImageIndex if it's not valid
    int savedIndex = loadCurrentImageIndex();
    if (savedIndex < 1 || savedIndex > 3) {
      currentImageIndex = 1;
      saveCurrentImageIndex(currentImageIndex);
    }
  }
  
  return anyCreated;
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

/**
 * Perform capacitive touch sensor calibration
 * This function can be called from physical button or BLE command
 */
void performCalibration() {
  uint16_t currentTouch = touchRead(TOUCH_PIN);
  touchThreshold = currentTouch - 4;
  if (touchThreshold < 10) touchThreshold = 10;
  saveThreshold(touchThreshold);
  Serial.printf("*** CALIBRATION COMPLETE ***\n");
  Serial.printf("Threshold calibrated to: %d\n", touchThreshold);
  
  // Flash LEDs (pcbLED and userLED) 3 times to indicate success
  for(int i=0; i<3; i++) {
    analogWrite(pcbLED, 255); 
    analogWrite(userLED, 255); 
    delay(100);
    analogWrite(pcbLED, 0);  
    analogWrite(userLED, 0);  
    delay(100);
  }
}

// Variables for LED blinking
unsigned long previousMillis = 0;
const long blinkInterval = 1000;  // Blink every 1 second
const long blinkDuration = 50;    // LED on for 50ms

// Variables for LED fading (charging indication)
unsigned long fadeStartMillis = 0;
const long fadeCycleDuration = 2000;  // Total cycle: 1s fade in + 1s fade out
int currentBrightness = 0;
bool isCharging = false;

// Variables for idle timeout (sleep after 30s unless actively receiving image)
unsigned long connectionStartTime = 0;
const long connectionTimeout = 30000;  // 30 seconds timeout for inactivity
bool bleConnected = false;

// Flag to track if hardware was initialized during wakeup long press
bool hardwareInitializedOnWake = false;

// Periodic refresh interval: 5 days in microseconds
static const uint64_t REFRESH_INTERVAL_US = 5ULL * 24ULL * 60ULL * 60ULL * 1000000ULL;

// Serial command buffer
String serialCommand = "";

// Touch tap detection variables
const unsigned long TAP_TIMEOUT = 500;  // Maximum time between taps (ms)
const unsigned long TAP_DURATION = 200; // Maximum duration of a single tap (ms)
const unsigned long LONG_PRESS_DURATION = 2000; // Long press duration (2 seconds)
unsigned long lastTapTime = 0;
int tapCount = 0;
bool touchActive = false;
unsigned long touchStartTime = 0;
bool longPressTriggered = false;
bool touchReleasedAfterLongPress = true; // Track if touch was released after last long press

/**
 * Detect long press (2 seconds) and double taps on the capacitive touch sensor
 * Long press = Next image (1->2->3->1)
 * Double tap = Remaining image (skip next)
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
    longPressTriggered = false;
    
    // Check if this tap is within the timeout window from last tap
    if (currentTime - lastTapTime < TAP_TIMEOUT) {
      tapCount++;
    } else {
      // Too much time passed, start new tap sequence
      tapCount = 1;
    }
    
    lastTapTime = currentTime;
  }
  
  // Check for long press while touch is still active
  if (isTouched && touchActive && !longPressTriggered) {
    unsigned long pressDuration = currentTime - touchStartTime;
    
    if (pressDuration >= LONG_PRESS_DURATION) {
      // Check if touch was released after previous long press
      if (!touchReleasedAfterLongPress) {
        Serial.println("Ignoring second long press as there was no touch release");
        longPressTriggered = true; // Mark as triggered to prevent repeated messages
        tapCount = 0; // Reset tap counter
        return; // Don't process this long press
      }
      
      // Long press detected - Next image
      Serial.println("*** LONG PRESS DETECTED (2s) ***");
      longPressTriggered = true;
      touchReleasedAfterLongPress = false; // Mark that touch needs to be released
      tapCount = 0; // Reset tap counter
      
      // Next image (1->2->3->1)
      currentImageIndex = (currentImageIndex % 3) + 1;
      saveCurrentImageIndex(currentImageIndex);
      Serial.print("Switching to Image_"); Serial.println(currentImageIndex);
      displayImageFromSPIFFS();
      // Reset idle timer so device stays awake for 30s after user action
      connectionStartTime = millis();
      Serial.println("Idle timer reset after long-press image change");
    }
  }
  
  // Detect touch release (transition from touched to not touched)
  if (!isTouched && touchActive) {
    touchActive = false;
    unsigned long tapDuration = currentTime - touchStartTime;
    
    // If long press was triggered, don't process as tap
    if (longPressTriggered) {
      tapCount = 0;
      longPressTriggered = false;
      touchReleasedAfterLongPress = true; // Touch has been released after long press
      Serial.println("Touch released after long press - ready for next long press");
    }
    // Only count as valid tap if it was quick enough
    else if (tapDuration > TAP_DURATION) {
      // Too long - this was a hold, not a tap. Reset sequence.
      tapCount = 0;
    }
  }
  
  // Check if tap sequence has completed (timeout expired after last tap)
  if (tapCount > 0 && !touchActive && (currentTime - lastTapTime > TAP_TIMEOUT)) {
    // Tap sequence complete - process it
    if (tapCount == 2) {
      Serial.println("*** DOUBLE TAP DETECTED ***");
      // Remaining image (skip next): +2 modulo 3
      currentImageIndex = ((currentImageIndex + 1) % 3) + 1;
      saveCurrentImageIndex(currentImageIndex);
      Serial.print("Switching to Image_"); Serial.println(currentImageIndex);
      displayImageFromSPIFFS();
      // Reset idle timer so device stays awake for 30s after user action
      connectionStartTime = millis();
      Serial.println("Idle timer reset after double-tap image change");
    } else if (tapCount > 2) {
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
          Serial.println("\n========== LITTLEFS INFORMATION ==========");
          
          if (!spiffsReady) {
            Serial.println("ERROR: LittleFS not mounted!");
            Serial.println("==========================================\n");
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
            Serial.println("LittleFS Features:");
            Serial.println("  ✓ Wear leveling enabled");
            Serial.println("  ✓ Power-loss resilient");
            Serial.println("  ✓ Reduced fragmentation");
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
          Serial.println("\n========== CLEAN LITTLEFS ==========");
          if (!spiffsReady) {
            Serial.println("LittleFS not mounted, attempting to mount...");
            spiffsReady = SPIFFS.begin(true);
          }
          // Avoid formatting while an image payload is in progress
          if (!receivingSize) {
            Serial.println("ERROR: Image transfer in progress. Try again after it completes.");
            Serial.println("====================================\n");
          } else {
            // Optionally unmount before format
            Serial.println("Formatting LittleFS partition (this may take a few seconds)...");
            bool ok = SPIFFS.format();
            if (!ok) {
              Serial.println("ERROR: LittleFS.format() failed.");
              Serial.println("====================================\n");
            } else {
              // Re-mount and recreate defaults
              spiffsReady = SPIFFS.begin(true);
              if (!spiffsReady) {
                Serial.println("ERROR: LittleFS mount failed after format.");
                Serial.println("====================================\n");
              } else {
                Serial.println("LittleFS formatted and mounted.");
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
  
  // Check if woken by GPIO39 (USB voltage detection)
  if (wakeCause == ESP_SLEEP_WAKEUP_EXT1) {
    Serial.begin(115200);
    delay(100);
    Serial.println("*************************************************************************");
    Serial.println("***************** WAKEUP FROM USB PIN (GPIO39) *****************");
    Serial.println("*************************************************************************");
    // Continue normal initialization - don't go back to sleep immediately
    // This allows BLE and charging indication to work
  }
  
  if (wakeCause == ESP_SLEEP_WAKEUP_TIMER) {
    Serial.println("Wake cause: RTC timer. Refreshing image from LittleFS...");
    // Ensure board GPIOs are configured (power rails, indicator LED)
    if (!spiffsReady) {
      spiffsReady = SPIFFS.begin(true);
      if (!spiffsReady) {
        Serial.println("LittleFS mount failed during timer wake.");
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
    // Keep both timer, touch, and USB voltage as wake sources
    touchSleepWakeUpEnable(TOUCH_PIN, touchThreshold);
    esp_sleep_enable_ext1_wakeup(1ULL << GPIO_NUM_39, ESP_EXT1_WAKEUP_ANY_HIGH);
    esp_sleep_enable_timer_wakeup(REFRESH_INTERVAL_US);
    Serial.flush();
    esp_deep_sleep_start();
  }

  pinMode(GND, OUTPUT); // Will be ignored if GPIO35 is input-only
  pinMode(pcbLED, OUTPUT); // LED on GPIO4
  pinMode(userLED, OUTPUT);   // Mirror LED on GPIO32
  digitalWrite(GND, LOW);
  analogWrite(pcbLED, 255);
  analogWrite(userLED, 255);
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
    Serial.println("[Warning] LED on GPIO34 (input-only) - blinking disabled.");
  #endif
  Serial.println("==============================");
  
  // Initialize LittleFS early to load threshold for touch detection
  spiffsReady = SPIFFS.begin(true);
  if (spiffsReady) {
    touchThreshold = loadThreshold();
    Serial.printf("Touch threshold loaded: %d\n", touchThreshold);
  }
  
  // Check if woken by touch - detect long press immediately
  if (wakeCause == ESP_SLEEP_WAKEUP_TOUCHPAD) {
    Serial.println("Wake cause: Touch pad");
    
    // Load current image index FIRST (needed for both short and long press)
    if (spiffsReady) {
      currentImageIndex = loadCurrentImageIndex();
      Serial.print("Loaded current slot from LittleFS: Image_"); Serial.println(currentImageIndex);
    }
    
    // Wait a moment for touch sensor to stabilize
    delay(50);
    
    // Check if user is still holding the touch (long press detection)
    unsigned long pressStart = millis();
    bool stillTouched = true;
    
    while (millis() - pressStart < LONG_PRESS_DURATION) {
      uint16_t touchVal = touchRead(TOUCH_PIN);
      
      if (touchVal >= touchThreshold) {
        // Touch released before long press duration
        stillTouched = false;
        Serial.println("Touch released - short press detected");
        break;
      }
      delay(50);  // Check every 50ms
    }
    
    if (stillTouched) {
      // Long press detected immediately after wake!
      Serial.println("*** LONG PRESS DETECTED ON WAKEUP (2s) ***");
      
      if (spiffsReady) {
        // Next image (1->2->3->1) - currentImageIndex already loaded above
        currentImageIndex = (currentImageIndex % 3) + 1;
        saveCurrentImageIndex(currentImageIndex);
        Serial.print("Switching to Image_"); Serial.println(currentImageIndex);
        
        // Initialize display hardware
        pinMode(PIN_EPD_BUSY, INPUT);
        pinMode(PIN_EPD_RST, OUTPUT);
        pinMode(PIN_EPD_DC, OUTPUT);
        pinMode(PIN_EPD_CS, OUTPUT);
        digitalWrite(PIN_EPD_CS, HIGH);
        digitalWrite(PIN_EPD_DC, HIGH);
        digitalWrite(PIN_EPD_RST, HIGH);
        
#if defined(ARDUINO_XIAO_ESP32C3)
        SPI.begin(EPD_SPI_SCK, EPD_SPI_MISO, EPD_SPI_MOSI, PIN_EPD_CS);
        Serial.println("ESP32C3 detected - using explicit SPI pin configuration");
#else
        SPI.begin();
        Serial.println("Using default SPI pin configuration");
#endif
        SPI.beginTransaction(SPISettings(8000000, MSBFIRST, SPI_MODE0));
        
        // Display the new image
        displayImageFromSPIFFS();
        
        Serial.println("Image changed via long press on wakeup");
        
        // Set flag to skip redundant hardware initialization
        hardwareInitializedOnWake = true;
      }
    }
  }
  
  // Re-initialize LittleFS (in case not done above)
  if (!spiffsReady) {
    spiffsReady = SPIFFS.begin(true);
  }
  
  if(!spiffsReady) {
    Serial.println("LittleFS mount failed!");
  } else {
    if (!touchThreshold) {
      // Load threshold if not already loaded (e.g., if LittleFS was just initialized)
      touchThreshold = loadThreshold();
      Serial.printf("Touch threshold: %d\n", touchThreshold);
    }
    
    // Setup default images if not present and load current slot
    // Skip if images were just used during long press (we know they exist)
    bool createdDefaults = false;
    if (!hardwareInitializedOnWake) {
      createdDefaults = ensureDefaultImagesCreated();
    } else {
      Serial.println("Skipping default image check - images already verified during wakeup");
    }
    
    // Load current index only if not already loaded (e.g., not loaded during touch wakeup)
    if (!currentImageIndex || currentImageIndex < 1 || currentImageIndex > 3) {
      currentImageIndex = loadCurrentImageIndex();
      Serial.print("Loaded current slot from LittleFS: Image_"); Serial.println(currentImageIndex);
    } else {
      Serial.print("Current image slot already set: Image_"); Serial.println(currentImageIndex);
    }
    
    if (createdDefaults) {
      // Show the first image after initial programming
      displayImageFromSPIFFS();
    }
  }
  
  // Setup calibration button for threshold calibration
  pinMode(CALIBRATION_BUTTON_PIN, INPUT_PULLUP);
  
  // Setup boot button (GPIO0) for factory reset
  pinMode(0, INPUT_PULLUP);
   
  // Initialize EPD pins and SPI - skip if already done during long press on wakeup
  if (!hardwareInitializedOnWake) {
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
  } else {
    Serial.println("Hardware already initialized during wakeup - skipping redundant init");
  }
  
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
  
  // Handle pcbLED/userLED blinking
  handleLedBlinking();

  // Boot/Calibration button (GPIO0) - combined handling
  // Short press: Calibrate threshold
  // Long press (5+ seconds): Factory reset (format flash and restart)
  #define BOOT_BUTTON_PIN 0
  static bool lastButtonState = HIGH;
  static unsigned long buttonPressStartTime = 0;
  static bool factoryResetTriggered = false;
  
  bool buttonState = digitalRead(CALIBRATION_BUTTON_PIN); // Same as BOOT_BUTTON_PIN (GPIO0)
  
  // Button just pressed
  if (lastButtonState == HIGH && buttonState == LOW) {
    buttonPressStartTime = millis();
    factoryResetTriggered = false;
    Serial.println("Button pressed...");
  }
  // Button still held - check for long press
  else if (buttonState == LOW && !factoryResetTriggered) {
    unsigned long pressDuration = millis() - buttonPressStartTime;
    if (pressDuration >= 5000) {
      // Long press detected - factory reset
      factoryResetTriggered = true;
      Serial.println("===========================================");
      Serial.println("BOOT BUTTON HELD FOR 5+ SECONDS");
      Serial.println("FACTORY RESET INITIATED");
      Serial.println("===========================================");
      
      // Format LittleFS (SPIFFS)
      Serial.println("Step 1: Formatting LittleFS...");
      if (SPIFFS.format()) {
        Serial.println("Step 1: LittleFS formatted successfully");
      } else {
        Serial.println("Step 1: LittleFS format failed");
      }
      
      // Restart ESP32
      Serial.println("Step 2: Restarting ESP32...");
      Serial.flush();
      delay(500);
      ESP.restart();
    }
  }
  // Button released
  else if (lastButtonState == LOW && buttonState == HIGH) {
    unsigned long pressDuration = millis() - buttonPressStartTime;
    Serial.println("Button released");
    
    // Only calibrate if it was a short press (not a factory reset)
    if (pressDuration < 5000 && !factoryResetTriggered) {
      // Short press - calibrate threshold
      Serial.println("Physical button calibration triggered");
      performCalibration();
    }
  }
  lastButtonState = buttonState;
  
  // Check for BLE connection status
  if (BLE.connected() && !bleConnected) {
    bleConnected = true;
    Serial.println("BLE device connected!");
  } else if (!BLE.connected() && bleConnected) {
    bleConnected = false;
    Serial.println("BLE device disconnected!");
  }
  
  // Send battery/charging status every second if connected
  static unsigned long lastBatteryUpdate = 0;
  if (BLE.connected() && (millis() - lastBatteryUpdate >= 1000)) {
    lastBatteryUpdate = millis();
    
    // Check GPIO39 voltage to determine if charging
    int gpio39Raw = analogRead(39);
    float gpio39Voltage = (gpio39Raw / 4095.0) * 3.3;
    float usbVoltage = gpio39Voltage * 2.0;
    
    // Send charging status or battery percentage
    extern BLECharacteristic txCharacteristic;
    if (usbVoltage > 4.5) {
      uint8_t chargingMsg[] = {0xB1, 0x01}; // ACK_CHARGING
      txCharacteristic.writeValue(chargingMsg, sizeof(chargingMsg));
    } else {
      uint8_t batt = getBatteryPercent();
      uint8_t battMsg[] = {0xB0, batt}; // ACK_BATTERY
      txCharacteristic.writeValue(battMsg, sizeof(battMsg));
    }
  }
  
  // Hold/reset the 30s idle timer while image data is actively being received
  // receivingSize == false means we're currently in the image payload phase
  if (!receivingSize) {
    connectionStartTime = millis();
  }

  // Show sleep countdown every second
  static unsigned long lastCountdownPrint = 0;
  unsigned long timeElapsed = millis() - connectionStartTime;
  unsigned long timeRemaining = connectionTimeout > timeElapsed ? (connectionTimeout - timeElapsed) / 1000 : 0;
  
  if (receivingSize && !dataReceived && (millis() - lastCountdownPrint >= 1000)) {
    lastCountdownPrint = millis();
    
    // Read touch value and GPIO39 voltage for debugging
    uint16_t currentTouch = touchRead(TOUCH_PIN);
    int gpio39Raw = analogRead(39);  // Read GPIO39 ADC value (12-bit: 0-4095)
    float gpio39Voltage = (gpio39Raw / 4095.0) * 3.3;  // Convert to voltage (assuming 3.3V reference)
    // If GPIO39 has a voltage divider from 5V, calculate the actual input voltage
    float gpio39Input = gpio39Voltage * 2.0;  // Assuming 2:1 voltage divider (adjust ratio as needed)
    
    // Read battery voltage from BATTERY_PIN
    int batteryRaw = analogRead(BATTERY_PIN);
    float batteryAdcVoltage = (batteryRaw / 4095.0) * 3.3;  // Voltage at ADC pin
    float batteryVoltage = batteryAdcVoltage * 2.0;  // Actual battery voltage (2:1 divider)
    
    Serial.printf("sleep: %lu | Touch: %u | usb %.2fV | bat: %.2fV\n", 
                  timeRemaining, currentTouch, gpio39Input, batteryVoltage);
  }

  // Sleep after 30s of idle (no active image transfer), regardless of BLE connection state
  // BUT do not sleep if USB is connected (GPIO39 has voltage > 4.5V for charging)
  if ((millis() - connectionStartTime > connectionTimeout) && receivingSize && !dataReceived) {
    // Check GPIO39 voltage before sleeping
    int gpio39Raw = analogRead(39);
    float gpio39Voltage = (gpio39Raw / 4095.0) * 3.3;
    float usbVoltage = gpio39Voltage * 2.0;  // 2:1 voltage divider
    
    if (usbVoltage > 4.5) {
      // USB charging detected - don't sleep, just reset the timer
      Serial.printf("Charging detected (%.2fV) - staying awake...\n", usbVoltage);
      connectionStartTime = millis();  // Reset timer to prevent continuous checking
    } else {
      // No charging - safe to sleep
      Serial.println("Going to sleep...");
      goToSleep();
    }
  }
  
  // Poll BLE for events
  BLE.poll();
  
  // Check for charging state changes (minimal data - only on change)
  extern void bleTick();
  bleTick();
  
  // If we have new data received via BLE, display it and wait 3s before sleep
  if (dataReceived) {
    if (!skipDisplay) {
      // Image verified OK - display it
      Serial.println("New data received via BLE. Displaying image...");
      displayImageFromSPIFFS();
      Serial.println("Image displayed. Keeping BLE active for 3 seconds...");
    } else {
      // Image corrupted - skip display
      Serial.println("Image corrupted - skipping display.");
      Serial.println("Keeping BLE active for 3 seconds...");
      skipDisplay = false;  // Reset flag for next transfer
    }
    
    dataReceived = false; // Reset flag
    
    // Keep BLE active for 3 seconds to allow another image transfer
    unsigned long waitStart = millis();
    while (millis() - waitStart < 3000) {
      BLE.poll();  // Keep BLE responsive
      
      // If new data starts arriving, reset idle timer and break out
      if (!receivingSize) {
        Serial.println("New image transfer detected! Cancelling sleep...");
        connectionStartTime = millis();
        break;
      }
      
      delay(10);
    }
    
    // If no new transfer started, check USB voltage before sleeping
    if (receivingSize) {
      // Check GPIO39 voltage before sleeping
      int gpio39Raw = analogRead(39);
      float gpio39Voltage = (gpio39Raw / 4095.0) * 3.3;
      float usbVoltage = gpio39Voltage * 2.0;  // 2:1 voltage divider
      
      if (usbVoltage > 4.5) {
        // Charging detected - don't sleep
        Serial.printf("Charging detected (%.2fV) - staying awake...\n", usbVoltage);
        connectionStartTime = millis();  // Reset timer
      } else {
        // No charging - safe to sleep
        Serial.println("No new transfer. Going to sleep...");
        goToSleep();
      }
    }
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

  
  // Flash LEDs (pcbLED and userLED) to indicate going to sleep
  for (int i = 0; i < 5; i++) {
    analogWrite(pcbLED, 255); analogWrite(userLED, 255);
    delay(100);
    analogWrite(pcbLED, 0);  analogWrite(userLED, 0);
    delay(100);
  }
  
  Serial.printf("Entering deep sleep mode. Touch GPIO%d to wake up again.\n", TOUCH_PIN);
  Serial.flush();

  // Note: SPIFFS cleanup is now done in BLE.cpp before writing new image
  // This ensures old files are removed before new transfer starts, not at sleep time
  
  // Configure touchpad as wakeup source
  // Use touch channel T9 which maps to GPIO32 on classic ESP32
  touchSleepWakeUpEnable(TOUCH_PIN, touchThreshold);
  
  // Configure GPIO39 (USB voltage detection) as EXT1 wakeup source
  // Wake when GPIO39 goes HIGH (USB connected/charging)
  esp_sleep_enable_ext1_wakeup(1ULL << GPIO_NUM_39, ESP_EXT1_WAKEUP_ANY_HIGH);
  
  // Also configure periodic 5-day RTC timer wake for image refresh
  esp_sleep_enable_timer_wakeup(REFRESH_INTERVAL_US);
  
  // Go to deep sleep
  esp_deep_sleep_start();
}


/**
 * Handle the blinking of pcbLED/userLED (50ms on, every second)
 * If touch value is below threshold, keep LED ON continuously
 * Otherwise, continue normal blinking behavior
 */
void handleLedBlinking() {
  unsigned long currentMillis = millis();
  uint16_t touchVal = touchRead(TOUCH_PIN);
  
  // Check USB charging voltage on GPIO39
  int gpio39Raw = analogRead(39);
  float gpio39Voltage = (gpio39Raw / 4095.0) * 3.3;
  float usbVoltage = gpio39Voltage * 2.0;  // Assuming 2:1 voltage divider
  
  // Determine if charging (USB voltage > 4.5V)
  isCharging = (usbVoltage > 4.5);
  
  // If touch value is less than threshold, keep LEDs ON continuously
  if (touchVal < touchThreshold) {
    // Use PWM for consistent behavior regardless of charging state
    analogWrite(pcbLED, 255);
    analogWrite(userLED, 255);
    return; // Exit early
  }
  
  // If charging, show fading effect
  if (isCharging) {
    unsigned long fadeElapsed = currentMillis - fadeStartMillis;
    
    // Reset cycle if it's complete
    if (fadeElapsed >= fadeCycleDuration) {
      fadeStartMillis = currentMillis;
      fadeElapsed = 0;
    }
    
    // Calculate brightness (0-255) based on position in cycle
    if (fadeElapsed < 1000) {
      // First 1 second: fade in (0 to 255)
      currentBrightness = map(fadeElapsed, 0, 1000, 0, 255);
    } else {
      // Next 1 second: fade out (255 to 0)
      currentBrightness = map(fadeElapsed, 1000, 2000, 255, 0);
    }
    
    // Apply PWM to both LEDs
    analogWrite(pcbLED, currentBrightness);
    analogWrite(userLED, currentBrightness);
  } 
  // Otherwise, continue normal blinking behavior
  else {
    // Check if it's time to turn the LED on
    if (currentMillis - previousMillis >= blinkInterval) {
      // Save the time when we started the blink cycle
      previousMillis = currentMillis;
      
      // Turn LEDs on for blinkDuration (use analogWrite to ensure proper reset from PWM)
      analogWrite(pcbLED, 255);
      analogWrite(userLED, 255);
    } 
    // Check if it's time to turn the LED off
    else if (currentMillis - previousMillis >= blinkDuration && 
             currentMillis - previousMillis < blinkInterval) {
      analogWrite(pcbLED, 0);
      analogWrite(userLED, 0);
    }
  }
}