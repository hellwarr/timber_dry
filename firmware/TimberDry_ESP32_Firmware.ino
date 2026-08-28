/*
 ==============================================================================
  🪵 TimberDry Pro — ESP32 Industrial Wood Drying Kiln Controller v1.7.3
 ==============================================================================
*/

#include <WiFi.h>
#include <HTTPClient.h>
#include <WiFiClientSecure.h>
#include <ArduinoJson.h>
#include <Preferences.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>
#include "DHT.h"

// ================= HARDWARE PINS =================
#define DHTPIN 15           // DHT22 Data pin
#define DHTTYPE DHT22      // DHT22 (AM2302)
#define PAIR_BUTTON_PIN 0  // BOOT button (GPIO 0)
#define STATUS_LED_PIN 2   // Built-in Blue LED (GPIO 2)

// ================= BLE CONFIG & UUIDs =================
#define SERVICE_UUID        "4fafc201-1fb5-459e-8fcc-c5c9c331914b"
#define CHARACTERISTIC_UUID "beb5483e-36e1-4688-b7f5-ea07361b26a8"

const char* DEFAULT_PIN = "196711";
const char* FIRMWARE_VERSION = "1.7.3";
const char* FIRESTORE_PROJECT_ID = "timber-dry-pro";

// ================= GLOBAL STATE =================
DHT dht(DHTPIN, DHTTYPE);
Preferences prefs;
BLEServer* pServer = NULL;

char device_id[9] = "UNKNOWN";
uint32_t boot_count = 0;

String wifi_ssid = "";
String wifi_pass = "";
String custom_label = "Сушарка №1";

bool bleActive = false;
unsigned long bleStartTime = 0;
const unsigned long BLE_TIMEOUT_MS = 300000; // 5 minutes

enum LedState {
  LED_CONNECTING,
  LED_SOS,
  LED_SOLID_OK,
  LED_BLE_MODE
};

LedState currentLedState = LED_BLE_MODE;
unsigned long lastLedUpdate = 0;

const unsigned long SEND_INTERVAL_MS = 10000; // 10 seconds
unsigned long lastSendTime = 0;
bool lastPushSuccess = false;

// ================= SENSOR VALIDATION =================
bool isSensorValid(float t, float h) {
  if (isnan(t) || isnan(h) || isinf(t) || isinf(h)) return false;
  if (t < -20.0 || t > 115.0) return false;
  if (h < 0.5 || h > 100.0) return false;
  return true;
}

// ================= NON-BLOCKING LED D2 CONTROLLER =================
void updateStatusLed() {
  unsigned long now = millis();

  switch (currentLedState) {
    case LED_SOLID_OK:
      digitalWrite(STATUS_LED_PIN, HIGH);
      break;

    case LED_CONNECTING:
      if (now - lastLedUpdate >= 250) {
        lastLedUpdate = now;
        digitalWrite(STATUS_LED_PIN, !digitalRead(STATUS_LED_PIN));
      }
      break;

    case LED_BLE_MODE:
      // Double pulse: 80ms ON, 120ms OFF, 80ms ON, 720ms OFF
      {
        unsigned long phase = now % 1000;
        if (phase < 80 || (phase >= 200 && phase < 280)) {
          digitalWrite(STATUS_LED_PIN, HIGH);
        } else {
          digitalWrite(STATUS_LED_PIN, LOW);
        }
      }
      break;

    case LED_SOS:
      // Morse SOS: ... --- ...
      {
        unsigned long phase = now % 4600;
        bool ledOn = false;
        if (phase < 900) {
          unsigned long sub = phase % 300;
          ledOn = (sub < 150);
        } else if (phase >= 900 && phase < 2700) {
          unsigned long sub = (phase - 900) % 600;
          ledOn = (sub < 450);
        } else if (phase >= 2700 && phase < 3600) {
          unsigned long sub = (phase - 2700) % 300;
          ledOn = (sub < 150);
        } else {
          ledOn = false;
        }
        digitalWrite(STATUS_LED_PIN, ledOn ? HIGH : LOW);
      }
      break;
  }
}

