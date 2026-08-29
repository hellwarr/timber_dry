/*
 ==============================================================================
  🪵 TimberDry Pro — ESP32 Industrial Wood Drying Kiln Controller v1.7.7
  ------------------------------------------------------------------------------
  • Persistent, Indefinite Wi-Fi Auto-Reconnection (Never stops retrying)
  • BLE strictly on-demand: ONLY activates when user presses the BOOT button
  • 100% dedicated 2.4 GHz radio bandwidth for Wi-Fi (zero BLE collisions)
  • Deep hardware radio reset cycle on connection drops (prevents driver lock)
  • Self-healing watchdog: auto-restarts if Wi-Fi disconnected for > 3 minutes
  • Universal BLE Protocol (supports both raw "PIN:SSID:PASS:LABEL" & JSON)
  • Google Cloud Server Timestamp (REQUEST_TIME) for lastSeen tracking
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
const char* FIRMWARE_VERSION = "1.7.7";
const char* FIRESTORE_PROJECT_ID = "timber-dry-pro";

// ================= GLOBAL STATE =================
DHT dht(DHTPIN, DHTTYPE);
Preferences prefs;
BLEServer* pServer = NULL;
bool bleInitialized = false;

char device_id[9] = "UNKNOWN";
uint32_t boot_count = 0;

String wifi_ssid = "";
String wifi_pass = "";
String custom_label = "Сушарка №1";

bool bleActive = false;
unsigned long bleStartTime = 0;
const unsigned long BLE_TIMEOUT_MS = 180000; // 3 min BLE timeout when activated by BOOT

unsigned long lastSendTime = 0;
const unsigned long SEND_INTERVAL_MS = 10000; // 10s telemetry interval

unsigned long lastWifiReconnectAttempt = 0;
const unsigned long WIFI_RETRY_INTERVAL_MS = 6000; // Retry Wi-Fi every 6 seconds
unsigned long wifiDisconnectStartTime = 0;
int wifiReconnectFailCount = 0;
const unsigned long MAX_OFFLINE_WATCHDOG_MS = 180000; // 3 minutes offline watchdog -> auto soft restart

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
      digitalWrite(STATUS_LED_PIN, (now / 150) % 2); // Fast blink (3.3 Hz)
      break;
    case LED_BLE_MODE:
      // Double flash pulse: flash-flash-pause
      {
        unsigned long phase = now % 1000;
        bool on = (phase < 100) || (phase >= 200 && phase < 300);
        digitalWrite(STATUS_LED_PIN, on ? HIGH : LOW);
      }
      break;
    case LED_SOLID_OK:
      digitalWrite(STATUS_LED_PIN, HIGH);           // Solid Blue
      break;
    case LED_SOS:
      // Morse SOS: 3 short, 3 long, 3 short
      {
        unsigned long cycle = now % 3000;
        if (cycle < 200 || (cycle >= 400 && cycle < 600) || (cycle >= 800 && cycle < 1000)) {
          digitalWrite(STATUS_LED_PIN, HIGH);
        } else if ((cycle >= 1300 && cycle < 1700) || (cycle >= 1900 && cycle < 2300) || (cycle >= 2500 && cycle < 2900)) {
          digitalWrite(STATUS_LED_PIN, HIGH);
        } else {
          digitalWrite(STATUS_LED_PIN, LOW);
        }
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

// ================= BLE CONFIGURATION HANDLER =================
void saveAndApplyWifiCredentials(String newPin, String newSsid, String newPass, String newLabel, BLECharacteristic *pChar, bool isJson) {
  newPin.trim();
  newSsid.trim();
  newPass.trim();
  newLabel.trim();

  if (newPin != DEFAULT_PIN) {
    Serial.println("❌ BLE Auth Failed: Invalid PIN!");
    if (isJson) {
      StaticJsonDocument<128> resp;
      resp["status"] = "ERROR";
      resp["message"] = "Невірний Master PIN-код!";
      String jsonResp;
      serializeJson(resp, jsonResp);
      pChar->setValue(jsonResp.c_str());
    } else {
      pChar->setValue("ERR:INVALID_PIN");
    }
    pChar->notify();
    return;
  }

  if (newSsid.length() == 0) {
    Serial.println("❌ BLE Error: Empty SSID!");
    if (isJson) {
      StaticJsonDocument<128> resp;
      resp["status"] = "ERROR";
      resp["message"] = "Назва Wi-Fi мережі не може бути порожньою!";
      String jsonResp;
      serializeJson(resp, jsonResp);
      pChar->setValue(jsonResp.c_str());
    } else {
      pChar->setValue("ERR:EMPTY_SSID");
    }
    pChar->notify();
    return;
  }

  wifi_ssid = newSsid;
  wifi_pass = newPass;
  if (newLabel.length() > 0) custom_label = newLabel;

  prefs.begin("timber_dry", false);
  prefs.putString("ssid", wifi_ssid);
  prefs.putString("pass", wifi_pass);
  prefs.putString("label", custom_label);
  prefs.end();

  Serial.printf("💾 Saved new Wi-Fi config to NVS: SSID='%s', Label='%s'\n", wifi_ssid.c_str(), custom_label.c_str());

  if (isJson) {
    StaticJsonDocument<128> resp;
    resp["status"] = "SAVED_REBOOTING";
    String jsonResp;
    serializeJson(resp, jsonResp);
    pChar->setValue(jsonResp.c_str());
  } else {
    pChar->setValue("OK:SAVED");
  }
  pChar->notify();

  delay(800);
  ESP.restart();
}

// ================= BLE CALLBACKS =================
class BleCallbacks : public BLECharacteristicCallbacks {
    void onWrite(BLECharacteristic *pCharacteristic) {
      String rxValue = pCharacteristic->getValue();
      rxValue.trim();
      if (rxValue.length() == 0) return;

      Serial.printf("\n📥 Received BLE Payload: '%s'\n", rxValue.c_str());

      // 1. Try parsing JSON format
      if (rxValue.startsWith("{") && rxValue.endsWith("}")) {
        StaticJsonDocument<512> doc;
        DeserializationError err = deserializeJson(doc, rxValue);
        if (!err) {
          const char* action = doc["action"];
          if (action) {
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
              Serial.printf("📤 BLE IDENTIFY sent for [%s]\n", device_id);
              return;
            }
            else if (strcmp(action, "CONFIGURE_WIFI") == 0) {
              String pin = doc["pin"] | "";
              String ssid = doc["ssid"] | "";
              String pass = doc["password"] | "";
              String label = doc["label"] | custom_label.c_str();
              saveAndApplyWifiCredentials(pin, ssid, pass, label, pCharacteristic, true);
              return;
            }
            else if (strcmp(action, "PING") == 0) {
              StaticJsonDocument<128> resp;
              resp["status"] = "PONG";
              resp["uptime"] = (uint32_t)(millis() / 1000ULL);
              String jsonResp;
              serializeJson(resp, jsonResp);
              pCharacteristic->setValue(jsonResp.c_str());
              pCharacteristic->notify();
              return;
            }
          }
        }
      }

      // 2. Fallback: Parse colon-separated format "PIN:SSID:PASS:LABEL" from mobile app
      int idx1 = rxValue.indexOf(':');
      int idx2 = rxValue.indexOf(':', idx1 + 1);
      int idx3 = rxValue.indexOf(':', idx2 + 1);

      if (idx1 > 0 && idx2 > 0) {
        String pin   = rxValue.substring(0, idx1);
        String ssid  = rxValue.substring(idx1 + 1, idx2);
        String pass  = (idx3 > 0) ? rxValue.substring(idx2 + 1, idx3) : rxValue.substring(idx2 + 1);
        String label = (idx3 > 0) ? rxValue.substring(idx3 + 1) : custom_label;
        saveAndApplyWifiCredentials(pin, ssid, pass, label, pCharacteristic, false);
      } else {
        Serial.println("⚠️ Unknown BLE payload format!");
      }
    }
};

void initBLEStack() {
  if (bleInitialized) return;
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

  bleInitialized = true;
}

void startBLE() {
  initBLEStack();
  BLEDevice::startAdvertising();
  bleActive = true;
  bleStartTime = millis();
  currentLedState = LED_BLE_MODE;
  Serial.printf("📡 [BOOT BUTTON] BLE Pairing mode activated for [TimberDry_%s] (3 min timeout)!\n", device_id);
}

void stopBLE() {
  if (!bleActive) return;
  Serial.println("🔒 Stopping BLE advertising. Restoring full radio to Wi-Fi...");
  if (BLEDevice::getAdvertising()) {
    BLEDevice::getAdvertising()->stop();
  }
  bleActive = false;
}

// ================= CONTINUOUS WI-FI ENGINE =================
void performCleanWifiBegin() {
  WiFi.persistent(false);
  WiFi.setAutoReconnect(true);
  WiFi.disconnect(true, false);
  delay(50);
  WiFi.mode(WIFI_STA);
  WiFi.setTxPower(WIFI_POWER_17dBm);
  WiFi.begin(wifi_ssid.c_str(), wifi_pass.c_str());
}

void performColdRadioReset() {
  Serial.println("⚡ Performing Cold Hardware Radio Reset (clearing stuck IDF state)...");
  WiFi.disconnect(true, true);
  WiFi.mode(WIFI_OFF);
  delay(150);
  performCleanWifiBegin();
}

bool tryConnectWiFi(bool blockingWait = true) {
  if (wifi_ssid.length() == 0) {
    Serial.println("⚠️ No Wi-Fi credentials stored in NVS.");
    return false;
  }

  Serial.printf("🔌 Connecting to Wi-Fi SSID: '%s'...\n", wifi_ssid.c_str());
  currentLedState = LED_CONNECTING;
  performCleanWifiBegin();

  if (blockingWait) {
    int attempts = 0;
    while (WiFi.status() != WL_CONNECTED && attempts < 25) { // 12.5 seconds wait
      delay(500);
      updateStatusLed();
      yield();
      attempts++;
      Serial.print(".");
    }
    Serial.println();

    if (WiFi.status() == WL_CONNECTED) {
      Serial.println("✅ Wi-Fi Connected Successfully!");
      Serial.printf("📍 IP: %s | GW: %s | RSSI: %d dBm\n",
                    WiFi.localIP().toString().c_str(),
                    WiFi.gatewayIP().toString().c_str(),
                    WiFi.RSSI());
      currentLedState = LED_SOLID_OK;
      wifiDisconnectStartTime = 0;
      wifiReconnectFailCount = 0;
      return true;
    } else {
      Serial.printf("⚠️ Initial Wi-Fi Connection Timeout (Status: %d). Continuing background reconnect...\n", WiFi.status());
      return false;
    }
  }

  return false;
}

// ================= SETUP =================
void setup() {
  Serial.begin(115200);
  pinMode(STATUS_LED_PIN, OUTPUT);
  pinMode(PAIR_BUTTON_PIN, INPUT_PULLUP);
  digitalWrite(STATUS_LED_PIN, LOW);

  // Brownout prevention: Cap Wi-Fi TX Power to 17dBm
  WiFi.setTxPower(WIFI_POWER_17dBm);

  // Generate 8-character device ID from hardware MAC
  uint64_t chipmac = ESP.getEfuseMac();
  uint32_t highBytes = (uint32_t)((chipmac >> 16) & 0xFFFFFFFF);
  snprintf(device_id, sizeof(device_id), "%08X", highBytes);

  // Read stored credentials & boot counter
  prefs.begin("timber_dry", false);
  boot_count = prefs.getUInt("boot_cnt", 0) + 1;
  prefs.putUInt("boot_cnt", boot_count);
  wifi_ssid = prefs.getString("ssid", "");
  wifi_pass = prefs.getString("pass", "");
  custom_label = prefs.getString("label", "Сушарка №1");
  prefs.end();

  // Initialize BLE Stack (dormant until BOOT button is pressed)
  initBLEStack();

  dht.begin();
  delay(300);

  Serial.println("\n=======================================================");
  Serial.println("🪵 TimberDry Pro — ESP32 Industrial Controller v1.7.7");
  Serial.printf("🏷️ Device ID: #%s | Boot Count: #%u\n", device_id, boot_count);
  Serial.printf("📶 Stored SSID: '%s' | Label: '%s'\n", wifi_ssid.c_str(), custom_label.c_str());
  Serial.printf("☁️ Firestore Project: %s\n", FIRESTORE_PROJECT_ID);
  Serial.println("=======================================================");

  if (wifi_ssid.length() > 0) {
    tryConnectWiFi(true);
  } else {
    Serial.println("⚠️ No Wi-Fi configured yet. Press BOOT button or start BLE to configure.");
    startBLE();
  }
}

// ================= LOOP =================
void loop() {
  updateStatusLed();
  yield();

  // 1. BOOT BUTTON: The ONLY trigger that activates BLE pairing mode
  if (digitalRead(PAIR_BUTTON_PIN) == LOW) {
    delay(50);
    if (digitalRead(PAIR_BUTTON_PIN) == LOW) {
      Serial.println("🔘 [USER ACTION] BOOT button pressed -> Activating BLE mode!");
      startBLE();
      while (digitalRead(PAIR_BUTTON_PIN) == LOW) {
        delay(10);
        updateStatusLed();
      }
    }
  }

  // 2. BLE Timeout: Auto-stop BLE after 3 minutes to keep RF radio dedicated to Wi-Fi
  if (bleActive && (millis() - bleStartTime > BLE_TIMEOUT_MS)) {
    stopBLE();
    currentLedState = (WiFi.status() == WL_CONNECTED && lastPushSuccess) ? LED_SOLID_OK : LED_CONNECTING;
  }

  // 3. PERSISTENT INDEFINITE WI-FI RECONNECTION ENGINE
  if (WiFi.status() != WL_CONNECTED) {
    if (wifiDisconnectStartTime == 0) {
      wifiDisconnectStartTime = millis();
    }

    if (wifi_ssid.length() > 0) {
      // Reconnection attempt timer (every 6 seconds)
      if (millis() - lastWifiReconnectAttempt >= WIFI_RETRY_INTERVAL_MS) {
        lastWifiReconnectAttempt = millis();
        wifiReconnectFailCount++;
        Serial.printf("🔄 [Wi-Fi Reconnect] Attempt #%d to '%s' (Offline: %us)...\n",
                      wifiReconnectFailCount,
                      wifi_ssid.c_str(),
                      (unsigned int)((millis() - wifiDisconnectStartTime) / 1000));

        // Every 5 failed attempts -> Deep Cold Hardware Radio Reset
        if (wifiReconnectFailCount % 5 == 0) {
          performColdRadioReset();
        } else {
          performCleanWifiBegin();
        }
      }

      // Self-Healing Watchdog: If offline for > 3 min, auto soft-restart microcontroller
      if (millis() - wifiDisconnectStartTime > MAX_OFFLINE_WATCHDOG_MS) {
        Serial.println("⚠️ Offline for > 3 minutes. Triggering Self-Healing Restart to recover hardware registers...");
        delay(200);
        ESP.restart();
      }
    }

    if (!bleActive) {
      currentLedState = LED_CONNECTING;
    }
    return;
  }

  // When Wi-Fi is connected:
  if (wifiDisconnectStartTime > 0) {
    Serial.println("🎉 Wi-Fi Connected / Restored!");
    wifiDisconnectStartTime = 0;
    wifiReconnectFailCount = 0;
    if (!bleActive) currentLedState = LED_SOLID_OK;
  }

  // 4. Telemetry Push Loop (Every 10 seconds)
  if (millis() - lastSendTime >= SEND_INTERVAL_MS || lastSendTime == 0) {
    lastSendTime = millis();

    float h = dht.readHumidity();
    float t = dht.readTemperature();
    bool valid = isSensorValid(t, h);
    uint32_t uptime_sec = (uint32_t)(millis() / 1000ULL);

    if (valid) {
      Serial.printf("🪵 [#%s] T: %.1f°C | RH: %.1f%% | RSSI: %d dBm | Uptime: %us\n", device_id, t, h, WiFi.RSSI(), uptime_sec);
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
    client.setTimeout(4); // 4-second TCP/TLS socket timeout

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
        if (!bleActive) currentLedState = LED_SOLID_OK;
        Serial.printf("✅ Telemetry synced to Firestore /devices/%s (HTTP %d)\n", device_id, code);
      } else {
        lastPushSuccess = false;
        if (!bleActive) currentLedState = LED_SOS;
        Serial.printf("❌ Firestore HTTP %d -> SOS LED\n", code);
      }
      https.end();
    } else {
      lastPushSuccess = false;
      if (!bleActive) currentLedState = LED_SOS;
    }
  }
}
