#include "BLE.h"
#include "W21.h"
#include "SPICom.h"
#include <Update.h>

// Forward declaration of Color_get from W21.cpp
extern unsigned char Color_get(unsigned char color);

// BLE service and characteristic UUIDs
const char* serviceUUID = "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"; // UART service
const char* rxCharUUID = "6E400002-B5A3-F393-E0A9-E50E24DCCA9E";  // RX characteristic
const char* txCharUUID = "6E400003-B5A3-F393-E0A9-E50E24DCCA9E";  // TX characteristic

// MTU and transfer parameters
int currentMTU = 512; // Start with max MTU for speed
const int MAX_MTU = 512; // Maximum MTU we'll try to negotiate
const int DEFAULT_MTU = 23; // Default BLE MTU
int chunkSize = BLE_MAX_WRITE_SIZE; // Use maximum allowed size from BLE.h
unsigned long lastTransferTime = 0;
unsigned long transferStartTime = 0; // Track transfer start time
unsigned long transferSpeed = 0; // bytes per second

// BLE service and characteristics
BLEService uartService(serviceUUID);
BLECharacteristic rxCharacteristic(rxCharUUID, BLEWrite | BLEWriteWithoutResponse, BLE_MAX_WRITE_SIZE);  // Allow write without response for speed
BLECharacteristic txCharacteristic(txCharUUID, BLENotify, 20);  // Notify buffer size = 20 bytes
BLEDescriptor rxDescriptor("2901", "RX Channel");
BLEDescriptor txDescriptor("2901", "TX Channel");

// Multiple buffers for received data to implement double-buffering
const int BUFFER_SIZE = BLE_MAX_WRITE_SIZE;  // Match buffer size to max write size
unsigned char buffer[BUFFER_SIZE];  // Main buffer for compatibility

// Optimized buffer queue for faster processing
struct BufferQueue {
  unsigned char data[BLE_BUFFER_COUNT][BUFFER_SIZE];
  int sizes[BLE_BUFFER_COUNT];
  volatile int writeIndex;
  volatile int readIndex;
  volatile int count;
} bufferQueue = {{0}, {0}, 0, 0, 0};

// Tracking variables
unsigned long expectedDataSize = 0;
unsigned long receivedDataSize = 0;
bool receivingSize = true;
bool displayInitialized = false;

// Detailed byte tracking for debugging
unsigned long bytesReceivedFromBLE = 0;
unsigned long bytesWrittenToSPIFFS = 0;
unsigned long bytesReadFromSPIFFS = 0;
unsigned long bytesSentToDisplay = 0;

// BLE states
bool bleActive = false;
bool dataReceived = false;
bool skipDisplay = false;  // Flag to skip display if image is corrupted

// SPIFFS related globals
const char* IMAGE_PATH = "/ble_image.bin"; // Legacy path (unused now, kept for compatibility)
File imageFile;
bool spiffsReady = false;
// OTA file path and transfer mode flag
const char* OTA_PATH = "/ota.bin";
bool isOtaTransfer = false;
// Header parsing state for typed header support (1-byte type + 4-byte size)
static uint8_t headerBuf[5];
static int headerCollected = 0;
static int headerExpectedLen = 0; // 5 for typed header, 4 for legacy
static bool headerHasType = false; // true if first byte is a transfer type

// Last connected device tracking
String lastConnectedDeviceAddress = "";

// Helper to diagnose potential size mismatch between raw pixel stream and display packed format
bool warnedSizePacking = false;
// Battery send flag per transfer
static bool batterySentForThisTransfer = false;

// Delay values (in milliseconds) for SPIFFS operations (reduced for performance)
#ifndef SPIFFS_DELAY_OPEN_MS
#define SPIFFS_DELAY_OPEN_MS 5
#endif
#ifndef SPIFFS_DELAY_REMOVE_MS
#define SPIFFS_DELAY_REMOVE_MS 5
#endif
#ifndef SPIFFS_DELAY_WRITE_MS
#define SPIFFS_DELAY_WRITE_MS 0
#endif
#ifndef SPIFFS_DELAY_FLUSH_MS
#define SPIFFS_DELAY_FLUSH_MS 20
#endif
#ifndef SPIFFS_DELAY_CLOSE_MS
#define SPIFFS_DELAY_CLOSE_MS 10
#endif

// Flush strategy: Don't flush on every write, instead flush every 32KB
// This greatly reduces SPIFFS fragmentation delays (pauses at 24%, 50%, 83%, etc.)
#define SPIFFS_FLUSH_EVERY_WRITE 0
#define SPIFFS_FLUSH_INTERVAL 32768  // Flush every 32 KB (only 6 times for 192KB image)

// Global tracking for periodic flushing
unsigned long lastFlushSize = 0;

// getBatteryPercent() implemented in Spectra6.ino

// Periodic BLE tasks
static unsigned long lastBatteryAnnounce = 0;
void bleTick() {
  if (!BLE.connected()) return;
  unsigned long now = millis();
  // Re-announce battery every 10 seconds while connected
  if (now - lastBatteryAnnounce >= 10000) {
    lastBatteryAnnounce = now;
  uint8_t batt = getBatteryPercent();
    uint8_t battMsg[] = {ACK_BATTERY, batt};
    txCharacteristic.writeValue(battMsg, sizeof(battMsg));
  }
}

//===============================================================
// SPIFFS Functions
//===============================================================

