/*
 ==============================================================================
  🪵 TimberDry Pro — ESP32 Industrial Wood Drying Kiln Controller v1.7.4
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
const char* FIRMWARE_VERSION = "1.7.4";
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
const unsigned long BLE_TIMEOUT_MS = 180000; // 3 min BLE timeout

unsigned long lastSendTime = 0;
const unsigned long SEND_INTERVAL_MS = 10000; // 10s telemetry interval

enum LedState {
  LED_CONNECTING,
  LED_BLE_MODE,
  LED_SOLID_OK,
  LED_SOS
};

LedState currentLedState = LED_CONNECTING;
bool lastPushSuccess = false;

// ================= STATUS LED ROUTINE =================
void updateStatusLed() {
  unsigned long now = millis();
  switch (currentLedState) {
    case LED_CONNECTING:
      digitalWrite(STATUS_LED_PIN, (now / 200) % 2); // Fast blink (2.5 Hz)
      break;
    case LED_BLE_MODE:
      digitalWrite(STATUS_LED_PIN, (now / 600) % 2); // Slow blink (0.8 Hz)
      break;
    case LED_SOLID_OK:
      digitalWrite(STATUS_LED_PIN, HIGH);           // Solid Blue
      break;
    case LED_SOS:
      // SOS: 3 short, 3 long, 3 short
      unsigned long cycle = now % 3000;
      if (cycle < 200 || (cycle >= 400 && cycle < 600) || (cycle >= 800 && cycle < 1000)) {
        digitalWrite(STATUS_LED_PIN, HIGH);
      } else if ((cycle >= 1300 && cycle < 1700) || (cycle >= 1900 && cycle < 2300) || (cycle >= 2500 && cycle < 2900)) {
        digitalWrite(STATUS_LED_PIN, HIGH);
      } else {
        digitalWrite(STATUS_LED_PIN, LOW);
      }
      break;
  }
}

// ================= SENSOR VALIDATION =================
bool isSensorValid(float t, float h) {
  if (isnan(t) || isnan(h)) return false;
  if (t < -20.0 || t > 110.0) return false;
  if (h < 1.0 || h > 100.0) return false;
  return true;
}

// ================= BLE CALLBACKS =================
class BleCallbacks : public BLECharacteristicCallbacks {
    void onWrite(BLECharacteristic *pCharacteristic) {
      String rxValue = pCharacteristic->getValue();
      if (rxValue.length() == 0) return;

      Serial.println("\n📥 Received BLE Command payload...");
      StaticJsonDocument<512> doc;
      DeserializationError err = deserializeJson(doc, rxValue);
      if (err) {
        Serial.printf("❌ JSON Parse Error: %s\n", err.c_str());
        return;
      }

      const char* action = doc["action"];
      if (!action) return;

      if (strcmp(action, "IDENTIFY") == 0) {
        StaticJsonDocument<256> resp;
        resp["status"] = "OK";
        resp["deviceId"] = device_id;
        resp["firmware"] = FIRMWARE_VERSION;
        resp["label"] = custom_label;
        resp["wifiConfigured"] = (wifi_ssid.length() > 0);
        resp["sensorOk"] = isSensorValid(dht.readTemperature(), dht.readHumidity());

        String jsonResp;
        serializeJson(resp, jsonResp);
        pCharacteristic->setValue(jsonResp.c_str());
        pCharacteristic->notify();
        Serial.printf("📤 BLE IDENTIFY response sent for [%s]\n", device_id);
      }
      else if (strcmp(action, "CONFIGURE_WIFI") == 0) {
        const char* pin = doc["pin"];
        if (!pin || strcmp(pin, DEFAULT_PIN) != 0) {
          StaticJsonDocument<128> resp;
          resp["status"] = "ERROR";
          resp["message"] = "Невірний Master PIN-код!";
          String jsonResp;
          serializeJson(resp, jsonResp);
          pCharacteristic->setValue(jsonResp.c_str());
          pCharacteristic->notify();
          Serial.println("❌ Authentication failed (Wrong PIN)");
          return;
        }

        const char* ssid = doc["ssid"];
        const char* pass = doc["password"];
        const char* label = doc["label"];

        if (ssid && strlen(ssid) > 0) {
          wifi_ssid = String(ssid);
          wifi_pass = pass ? String(pass) : "";
          if (label && strlen(label) > 0) custom_label = String(label);

          prefs.begin("timber_dry", false);
          prefs.putString("ssid", wifi_ssid);
          prefs.putString("pass", wifi_pass);
          prefs.putString("label", custom_label);
          prefs.end();

          Serial.printf("💾 Saved new Wi-Fi credentials: SSID='%s', Label='%s'\n", wifi_ssid.c_str(), custom_label.c_str());

          StaticJsonDocument<128> resp;
          resp["status"] = "SAVED_REBOOTING";
          String jsonResp;
          serializeJson(resp, jsonResp);
          pCharacteristic->setValue(jsonResp.c_str());
          pCharacteristic->notify();

          delay(1000);
          ESP.restart();
        }
      }
      else if (strcmp(action, "PING") == 0) {
        StaticJsonDocument<128> resp;
        resp["status"] = "PONG";
        resp["uptime"] = (uint32_t)(millis() / 1000ULL);
        String jsonResp;
        serializeJson(resp, jsonResp);
        pCharacteristic->setValue(jsonResp.c_str());
        pCharacteristic->notify();
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

  // Brownout prevention: Cap Wi-Fi TX Power to 17dBm (avoids 500mA surge on thin USB cables)
  WiFi.setTxPower(WIFI_POWER_17dBm);

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
      yield();
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
  yield();

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

      // Build Atomic Firestore Commit with Server Timestamp transform for lastSeen
      StaticJsonDocument<768> doc;
      JsonArray writes = doc.createNestedArray("writes");
      JsonObject write0 = writes.createNestedObject();

      JsonObject update = write0.createNestedObject("update");
      update["name"] = "projects/" + String(FIRESTORE_PROJECT_ID) + "/databases/(default)/documents/devices/" + String(device_id);
      JsonObject fields = update.createNestedObject("fields");

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

      JsonObject updateMask = write0.createNestedObject("updateMask");
      JsonArray fieldPaths = updateMask.createNestedArray("fieldPaths");
      fieldPaths.add("deviceId");
      fieldPaths.add("label");
      fieldPaths.add("sensorConnected");
      fieldPaths.add("sensorStatus");
      fieldPaths.add("uptimeSeconds");
      fieldPaths.add("bootCount");
      fieldPaths.add("wifiSsid");
      fieldPaths.add("ipAddress");
      fieldPaths.add("rssi");
      fieldPaths.add("firmwareVersion");
      fieldPaths.add("isOnline");
      if (valid) {
        fieldPaths.add("currentTemp");
        fieldPaths.add("currentHumidity");
      }

      // Automatic Google Cloud Server Timestamp for lastSeen
      JsonArray updateTransforms = write0.createNestedArray("updateTransforms");
      JsonObject transformLastSeen = updateTransforms.createNestedObject();
      transformLastSeen["fieldPath"] = "lastSeen";
      transformLastSeen["setToServerValue"] = "REQUEST_TIME";

      String payload;
      serializeJson(doc, payload);

      WiFiClientSecure client;
      client.setInsecure();
      client.setTimeout(4); // 4-second TCP/TLS socket timeout (prevents Task Watchdog lockup)

      HTTPClient https;
      https.setTimeout(4500); // 4.5-second HTTP request timeout
      https.setReuse(false);

      String endpoint = "https://firestore.googleapis.com/v1/projects/" + String(FIRESTORE_PROJECT_ID) +
                        "/databases/(default)/documents:commit";

      if (https.begin(client, endpoint)) {
        https.addHeader("Content-Type", "application/json");
        int code = https.POST(payload);
        if (code >= 200 && code < 300) {
          lastPushSuccess = true;
          currentLedState = LED_SOLID_OK;
          Serial.printf("✅ Telemetry + Server Timestamp synced to Firestore /devices/%s (HTTP %d)\n", device_id, code);
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