// ================= BLE CALLBACKS =================
class BleCallbacks: public BLECharacteristicCallbacks {
    void onWrite(BLECharacteristic *pCharacteristic) {
      String value = pCharacteristic->getValue();
      if (value.length() > 0) {
        Serial.print("BLE Received: ");
        Serial.println(value);

        int idx1 = value.indexOf(':');
        int idx2 = value.indexOf(':', idx1 + 1);
        int idx3 = value.indexOf(':', idx2 + 1);

        if (idx1 > 0 && idx2 > 0) {
          String pin   = value.substring(0, idx1);
          String ssid  = value.substring(idx1 + 1, idx2);
          String pass  = (idx3 > 0) ? value.substring(idx2 + 1, idx3) : value.substring(idx2 + 1);
          String label = (idx3 > 0) ? value.substring(idx3 + 1) : "Сушарка";

          if (pin == DEFAULT_PIN) {
            Serial.println("✅ PIN correct! Saving Wi-Fi config to NVS...");
            prefs.begin("timber_dry", false);
            prefs.putString("ssid", ssid);
            prefs.putString("pass", pass);
            prefs.putString("label", label);
            prefs.end();

            pCharacteristic->setValue("OK:SAVED");
            pCharacteristic->notify();
            delay(800);
            ESP.restart();
          } else {
            Serial.println("❌ Invalid PIN! Config rejected.");
            pCharacteristic->setValue("ERR:INVALID_PIN");
            pCharacteristic->notify();
          }
        }
      }
    }
};

void startBLE() {
  if (bleActive) return;
  Serial.printf("📡 Starting BLE for Device [%s]...\n", device_id);

  String bleName = "TimberDry_" + String(device_id);
  BLEDevice::init(bleName.c_str());
  pServer = BLEDevice::createServer();
  BLEService *pService = pServer->createService(SERVICE_UUID);
  BLECharacteristic *pCharacteristic = pService->createCharacteristic(
                                         CHARACTERISTIC_UUID,
                                         BLECharacteristic::PROPERTY_READ |
                                         BLECharacteristic::PROPERTY_WRITE |
                                         BLECharacteristic::PROPERTY_NOTIFY
                                       );
  pCharacteristic->setCallbacks(new BleCallbacks());
  pCharacteristic->addDescriptor(new BLE2902());
  pService->start();

  BLEAdvertising *pAdvertising = BLEDevice::getAdvertising();
  pAdvertising->addServiceUUID(SERVICE_UUID);
  pAdvertising->setScanResponse(true);

  BLEAdvertisementData advData;
  advData.setFlags(0x06); // General Discoverable + BR/EDR Not Supported
  advData.setCompleteServices(BLEUUID(SERVICE_UUID));
  String mfgData = "TD:" + String(device_id);
  advData.setManufacturerData(mfgData.c_str());
  pAdvertising->setAdvertisementData(advData);

  BLEAdvertisementData scanResponseData;
  scanResponseData.setName(bleName.c_str());
  pAdvertising->setScanResponseData(scanResponseData);

  BLEDevice::startAdvertising();

  bleActive = true;
  bleStartTime = millis();
  currentLedState = LED_BLE_MODE;
  Serial.println("✅ BLE Advertising active! Waiting for app connection...");
}

void stopBLE() {
  if (!bleActive) return;
  Serial.println("🔒 Stopping BLE and releasing RAM...");
  BLEDevice::deinit(true);
  bleActive = false;
}

// ================= SETUP =================
void setup() {
  Serial.begin(115200);
  pinMode(STATUS_LED_PIN, OUTPUT);
  pinMode(PAIR_BUTTON_PIN, INPUT_PULLUP);
  digitalWrite(STATUS_LED_PIN, LOW);

  // Generate 8-character device ID from hardware MAC
  uint64_t chipmac = ESP.getEfuseMac();
  uint32_t highBytes = (uint32_t)((chipmac >> 16) & 0xFFFFFFFF);
  snprintf(device_id, sizeof(device_id), "%08X", highBytes);

  // Track Boot Count
  prefs.begin("timber_dry", false);
  boot_count = prefs.getUInt("boot_cnt", 0) + 1;
  prefs.putUInt("boot_cnt", boot_count);
  wifi_ssid = prefs.getString("ssid", "");
  wifi_pass = prefs.getString("pass", "");
  custom_label = prefs.getString("label", "Сушарка №1");
  prefs.end();

  dht.begin();
  delay(300);

  Serial.println("\n=======================================================");
  Serial.println("🪵 TimberDry Pro — ESP32 Industrial Controller");
  Serial.printf("🏷️ Device ID: #%s | Boot Count: #%u | FW: %s\n", device_id, boot_count, FIRMWARE_VERSION);
  Serial.printf("☁️ Firestore Project: %s\n", FIRESTORE_PROJECT_ID);
  Serial.println("=======================================================");

  if (wifi_ssid.length() > 0) {
    Serial.printf("Connecting to Wi-Fi '%s'...\n", wifi_ssid.c_str());
    currentLedState = LED_CONNECTING;
    WiFi.mode(WIFI_STA);
    WiFi.begin(wifi_ssid.c_str(), wifi_pass.c_str());

    int attempts = 0;
    while (WiFi.status() != WL_CONNECTED && attempts < 25) {
      delay(200);
      updateStatusLed();
      attempts++;
    }

    if (WiFi.status() == WL_CONNECTED) {
      Serial.println("\n✅ Wi-Fi Connected!");
      Serial.printf("📍 IP: %s | SSID: %s | RSSI: %d dBm\n",
                    WiFi.localIP().toString().c_str(), wifi_ssid.c_str(), WiFi.RSSI());
      currentLedState = LED_SOLID_OK;
      return;
    }
  }

  // If no Wi-Fi credentials or failed, start BLE
  startBLE();
}