bool initSPIFFS() {
  if (!SPIFFS.begin(true)) {  // Format on failure
    Serial.println("SPIFFS initialization failed!");
    return false;
  }
  
  Serial.print("SPIFFS total bytes: ");
  Serial.println(SPIFFS.totalBytes());
  Serial.print("SPIFFS used bytes: ");
  Serial.println(SPIFFS.usedBytes());
  
  return true;
}

//===============================================================
//===============================================================
// Display Functions
//===============================================================

void displayImageFromSPIFFSPath(const char* path) {
  if (!spiffsReady || !path || !SPIFFS.exists(path)) {
    Serial.println("[DISPLAY] ERROR: No image file found");
    return;
  }
  
  File f = SPIFFS.open(path, FILE_READ);
  if (!f) {
    Serial.println("[DISPLAY] ERROR: Failed to open file");
    return;
  }
  
  size_t fileSize = f.size();
  Serial.printf("[DISPLAY] Showing %s (%u bytes)\n", path, fileSize);
  
  // Reset display tracking counters
  bytesReadFromSPIFFS = 0;
  bytesSentToDisplay = 0;
  
  // Initialize display
  EPD_init();
  
  // Use our optimized fast display function that works directly with BLE data
  if (fileSize <= BLE_IMAGE_SIZE) {
    // Read the entire file into memory if it's small enough
    if (fileSize <= 65536) {  // Only for files under 64KB
      uint8_t* fileBuffer = (uint8_t*)malloc(fileSize);
      if (fileBuffer) {
        size_t bytesRead = f.read(fileBuffer, fileSize);
        bytesReadFromSPIFFS += bytesRead;
        
        // Display the data directly without processing
        PIC_display_fast(fileBuffer, fileSize);
        bytesSentToDisplay += fileSize;
        
        free(fileBuffer);
        f.close();
        
        // Print display summary
        Serial.println("\n========== DISPLAY SUMMARY ==========");
        Serial.printf("Bytes read from SPIFFS:  %lu\n", bytesReadFromSPIFFS);
        Serial.printf("Bytes sent to display:   %lu\n", bytesSentToDisplay);
        Serial.println("=====================================\n");
        Serial.println("[DISPLAY] Complete");
        return;
      }
    }
    
    // For larger files, read and display in chunks
    const size_t CHUNK_SIZE = 4096;  // 4KB chunks
    uint8_t readBuffer[CHUNK_SIZE];
    
    EPD_W21_WriteCMD(0x10);
    
    size_t totalBytesRead = 0;
    while (f.available()) {
      size_t bytesRead = f.read(readBuffer, CHUNK_SIZE);
      if (bytesRead <= 0) break;
      
      bytesReadFromSPIFFS += bytesRead;
      
      // Write directly to the display
      for (size_t i = 0; i < bytesRead; i++) {
        EPD_W21_WriteDATA(readBuffer[i]);
      }
      bytesSentToDisplay += bytesRead;
      
      totalBytesRead += bytesRead;
    }
    
    // Complete the display refresh
    EPD_W21_WriteCMD(0x12);
    EPD_W21_WriteDATA(0x00);
    delay(1);
    lcd_chkstatus();
    
    // Print display summary
    Serial.println("\n========== DISPLAY SUMMARY ==========");
    Serial.printf("Bytes read from SPIFFS:  %lu\n", bytesReadFromSPIFFS);
    Serial.printf("Bytes sent to display:   %lu\n", bytesSentToDisplay);
    Serial.println("=====================================\n");
    Serial.println("[DISPLAY] Complete");
  } else {
    Serial.println("[DISPLAY] ERROR: File too large");
  }
  
  f.close();
  EPD_sleep();
}

void displayImageFromSPIFFS() {
  // Display the current image slot file
  const char* path = getCurrentImagePath();
  displayImageFromSPIFFSPath(path);
}

void displayTransferError() {
  Serial.println("Displaying 'Transfer Error' message...");
  
  EPD_init();
  EPD_W21_WriteCMD(0x10);
  // For error screen, use red background
  for (int i = 0; i < IMAGE_WIDTH * IMAGE_HEIGHT / 2; i++) {
    EPD_W21_WriteDATA(0x33); // Red
  }
  
  // Refresh the display
  EPD_W21_WriteCMD(0x12); // DISPLAY REFRESH
  EPD_W21_WriteDATA(0x00);
  delay(1);
  lcd_chkstatus();
  EPD_sleep();
  
  Serial.println("'Transfer Error' message displayed");
}

//===============================================================
// BLE Functions
//===============================================================

void startBLE() {
  Serial.println("Starting BLE services...");
  
  if (BLE.begin()) {
    // Configure the device for BLE
    BLE.setLocalName("EPD-Display");
    BLE.setAdvertisedService(uartService);
    
    // Add descriptors to characteristics
    rxCharacteristic.addDescriptor(rxDescriptor);
    txCharacteristic.addDescriptor(txDescriptor);
    
    // Add the characteristics to the service
    uartService.addCharacteristic(rxCharacteristic);
    uartService.addCharacteristic(txCharacteristic);
    
    // Add the service
    BLE.addService(uartService);
    
    // Set the event handlers
    rxCharacteristic.setEventHandler(BLEWritten, onRxCharacteristicWritten);
    BLE.setEventHandler(BLEConnected, onBLEConnected);
    BLE.setEventHandler(BLEDisconnected, onBLEDisconnected);
    
    // Set advertising parameters for better discovery
    BLE.setAdvertisingInterval(160); // 100ms (160 * 0.625ms)
    
    // Start advertising
    BLE.advertise();
    
    bleActive = true;
    Serial.println("BLE services started and advertising");
  } else {
    Serial.println("Failed to start BLE!");
  }
}

