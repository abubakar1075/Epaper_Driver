#include "BLE.h"
#include "W21.h"
#include "SPICom.h"

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
BLECharacteristic rxCharacteristic(rxCharUUID, BLEWrite, BLE_MAX_WRITE_SIZE);  // Use max write size from BLE.h
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

// BLE states
bool bleActive = false;
bool dataReceived = false;

// SPIFFS related globals
const char* IMAGE_PATH = "/ble_image.bin"; // Path to store incoming image data
File imageFile;
bool spiffsReady = false;

// Last connected device tracking
String lastConnectedDeviceAddress = "";

// Helper to diagnose potential size mismatch between raw pixel stream and display packed format
bool warnedSizePacking = false;
// Battery send flag per transfer
static bool batterySentForThisTransfer = false;

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

void displayImageFromSPIFFS() {
  if (!spiffsReady || !SPIFFS.exists(IMAGE_PATH)) {
    Serial.println("No image file found in SPIFFS to display");
    return;
  }
  
  File f = SPIFFS.open(IMAGE_PATH, FILE_READ);
  if (!f) {
    Serial.println("Failed to open image file for display");
    return;
  }
  
  size_t fileSize = f.size();
  Serial.print("SPIFFS image file size: ");
  Serial.print(fileSize);
  Serial.println(" bytes");
  
  // Initialize display
  Serial.println("Initializing display for showing stored image...");
  EPD_init();
  
  // Use our optimized fast display function that works directly with BLE data
  if (fileSize <= BLE_IMAGE_SIZE) {
    // Read the entire file into memory if it's small enough
    if (fileSize <= 65536) {  // Only for files under 64KB
      // For smaller files, we can read the entire file at once
      uint8_t* fileBuffer = (uint8_t*)malloc(fileSize);
      if (fileBuffer) {
        f.read(fileBuffer, fileSize);
        
        // Display the data directly without processing
        PIC_display_fast(fileBuffer, fileSize);
        
        free(fileBuffer);
        f.close();
        Serial.println("Image displayed using fast method");
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
      
      // Write directly to the display
      for (size_t i = 0; i < bytesRead; i++) {
        EPD_W21_WriteDATA(readBuffer[i]);
      }
      
      totalBytesRead += bytesRead;
      
      // Show progress dots
      if ((totalBytesRead % 32768) == 0) {
        Serial.print(".");
      }
    }
    
    // Complete the display refresh
    EPD_W21_WriteCMD(0x12);
    EPD_W21_WriteDATA(0x00);
    delay(1);
    lcd_chkstatus();
    
    Serial.println("\nImage displayed using chunked method");
  } else {
    Serial.println("File size exceeds maximum image size, cannot display");
  }
  
  f.close();
  EPD_sleep();
  Serial.println("Image displayed successfully from SPIFFS");
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
  batterySentForThisTransfer = false;
  
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
  
  // If this is the size information
  if (receivingSize) {
    // Read the data into our main buffer
    characteristic.readValue(buffer, dataLength);
    
    // First 4 bytes contain the expected data size
    expectedDataSize = ((unsigned long)buffer[0]) | 
                       ((unsigned long)buffer[1] << 8) |
                       ((unsigned long)buffer[2] << 16) |
                       ((unsigned long)buffer[3] << 24);
    
    Serial.print("Expected data size: ");
    Serial.print(expectedDataSize);
    Serial.print(" bytes (");
    Serial.print(expectedDataSize / 1024.0, 1);
    Serial.println(" KB)");

    // Verify we're receiving the expected packed format (2 pixels per byte)
    if (expectedDataSize == BLE_IMAGE_SIZE) {
      Serial.println("[Info] Receiving BLE data in 2-pixels-per-byte format (192,000 bytes)");
    } else {
      Serial.print("[Warning] Unexpected data size. Expected 192,000 bytes. Got: ");
      Serial.println(expectedDataSize);
      Serial.println("[Info] Will attempt to process anyway");
    }
    
    // Reset counters for image data and start timing the transfer
    receivedDataSize = 0;
    receivingSize = false;
    displayInitialized = false;
    transferStartTime = millis(); // Start timing the transfer

    // Prepare SPIFFS file for writing new image
    if (spiffsReady) {
      if (SPIFFS.exists(IMAGE_PATH)) {
        SPIFFS.remove(IMAGE_PATH);
        Serial.println("Old image file removed from SPIFFS.");
      }
      imageFile = SPIFFS.open(IMAGE_PATH, FILE_WRITE);
      if (!imageFile) {
        Serial.println("Failed to create image file in SPIFFS.");
      } else {
        Serial.println("Created image file in SPIFFS for incoming data.");
      }
    } else {
      Serial.println("SPIFFS not ready - cannot store incoming data.");
    }
    
    // Send acknowledgment
    sendAcknowledgment(ACK_SIZE_RECEIVED);
    Serial.println("Size received, ready for image data");
    // Send battery once, right at the start of image data per request
    if (!batterySentForThisTransfer) {
  uint8_t batt = getBatteryPercent();
      uint8_t battMsg[] = {ACK_BATTERY, batt};
      txCharacteristic.writeValue(battMsg, sizeof(battMsg));
      batterySentForThisTransfer = true;
      Serial.print("Battery percent sent at start: ");
      Serial.print(batt);
      Serial.println("%");
    }
  } 
  // Otherwise, we're receiving the image data
  else {
    // If this is the first chunk, initialize the display
    if (!displayInitialized) {
      Serial.println("Initializing display for data reception");
      EPD_init_fast();
      
      // Start writing old data (all white)
      EPD_W21_WriteCMD(0x10);
      for (int i = 0; i < IMAGE_WIDTH * IMAGE_HEIGHT / 8; i++) {
        EPD_W21_WriteDATA(0xff);
      }
      
      displayInitialized = true;
    }
    
    // Add the new data to our buffer queue for faster processing
    if (bufferQueue.count < BLE_BUFFER_COUNT) {
      // We have room in the queue, add the data
      int writeIdx = bufferQueue.writeIndex;
      
      // Read data directly into the queue buffer
      characteristic.readValue(bufferQueue.data[writeIdx], dataLength);
      bufferQueue.sizes[writeIdx] = dataLength;
      
      // Update queue state
      bufferQueue.writeIndex = (writeIdx + 1) % BLE_BUFFER_COUNT;
      bufferQueue.count++;
      
      // Process any available buffers while we're receiving more
      if (bufferQueue.count > 0) {
        int readIdx = bufferQueue.readIndex;
        int size = bufferQueue.sizes[readIdx];
        
        // Process this buffer (write to SPIFFS)
        if (imageFile) {
          imageFile.write(bufferQueue.data[readIdx], size);
        }
        
        // Update received count
        receivedDataSize += size;
        
        // Update queue state
        bufferQueue.readIndex = (readIdx + 1) % BLE_BUFFER_COUNT;
        bufferQueue.count--;
      }
    } else {
      // Queue is full, read directly into main buffer and process immediately
      characteristic.readValue(buffer, dataLength);
      
      if (imageFile) {
        imageFile.write(buffer, dataLength);
      }
      
      receivedDataSize += dataLength;
    }
    
    // Print minimal information about the received chunk to reduce serial overhead
    if ((receivedDataSize % 131072) == 0) { // Only show progress every 128KB to reduce overhead
      Serial.print("Received: ");
      Serial.print(receivedDataSize / 1024);
      Serial.print("KB / ");
      Serial.print(expectedDataSize / 1024);
      Serial.println("KB");
    }
      
    // Only flush the SPIFFS file at the very end to greatly improve performance
    if (imageFile && (receivedDataSize >= expectedDataSize)) {
      imageFile.flush();
    }
    
    // Calculate progress percentage and only send acknowledgment periodically
    // This reduces BLE overhead by not sending too many ACKs
    uint8_t progress = (receivedDataSize * 100) / expectedDataSize;
    static uint8_t lastProgress = 0;
    
    // Only send progress update based on BLE_ACK_THRESHOLD to reduce overhead
    // Send ack every X chunks (defined in BLE_ACK_THRESHOLD) instead of by percentage
    if ((receivedDataSize % (BLE_MAX_WRITE_SIZE * BLE_ACK_THRESHOLD)) == 0 || (receivedDataSize >= expectedDataSize)) {
      lastProgress = progress;
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
      
      Serial.print("Transfer complete in ");
      Serial.print(totalTime / 1000.0, 2);
      Serial.println(" seconds");
      Serial.print("Average transfer speed: ");
      Serial.print(speedKBps, 2);
      Serial.println(" KB/s");
      
      // Close the file after writing all data
      if (imageFile) {
        // Process any remaining buffers in the queue
        while (bufferQueue.count > 0) {
          int readIdx = bufferQueue.readIndex;
          imageFile.write(bufferQueue.data[readIdx], bufferQueue.sizes[readIdx]);
          bufferQueue.readIndex = (readIdx + 1) % BLE_BUFFER_COUNT;
          bufferQueue.count--;
        }
        
        imageFile.close();
        Serial.print("Image data stored in SPIFFS at ");
        Serial.println(IMAGE_PATH);
        
        // Set flag for main loop to display the image
        dataReceived = true;
      } else {
        Serial.println("No SPIFFS file to close / print.");
      }
      
      // Send completion acknowledgment
      sendAcknowledgment(ACK_COMPLETE);
    
      // Reset state for next transfer
      receivingSize = true;
      receivedDataSize = 0;
      expectedDataSize = 0;
      displayInitialized = false;
    } else if (receivedDataSize > expectedDataSize) {
      Serial.println("Error: Received more data than expected.");
      
      // Send error acknowledgment
      sendAcknowledgment(ACK_ERROR);
      
      // Reset state
      receivingSize = true;
      receivedDataSize = 0;
      displayInitialized = false;
      EPD_sleep();
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