// ================= LOOP =================
void loop() {
  updateStatusLed();

  // Press BOOT button to start BLE mode anytime
  if (digitalRead(PAIR_BUTTON_PIN) == LOW) {
    delay(50);
    if (digitalRead(PAIR_BUTTON_PIN) == LOW) {
      startBLE();
    }
  }

  // Auto-disable BLE after timeout
  if (bleActive && (millis() - bleStartTime > BLE_TIMEOUT_MS)) {
    stopBLE();
    currentLedState = (WiFi.status() == WL_CONNECTED && lastPushSuccess) ? LED_SOLID_OK : LED_SOS;
  }

  // Telemetry Send Loop
  if (WiFi.status() == WL_CONNECTED) {
    if (millis() - lastSendTime >= SEND_INTERVAL_MS || lastSendTime == 0) {
      lastSendTime = millis();

      float h = dht.readHumidity();
      float t = dht.readTemperature();
      bool valid = isSensorValid(t, h);
      uint32_t uptime_sec = (uint32_t)(millis() / 1000ULL);

      if (valid) {
        Serial.printf("🪵 [#%s] T: %.1f°C | RH: %.1f%% | Uptime: %us\n", device_id, t, h, uptime_sec);
      } else {
        Serial.printf("⚠️ [#%s] SENSOR DISCONNECTED! Uptime: %us\n", device_id, uptime_sec);
      }

      StaticJsonDocument<384> doc;
      JsonObject fields = doc.createNestedObject("fields");

      fields["deviceId"]["stringValue"] = device_id;
      fields["label"]["stringValue"] = custom_label;
      fields["sensorConnected"]["booleanValue"] = valid;
      fields["sensorStatus"]["stringValue"] = valid ? "OK" : "DISCONNECTED";
      fields["uptimeSeconds"]["integerValue"] = uptime_sec;
      fields["bootCount"]["integerValue"] = boot_count;
      fields["wifiSsid"]["stringValue"] = wifi_ssid;
      fields["ipAddress"]["stringValue"] = WiFi.localIP().toString();
      fields["rssi"]["integerValue"] = WiFi.RSSI();
      fields["firmwareVersion"]["stringValue"] = FIRMWARE_VERSION;
      fields["isOnline"]["booleanValue"] = true;

      if (valid) {
        fields["currentTemp"]["doubleValue"] = t;
        fields["currentHumidity"]["doubleValue"] = h;
      }

      String payload;
      serializeJson(doc, payload);

      WiFiClientSecure client;
      client.setInsecure();
      HTTPClient https;

      String updateMask = "updateMask.fieldPaths=deviceId"
                          "&updateMask.fieldPaths=label"
                          "&updateMask.fieldPaths=sensorConnected"
                          "&updateMask.fieldPaths=sensorStatus"
                          "&updateMask.fieldPaths=uptimeSeconds"
                          "&updateMask.fieldPaths=bootCount"
                          "&updateMask.fieldPaths=wifiSsid"
                          "&updateMask.fieldPaths=ipAddress"
                          "&updateMask.fieldPaths=rssi"
                          "&updateMask.fieldPaths=firmwareVersion"
                          "&updateMask.fieldPaths=isOnline";

      if (valid) {
        updateMask += "&updateMask.fieldPaths=currentTemp"
                      "&updateMask.fieldPaths=currentHumidity";
      }

      String endpoint = "https://firestore.googleapis.com/v1/projects/" + String(FIRESTORE_PROJECT_ID) +
                        "/databases/(default)/documents/devices/" + String(device_id) +
                        "?" + updateMask;

      if (https.begin(client, endpoint)) {
        https.addHeader("Content-Type", "application/json");
        int code = https.PATCH(payload);
        if (code >= 200 && code < 300) {
          lastPushSuccess = true;
          currentLedState = LED_SOLID_OK;
          Serial.printf("✅ Telemetry synced to Firestore /devices/%s (HTTP %d)\n", device_id, code);
          if (bleActive) stopBLE();
        } else {
          lastPushSuccess = false;
          currentLedState = LED_SOS;
          Serial.printf("❌ Firestore HTTP %d -> SOS LED\n", code);
        }
        https.end();
      } else {
        lastPushSuccess = false;
        currentLedState = LED_SOS;
      }
    }
  } else {
    if (wifi_ssid.length() > 0 && !bleActive) {
      currentLedState = LED_CONNECTING;
      WiFi.reconnect();
    }
  }
}