// BLE connection event handler
void onBLEConnected(BLEDevice central) {
  Serial.print("BLE Connection established with device: ");
  Serial.println(central.address());
  
  // Reset state for new connection
  receivingSize = true;
  receivedDataSize = 0;
  expectedDataSize = 0;
  displayInitialized = false;
  dataReceived = false;
  skipDisplay = false;  // Reset skip flag for new transfer
  batterySentForThisTransfer = false;
  isOtaTransfer = false;
  headerCollected = 0;
  headerExpectedLen = 0;
  headerHasType = false;
  
  // Reset byte tracking counters
  bytesReceivedFromBLE = 0;
  bytesWrittenToSPIFFS = 0;
  bytesReadFromSPIFFS = 0;
  bytesSentToDisplay = 0;
  
  // For ArduinoBLE, we can't directly request MTU changes, but we can
  // optimize our settings for the fastest possible transfer
  Serial.println("Using high-speed BLE settings...");
  
  // Use maximum chunk size allowed
  chunkSize = BLE_MAX_WRITE_SIZE;
  
  // Update the currentMTU variable to reflect our target MTU
  currentMTU = BLE_MTU_SIZE;
  
  // Set faster connection parameters for high-speed transfer
  BLE.setConnectionInterval(0x0006, 0x0010); // 7.5ms to 20ms
  
  Serial.print("Optimized chunk size: ");
  Serial.println(chunkSize);
  Serial.print("Target MTU: ");
  Serial.println(currentMTU);
  
  // Send a notification to indicate connection is successful
  // Include our preferred MTU size in the message
  uint8_t connectMsg[] = {0xC0, 0xDE, 
                          (uint8_t)(BLE_MTU_SIZE & 0xFF), 
                          (uint8_t)((BLE_MTU_SIZE >> 8) & 0xFF)};
  txCharacteristic.writeValue(connectMsg, sizeof(connectMsg));
  
  Serial.print("Initial chunk size set to: ");
  Serial.println(chunkSize);
}

// BLE disconnection event handler
void onBLEDisconnected(BLEDevice central) {
  Serial.print("BLE Connection ended with device: ");
  Serial.println(central.address());
  
  // Reset any in-progress transfer state
  receivingSize = true;
  receivedDataSize = 0;
  expectedDataSize = 0;
  
  if (displayInitialized) {
    // Make sure to properly close any in-progress display operation
    EPD_sleep();
    displayInitialized = false;
  }

  // Close file if still open on disconnect
  if (imageFile) {
    imageFile.close();
    Serial.println("SPIFFS image file closed due to disconnect.");
  }
  
  // Start advertising again
  Serial.println("Re-starting BLE advertising...");
  BLE.advertise();
}

