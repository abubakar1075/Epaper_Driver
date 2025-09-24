#ifndef BLE_H
#define BLE_H

#include <Arduino.h>
#include <ArduinoBLE.h>
#include <FS.h>
#include <SPIFFS.h>

// Constants for BLE acknowledgements
#define ACK_SIZE_RECEIVED 0x01   // Size acknowledgment
#define ACK_PROGRESS 0x02        // Progress update
#define ACK_COMPLETE 0x03        // Transfer complete
#define ACK_ERROR 0xFF           // Error acknowledgment
// New: battery percentage notification
#define ACK_BATTERY 0xB0         // Battery percentage notification (value in next byte)

// BLE service and characteristic UUIDs
extern const char* serviceUUID;
extern const char* rxCharUUID;
extern const char* txCharUUID;

// BLE service and characteristics
extern BLEService uartService;
extern BLECharacteristic rxCharacteristic;
extern BLECharacteristic txCharacteristic;

// High-speed transfer optimization
#define BLE_MTU_SIZE 512          // Target MTU size for BLE
#define BLE_ACK_THRESHOLD 200     // Send acknowledgment every 200 chunks (increased for max speed)
#define BLE_MAX_WRITE_SIZE 512    // Maximum write size per packet
#define BLE_BUFFER_COUNT 8        // Increased number of buffers in the queue for better performance
extern BLEDescriptor rxDescriptor;
extern BLEDescriptor txDescriptor;

// Buffer for received data
extern const int BUFFER_SIZE;
extern unsigned char buffer[];
extern unsigned long expectedDataSize;
extern unsigned long receivedDataSize;
extern bool receivingSize;
extern bool displayInitialized;

// MTU and transfer parameters
extern int currentMTU;
extern const int MAX_MTU;
extern const int DEFAULT_MTU;
extern int chunkSize;
extern unsigned long lastTransferTime;
extern unsigned long transferSpeed; // bytes per second

// BLE states
extern bool bleActive;
extern bool dataReceived;

// SPIFFS related globals
extern const char* IMAGE_PATH;
extern File imageFile;

// Function declarations for BLE operations
void updateTransferSpeed();
void sendAcknowledgment(uint8_t type);
void sendProgressUpdate(uint8_t progress);
extern bool spiffsReady;

// Image sizes
#define IMAGE_WIDTH  800
#define IMAGE_HEIGHT 480
#define BLE_IMAGE_SIZE (IMAGE_WIDTH * IMAGE_HEIGHT / 2) // 2 pixels per byte

// Function declarations
void startBLE();
void onBLEConnected(BLEDevice central);
void onBLEDisconnected(BLEDevice central);
void onRxCharacteristicWritten(BLEDevice central, BLECharacteristic characteristic);
void displayImageFromSPIFFS();
bool initSPIFFS();
void requestMTUIncrease();
// No periodic BLE tasks (battery sent once at start of image data)

#endif // BLE_H