// Function to handle incoming BLE data
void onRxCharacteristicWritten(BLEDevice central, BLECharacteristic characteristic) {
  // Get the value length
  int dataLength = characteristic.valueLength();
  
  // Check for version query command (0x30) - single byte command
  if (dataLength == 1) {
    uint8_t command;
    characteristic.readValue(&command, 1);
    
    if (command == 0x30) {
      // Version query command - send firmware version
      String version = FIRMWARE_VERSION;
      uint8_t versionMsg[32];
      versionMsg[0] = 0x30; // Version response header
      int versionLen = version.length();
      if (versionLen > 30) versionLen = 30; // Limit to 30 chars
      memcpy(&versionMsg[1], version.c_str(), versionLen);
      
      txCharacteristic.writeValue(versionMsg, versionLen + 1);
      Serial.print("Version query received, sent: ");
      Serial.println(version);
      return;
    }
  }
  
  // If this is the size information
  if (receivingSize) {
    // Read the incoming bytes locally to support typed or legacy headers and possible extra payload
    uint8_t temp[BLE_MAX_WRITE_SIZE];
    characteristic.readValue(temp, dataLength);

    int usedForHeader = 0;

    // Determine header format if starting fresh
    if (headerCollected == 0) {
      // If first byte looks like a transfer type, expect 5-byte header, else legacy 4-byte size
      if (dataLength >= 1 && (temp[0] == 0x10 || temp[0] == 0x20)) {
        headerHasType = true;
        headerExpectedLen = 5;
      } else {
        headerHasType = false;
        headerExpectedLen = 4;
      }

      if (dataLength >= headerExpectedLen) {
        // We have full header in this packet
        if (headerHasType) {
          uint8_t t = temp[0];
          expectedDataSize = ((unsigned long)temp[1]) |
                             ((unsigned long)temp[2] << 8) |
                             ((unsigned long)temp[3] << 16) |
                             ((unsigned long)temp[4] << 24);
          isOtaTransfer = (t == 0x20); // 0x10 = image, 0x20 = OTA
          Serial.print("[Typed] Header type: 0x");
          Serial.print(t, HEX);
          Serial.print(" size: ");
          Serial.println(expectedDataSize);
          usedForHeader = 5;
        } else {
          expectedDataSize = ((unsigned long)temp[0]) |
                             ((unsigned long)temp[1] << 8) |
                             ((unsigned long)temp[2] << 16) |
                             ((unsigned long)temp[3] << 24);
          isOtaTransfer = (expectedDataSize != BLE_IMAGE_SIZE);
          Serial.print("[Legacy] Header size: ");
          Serial.println(expectedDataSize);
          usedForHeader = 4;
        }
      } else {
        // Partial header, store and wait for next packet
        memcpy(headerBuf, temp, dataLength);
        headerCollected = dataLength;
        return;
      }
    } else {
      // Continue collecting a partial header
      int need = headerExpectedLen - headerCollected;
      int toCopy = (dataLength < need) ? dataLength : need;
      memcpy(&headerBuf[headerCollected], temp, toCopy);
      headerCollected += toCopy;
      usedForHeader = toCopy;
      if (headerCollected < headerExpectedLen) {
        // Still waiting for more header bytes
        return;
      }
      // We now have a full header in headerBuf
      if (headerHasType) {
        uint8_t t = headerBuf[0];
        expectedDataSize = ((unsigned long)headerBuf[1]) |
                           ((unsigned long)headerBuf[2] << 8) |
                           ((unsigned long)headerBuf[3] << 16) |
                           ((unsigned long)headerBuf[4] << 24);
        isOtaTransfer = (t == 0x20);
        Serial.print("[Typed] Header(type in two packets) type: 0x");
        Serial.print(t, HEX);
        Serial.print(" size: ");
        Serial.println(expectedDataSize);
      } else {
        expectedDataSize = ((unsigned long)headerBuf[0]) |
                           ((unsigned long)headerBuf[1] << 8) |
                           ((unsigned long)headerBuf[2] << 16) |
                           ((unsigned long)headerBuf[3] << 24);
        isOtaTransfer = (expectedDataSize != BLE_IMAGE_SIZE);
        Serial.print("[Legacy] Header(size in two packets) size: ");
        Serial.println(expectedDataSize);
      }
      // Reset header collection for next transfer
      headerCollected = 0;
    }

    Serial.printf("[HEADER] %s transfer: %lu bytes (%.1f KB)\n", 
                 isOtaTransfer ? "OTA" : "IMAGE", 
                 expectedDataSize, expectedDataSize / 1024.0);

    // If OTA transfer, format SPIFFS first (before receiving data)
    if (isOtaTransfer && spiffsReady) {
      Serial.println("\n========== PRE-OTA SPIFFS CLEANUP ==========");
      
      // Backup touch threshold before format
      int savedThreshold = 70; // Default fallback value
      if (SPIFFS.exists("/thresh.txt")) {
        File f = SPIFFS.open("/thresh.txt", "r");
        if (f) {
          int loadedValue = f.parseInt();
          f.close();
          if (loadedValue > 0) {
            savedThreshold = loadedValue;
            Serial.printf("Threshold backed up from SPIFFS: %d\n", savedThreshold);
          } else {
            Serial.printf("Threshold file empty, using default: %d\n", savedThreshold);
          }
        } else {
          Serial.printf("Failed to read threshold file, using default: %d\n", savedThreshold);
        }
      } else {
        Serial.printf("No saved threshold found, using default: %d\n", savedThreshold);
      }
      
      Serial.println("Formatting SPIFFS before OTA download...");
      if (SPIFFS.format()) {
        Serial.println("SPIFFS formatted successfully.");
        
        // Re-mount SPIFFS after format
        spiffsReady = SPIFFS.begin(true);
        if (spiffsReady) {
          Serial.println("SPIFFS re-mounted after format.");
          
          // Restore threshold to fresh SPIFFS
          File f = SPIFFS.open("/thresh.txt", "w");
          if (f) {
            f.println(savedThreshold);
            f.close();
            Serial.printf("Threshold restored to SPIFFS: %d\n", savedThreshold);
          } else {
            Serial.println("WARNING: Failed to restore threshold file.");
          }
        } else {
          Serial.println("ERROR: Failed to re-mount SPIFFS after format!");
        }
      } else {
        Serial.println("ERROR: SPIFFS format failed!");
      }
      Serial.println("============================================\n");
    }

    // Reset ALL counters for data and start timing the transfer
    receivedDataSize = 0;
    bytesReceivedFromBLE = 0;
    bytesWrittenToSPIFFS = 0;
    receivingSize = false;
    displayInitialized = false;
    transferStartTime = millis();
    lastFlushSize = 0;  // Reset flush tracking for new transfer

    // Prepare SPIFFS file for writing incoming data (image or OTA)
    if (spiffsReady) {
      const char* path = isOtaTransfer ? OTA_PATH : getCurrentImagePath();
      
      // Critical: Ensure file is fully removed before creating new one
      // This prevents SPIFFS corruption after multiple overwrites (~20+ times)
      if (SPIFFS.exists(path)) {
        Serial.printf("[SPIFFS] Removing old file: %s\n", path);
        SPIFFS.remove(path);
        delay(SPIFFS_DELAY_REMOVE_MS);
        
        // Verify deletion succeeded
        if (SPIFFS.exists(path)) {
          Serial.println("[SPIFFS] WARNING: File still exists after remove, trying again...");
          SPIFFS.remove(path);
          delay(SPIFFS_DELAY_REMOVE_MS * 2);
        }
      }
      
      // Open file for writing (creates new file)
      imageFile = SPIFFS.open(path, FILE_WRITE);
      if (imageFile) {
        delay(SPIFFS_DELAY_OPEN_MS);
        Serial.printf("[SPIFFS] File created: %s\n", path);
      } else {
        Serial.println("[SPIFFS] ERROR: Failed to create file");
      }
    } else {
      Serial.println("SPIFFS not ready - cannot store incoming data.");
    }

    // Send acknowledgment for header/size
    sendAcknowledgment(ACK_SIZE_RECEIVED);
    Serial.println("Size received, ready for data");
    // Send battery once, at the start
    if (!batterySentForThisTransfer) {
      uint8_t batt = getBatteryPercent();
      uint8_t battMsg[] = {ACK_BATTERY, batt};
      txCharacteristic.writeValue(battMsg, sizeof(battMsg));
      batterySentForThisTransfer = true;
      Serial.print("Battery percent sent at start: ");
      Serial.print(batt);
      Serial.println("%");
    }

    // If there are leftover bytes in this packet after the header, treat them as the first data chunk
    int leftover = dataLength - usedForHeader;
    if (leftover > 0) {
      const uint8_t* payload = &temp[usedForHeader];
      // Initialize display on first payload if this is an image transfer
      if (!isOtaTransfer && !displayInitialized) {
        Serial.println("Initializing display for data reception");
        EPD_init_fast();
        EPD_W21_WriteCMD(0x10);
        for (int i = 0; i < IMAGE_WIDTH * IMAGE_HEIGHT / 8; i++) {
          EPD_W21_WriteDATA(0xff);
        }
        displayInitialized = true;
      }
      if (imageFile && leftover > 0) {
        // Prevent overflow: only write what we need
        size_t bytesToWrite = leftover;
        if (receivedDataSize + bytesToWrite > expectedDataSize) {
          bytesToWrite = expectedDataSize - receivedDataSize;
        }
        
        if (bytesToWrite > 0) {
          imageFile.write(payload, bytesToWrite);
          bytesWrittenToSPIFFS += bytesToWrite;
          receivedDataSize += bytesToWrite;
          bytesReceivedFromBLE += bytesToWrite;
          
          // Periodic flush every 32KB instead of every write (prevents fragmentation delays)
          if ((receivedDataSize / SPIFFS_FLUSH_INTERVAL) > (lastFlushSize / SPIFFS_FLUSH_INTERVAL)) {
            imageFile.flush();
            delay(SPIFFS_DELAY_FLUSH_MS);
            lastFlushSize = receivedDataSize;
          }
          yield();
        }
      }

      // Minimal progress/ack updates matching main path
      uint8_t progress = (receivedDataSize * 100) / expectedDataSize;
      if ((receivedDataSize % (BLE_MAX_WRITE_SIZE * BLE_ACK_THRESHOLD)) == 0 || (receivedDataSize >= expectedDataSize)) {
        sendProgressUpdate(progress);
        if ((progress % 20) == 0 || progress == 100) {
          unsigned long currentTime = millis();
          unsigned long elapsedTime = currentTime - transferStartTime;
          if (elapsedTime > 0) {
            transferSpeed = (receivedDataSize * 1000) / elapsedTime;
            Serial.print("Transfer speed: ");
            Serial.print(transferSpeed / 1024.0, 2);
            Serial.println(" KB/s");
          }
        }
      }

      // If we already received everything in this packet, finalize
      if (imageFile && (receivedDataSize >= expectedDataSize)) {
        imageFile.flush();
      }

      if (receivedDataSize >= expectedDataSize) {
        unsigned long totalTime = millis() - transferStartTime;
        float speedKBps = (float)(expectedDataSize * 1000) / (float)(totalTime * 1024);
        Serial.print("Transfer complete in ");
        Serial.print(totalTime / 1000.0, 2);
        Serial.println(" seconds");
        Serial.print("Average transfer speed: ");
        Serial.print(speedKBps, 2);
        Serial.println(" KB/s");

        if (imageFile) {
          imageFile.close();
          if (isOtaTransfer) {
            Serial.print("OTA data stored in SPIFFS at ");
            Serial.println(OTA_PATH);
            // Apply OTA update
            File otaFile = SPIFFS.open(OTA_PATH, FILE_READ);
            if (!otaFile) {
              Serial.println("Failed to open OTA file for reading");
              sendAcknowledgment(ACK_ERROR);
            } else {
              Serial.println("Starting OTA update...");
              if (!Update.begin(expectedDataSize)) {
                Serial.println("Update.begin failed");
                otaFile.close();
                sendAcknowledgment(ACK_ERROR);
              } else {
                size_t written = 0;
                const size_t BUFSZ = 4096;
                uint8_t buf[BUFSZ];
                while (otaFile.available()) {
                  size_t n = otaFile.read(buf, BUFSZ);
                  if (n == 0) break;
                  size_t w = Update.write(buf, n);
                  written += w;
                  if (w != n) {
                    Serial.println("OTA write mismatch");
                    break;
                  }
                }
                otaFile.close();
                if (written == expectedDataSize && Update.end(true)) {
                  Serial.println("OTA update successful!");
                  sendAcknowledgment(ACK_COMPLETE);
                  delay(200);
                  
                  // Backup touch threshold before format
                  int savedThreshold = 70; // Default fallback value
                  if (SPIFFS.exists("/thresh.txt")) {
                    File f = SPIFFS.open("/thresh.txt", "r");
                    if (f) {
                      int loadedValue = f.parseInt();
                      f.close();
                      if (loadedValue > 0) {
                        savedThreshold = loadedValue;
                        Serial.printf("Threshold backed up from SPIFFS: %d\n", savedThreshold);
                      } else {
                        Serial.printf("Threshold file empty, using default: %d\n", savedThreshold);
                      }
                    } else {
                      Serial.printf("Failed to read threshold file, using default: %d\n", savedThreshold);
                    }
                  } else {
                    Serial.printf("No saved threshold found, using default: %d\n", savedThreshold);
                  }
                  
                  Serial.println("Cleaning up SPIFFS before restart...");
                  if (SPIFFS.format()) {
                    Serial.println("SPIFFS formatted successfully.");
                    
                    // Restore threshold to fresh SPIFFS
                    File f = SPIFFS.open("/thresh.txt", "w");
                    if (f) {
                      f.println(savedThreshold);
                      f.close();
                      Serial.printf("Threshold restored to SPIFFS: %d\n", savedThreshold);
                    } else {
                      Serial.println("WARNING: Failed to restore threshold file.");
                    }
                  } else {
                    Serial.println("WARNING: SPIFFS format failed, but continuing with restart.");
                  }
                  
                  Serial.println("Restarting ESP32 to apply OTA update...");
                  Serial.flush();
                  delay(500);
                  ESP.restart();
                } else {
                  Serial.print("OTA failed. Error #");
                  Serial.println(Update.getError());
                  Update.end();
                  sendAcknowledgment(ACK_ERROR);
                }
              }
            }
          } else {
            Serial.print("Image data stored in SPIFFS at ");
            Serial.println(getCurrentImagePath());
            dataReceived = true;
            sendAcknowledgment(ACK_COMPLETE);
          }
        }

        // Reset state for next transfer
        receivingSize = true;
        receivedDataSize = 0;
        expectedDataSize = 0;
        displayInitialized = false;
        isOtaTransfer = false;
      }
    }
  } 
  // Otherwise, we're receiving the image or OTA data
  else {
    // If this is the first chunk for image transfer, initialize the display
    if (!isOtaTransfer && !displayInitialized) {
      Serial.println("[DISPLAY] Initializing e-paper display...");
      EPD_init_fast();
      EPD_W21_WriteCMD(0x10);
      for (int i = 0; i < IMAGE_WIDTH * IMAGE_HEIGHT / 8; i++) {
        EPD_W21_WriteDATA(0xff);
      }
      displayInitialized = true;
      Serial.println("[DISPLAY] Ready for data");
    }
    
    // Read data directly and write immediately (no queue buffering to prevent double-write bug)
    characteristic.readValue(buffer, dataLength);
    
    // Write data to SPIFFS immediately
    if (imageFile && receivedDataSize < expectedDataSize) {
      // Calculate how much we can actually write (prevent overflow)
      size_t bytesToWrite = dataLength;
      if (receivedDataSize + bytesToWrite > expectedDataSize) {
        bytesToWrite = expectedDataSize - receivedDataSize;
      }
      
      if (bytesToWrite > 0) {
        imageFile.write(buffer, bytesToWrite);
        bytesWrittenToSPIFFS += bytesToWrite;
        receivedDataSize += bytesToWrite;
        bytesReceivedFromBLE += bytesToWrite;
        
        // Periodic flush every 32KB to prevent fragmentation delays
        if ((receivedDataSize / SPIFFS_FLUSH_INTERVAL) > (lastFlushSize / SPIFFS_FLUSH_INTERVAL)) {
          imageFile.flush();
          delay(SPIFFS_DELAY_FLUSH_MS);
          lastFlushSize = receivedDataSize;
        }
        yield();
      }
    }
    
    // Print progress information every 64KB (less frequent for better speed)
    if ((receivedDataSize % 65536) == 0) {
      float percentComplete = (receivedDataSize * 100.0) / expectedDataSize;
      Serial.printf("[RX] %lu KB / %lu KB (%.0f%%)\n", 
                   receivedDataSize / 1024, expectedDataSize / 1024, percentComplete);
    }
      
    // Only flush the SPIFFS file at the very end to greatly improve performance
    if (imageFile && (receivedDataSize >= expectedDataSize)) {
      imageFile.flush();
      delay(SPIFFS_DELAY_FLUSH_MS);
      yield();
    }
    
    // Calculate progress percentage and only send acknowledgment periodically
    // This reduces BLE overhead by not sending too many ACKs
  uint8_t progress = (receivedDataSize * 100) / expectedDataSize;
    
    // Only send progress update based on BLE_ACK_THRESHOLD to reduce overhead
    // Send ack every X chunks (defined in BLE_ACK_THRESHOLD) instead of by percentage
    if ((receivedDataSize % (BLE_MAX_WRITE_SIZE * BLE_ACK_THRESHOLD)) == 0 || (receivedDataSize >= expectedDataSize)) {
  sendProgressUpdate(progress);
      
      // Only print progress at 20% intervals to reduce Serial overhead
      if ((progress % 20) == 0 || progress == 100) {
        Serial.print("Progress: ");
        Serial.print(progress);
        Serial.println("%");
        
        // Calculate and report transfer speed again at these intervals
        unsigned long currentTime = millis();
        unsigned long elapsedTime = currentTime - transferStartTime;
        if (elapsedTime > 0) {
          // Calculate speed in KB/s
          transferSpeed = (receivedDataSize * 1000) / elapsedTime;
          Serial.print("Transfer speed: ");
          Serial.print(transferSpeed / 1024.0, 2);
          Serial.println(" KB/s");
        }
      }
    }
    
  // Check if we've received all the data
    if (receivedDataSize >= expectedDataSize) {
      // Print total transfer time and speed at completion
      unsigned long totalTime = millis() - transferStartTime;
      float speedKBps = (float)(expectedDataSize * 1000) / (float)(totalTime * 1024);
      
      Serial.printf("[COMPLETE] %lu bytes in %.1fs (%.1f KB/s)\n", 
                   receivedDataSize, totalTime / 1000.0, speedKBps);
      
      // Close the file after writing all data
      if (imageFile) {
        // Critical: Ensure all data is flushed and synced before closing
        Serial.println("[SPIFFS] Flushing final data...");
        imageFile.flush();
        delay(SPIFFS_DELAY_FLUSH_MS * 2);
        imageFile.close();
        delay(SPIFFS_DELAY_CLOSE_MS * 2);
        Serial.println("[SPIFFS] File closed");
        
        if (isOtaTransfer) {
          Serial.print("OTA data stored in SPIFFS at ");
          Serial.println(OTA_PATH);
          // Apply OTA update
          File otaFile = SPIFFS.open(OTA_PATH, FILE_READ);
          if (!otaFile) {
            Serial.println("Failed to open OTA file for reading");
            sendAcknowledgment(ACK_ERROR);
          } else {
            Serial.println("Starting OTA update...");
            if (!Update.begin(expectedDataSize)) {
              Serial.println("Update.begin failed");
              otaFile.close();
              sendAcknowledgment(ACK_ERROR);
            } else {
              size_t written = 0;
              const size_t BUFSZ = 4096;
              uint8_t buf[BUFSZ];
              while (otaFile.available()) {
                size_t n = otaFile.read(buf, BUFSZ);
                if (n == 0) break;
                size_t w = Update.write(buf, n);
                written += w;
                if (w != n) {
                  Serial.println("OTA write mismatch");
                  break;
                }
              }
              otaFile.close();
              if (written == expectedDataSize && Update.end(true)) {
                Serial.println("OTA update successful!");
                sendAcknowledgment(ACK_COMPLETE);
                delay(200);
                
                // Backup touch threshold before format
                int savedThreshold = 70; // Default fallback value
                if (SPIFFS.exists("/thresh.txt")) {
                  File f = SPIFFS.open("/thresh.txt", "r");
                  if (f) {
                    int loadedValue = f.parseInt();
                    f.close();
                    if (loadedValue > 0) {
                      savedThreshold = loadedValue;
                      Serial.printf("Threshold backed up from SPIFFS: %d\n", savedThreshold);
                    } else {
                      Serial.printf("Threshold file empty, using default: %d\n", savedThreshold);
                    }
                  } else {
                    Serial.printf("Failed to read threshold file, using default: %d\n", savedThreshold);
                  }
                } else {
                  Serial.printf("No saved threshold found, using default: %d\n", savedThreshold);
                }
                
                Serial.println("Cleaning up SPIFFS before restart...");
                if (SPIFFS.format()) {
                  Serial.println("SPIFFS formatted successfully.");
                  
                  // Restore threshold to fresh SPIFFS
                  File f = SPIFFS.open("/thresh.txt", "w");
                  if (f) {
                    f.println(savedThreshold);
                    f.close();
                    Serial.printf("Threshold restored to SPIFFS: %d\n", savedThreshold);
                  } else {
                    Serial.println("WARNING: Failed to restore threshold file.");
                  }
                } else {
                  Serial.println("WARNING: SPIFFS format failed, but continuing with restart.");
                }
                
                Serial.println("Restarting ESP32 to apply OTA update...");
                Serial.flush();
                delay(500);
                ESP.restart();
              } else {
                Serial.print("OTA failed. Error #");
                Serial.println(Update.getError());
                Update.end();
                sendAcknowledgment(ACK_ERROR);
              }
            }
          }
        } else {
          Serial.printf("[SPIFFS] Saved to %s\n", getCurrentImagePath());
          
          // Verify file size immediately after writing
          delay(50); // Give SPIFFS time to finalize write
          File verifyFile = SPIFFS.open(getCurrentImagePath(), FILE_READ);
          bool fileCorrupted = false;
          if (verifyFile) {
            size_t fileSize = verifyFile.size();
            verifyFile.close();
            
            // Print detailed byte tracking summary
            Serial.println("\n========== BYTE TRACKING SUMMARY ==========");
            Serial.printf("Expected bytes:          %lu\n", expectedDataSize);
            Serial.printf("Bytes received from BLE: %lu\n", bytesReceivedFromBLE);
            Serial.printf("Bytes written to SPIFFS: %lu\n", bytesWrittenToSPIFFS);
            Serial.printf("Bytes in SPIFFS file:    %u\n", fileSize);
            
            if (fileSize == expectedDataSize) {
              Serial.println("STATUS:                  OK - File verified");
              Serial.println("===========================================\n");
              Serial.println("[VERIFY] ✓ File size matches, image will be displayed");
            } else {
              Serial.println("STATUS:                  CORRUPTED - Image skipped");
              Serial.println("===========================================\n");
              
              Serial.printf("[VERIFY] ✗ ERROR: Expected %lu, got %u bytes - SPIFFS CORRUPTION!\n", expectedDataSize, fileSize);
              Serial.println("[SKIP] Corrupted image will NOT be displayed");
              fileCorrupted = true;
            }
          } else {
            Serial.println("\n========== BYTE TRACKING SUMMARY ==========");
            Serial.printf("Expected bytes:          %lu\n", expectedDataSize);
            Serial.printf("Bytes received from BLE: %lu\n", bytesReceivedFromBLE);
            Serial.printf("Bytes written to SPIFFS: %lu\n", bytesWrittenToSPIFFS);
            Serial.println("STATUS:                  ERROR - Cannot verify");
            Serial.println("===========================================\n");
            Serial.println("[VERIFY] ✗ ERROR: Cannot open file for verification");
            fileCorrupted = true;
          }
          
          // Set flags for main loop
          if (!fileCorrupted) {
            dataReceived = true;
            skipDisplay = false;  // Image is good, display it
          } else {
            dataReceived = true;   // Still set to trigger main loop
            skipDisplay = true;    // But skip the display step
          }
          sendAcknowledgment(ACK_COMPLETE);
        }
      } else {
        Serial.println("No SPIFFS file to close / print.");
      }
      
      // For image transfers, completion ack already sent above. For OTA, we send ack inside OTA branch.
      
      // Reset state for next transfer
      receivingSize = true;
      receivedDataSize = 0;
      expectedDataSize = 0;
      displayInitialized = false;
      isOtaTransfer = false;
    } else if (receivedDataSize > expectedDataSize) {
      Serial.println("Error: Received more data than expected.");
      
      // Send error acknowledgment
      sendAcknowledgment(ACK_ERROR);
      
      // Reset state
      if (imageFile) {
        imageFile.close();
        delay(SPIFFS_DELAY_CLOSE_MS);
      }
      receivingSize = true;
      receivedDataSize = 0;
      displayInitialized = false;
      EPD_sleep();
      isOtaTransfer = false;
    }
  }
}

// Utility: Read the stored image file and print its content in hex to Serial.
// WARNING: This can produce a very large amount of output for large images.
void printImageFileHex() {
  if (!spiffsReady) {
    Serial.println("SPIFFS not ready - cannot read file.");
    return;
  }
  File f = SPIFFS.open(IMAGE_PATH, FILE_READ);
  if (!f) {
    Serial.println("Failed to open image file for reading.");
    return;
  }
  Serial.println("\n--- Begin SPIFFS Image File Hex Dump ---");
  const size_t dumpBuffer = 256; // read in chunks to limit RAM
  uint8_t temp[dumpBuffer];
  size_t index = 0;
  while (true) {
    size_t n = f.read(temp, dumpBuffer);
    if (!n) break;
    for (size_t i = 0; i < n; i++) {
      if (index % 32 == 0) {
        Serial.println();
        Serial.print(index);
        Serial.print(": ");
      }
      Serial.print(temp[i], HEX);
      Serial.print(' ');
      index++;
      delay(1);
    }
  }
  f.close();
  Serial.println();
  Serial.println("--- End SPIFFS Image File Hex Dump ---\n");
}

// Helper functions for optimized BLE transfer

// Updates the transfer speed calculation based on received data size and time
void updateTransferSpeed() {
  // Calculate transfer speed for high-performance BLE transfers
  static unsigned long lastUpdateTime = 0;
  unsigned long currentTime = millis();
  
  // Only update stats every 5 seconds to reduce overhead significantly
  if (currentTime - lastUpdateTime < 5000) {
    return;
  }
  
  lastUpdateTime = currentTime;
  unsigned long elapsedTime = currentTime - transferStartTime;
  
  if (elapsedTime > 0 && receivedDataSize > 0) {
    // Calculate bytes per second
    transferSpeed = (receivedDataSize * 1000) / elapsedTime;
    
    // Only print if we've received at least 10% of the data to reduce overhead
    if (receivedDataSize > expectedDataSize / 10) {
      // Convert to KB/s for display
      float speedKBps = transferSpeed / 1024.0;
      
      Serial.print("Speed: ");
      Serial.print(speedKBps, 1);
      Serial.print(" KB/s");
      
      // Only print ETA when we have enough data to make a reasonable estimate
      if (receivedDataSize > expectedDataSize / 5) {
        // Estimate remaining time
        if (expectedDataSize > receivedDataSize) {
          unsigned long remainingBytes = expectedDataSize - receivedDataSize;
          unsigned long remainingTimeMs = (remainingBytes * 1000) / transferSpeed;
          
          Serial.print(" | ETA: ");
          Serial.print(remainingTimeMs / 1000.0, 1);
          Serial.println("s");
        }
      } else {
        Serial.println(); // Just end the line
      }
    }
  }
}

// Sends an acknowledgment to the connected BLE client
void sendAcknowledgment(uint8_t type) {
  // Send an acknowledgment with minimal data
  uint8_t ack[1] = {type};
  txCharacteristic.writeValue(ack, 1);
}

// Sends a progress update to the connected BLE client
void sendProgressUpdate(uint8_t progress) {
  static uint8_t lastReportedProgress = 0;
  
  // Only send if progress has changed by at least 5% to reduce BLE overhead
  if (progress - lastReportedProgress >= 5 || progress == 100) {
    uint8_t ack[2] = {ACK_PROGRESS, progress};
    txCharacteristic.writeValue(ack, 2);
    lastReportedProgress = progress;
    
    // Only print at 20% intervals to reduce serial overhead
    if ((progress % 20) == 0 || progress == 100) {
      Serial.print("Progress: ");
      Serial.print(progress);
      Serial.println("%");
      
      // Update transfer speed when we report progress
      updateTransferSpeed();
    }
  }
}
