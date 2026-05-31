#include <Wire.h>
#include <BluetoothSerial.h>
#include <ageislink_inferencing.h>

// ---- YOUR BLE LIBRARIES (added) ----------------------------
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>

// ---- YOUR BLE CONSTANTS (DO NOT CHANGE) --------------------
#define SERVICE_UUID        "12345678-1234-1234-1234-1234567890ab"
#define CHARACTERISTIC_UUID "abcd1234-5678-1234-5678-abcdef123456"

BLECharacteristic *pCharacteristic;
bool bleDeviceConnected = false;

// ---- YOUR BLE SERVER CALLBACKS (added) ---------------------
class MyServerCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer* pServer) {
    bleDeviceConnected = true;
    Serial.println("[BLE] Device connected ✅");
  }
  void onDisconnect(BLEServer* pServer) {
    bleDeviceConnected = false;
    Serial.println("[BLE] Device disconnected ❌");
    BLEDevice::getAdvertising()->start();
    Serial.println("[BLE] Advertising restarted...");
  }
};

// ---- Pin Mappings (FRIEND'S - unchanged) -------------------
const int buttonPin         = 32;
const int mpuInterruptPin   = 33;
const int buzzerPin         = 25;

// ---- MPU6050 Registers (FRIEND'S - unchanged) --------------
const uint8_t MPU6050_ADDR = 0x68;

// ---- System State Machine (FRIEND'S - unchanged) -----------
enum SystemState { STATE_NORMAL, STATE_GRACE_PERIOD, STATE_ALERT_TRIGGERED };
volatile SystemState currentState = STATE_NORMAL;

// ---- Timing (FRIEND'S - unchanged) -------------------------
volatile unsigned long gracePeriodStartTime = 0;
const unsigned long GRACE_DURATION = 20000;

// ---- Flags (FRIEND'S - unchanged) --------------------------
volatile bool hardwareButtonFlag = false;
volatile bool sensorActive       = true;
volatile bool bluetoothReady     = false;

// ---- AI Inference Config (FRIEND'S - unchanged) ------------
#define ACCEL_SCALE    16384.0f
#define GYRO_SCALE     131.0f
#define CONVERT_G_MS2  9.80665f

#define CRASH_THRESHOLD          0.75f
#define SLIGHT_DISRUPT_THRESHOLD 0.60f

// ---- AI Result Cache (FRIEND'S - unchanged) ----------------
volatile float ai_crash_score    = 0.0f;
volatile float ai_normal_score   = 1.0f;
volatile float ai_disrupt_score  = 0.0f;
volatile bool  ai_crash_detected = false;
volatile bool  ai_inference_ready = false;

BluetoothSerial ESP_BT;

// ---- MPU6050 Helpers (FRIEND'S - unchanged) ----------------
void writeRegister(uint8_t reg, uint8_t value) {
    if (!sensorActive) return;
    Wire.beginTransmission(MPU6050_ADDR);
    Wire.write(reg);
    Wire.write(value);
    if (Wire.endTransmission() != 0) {
        sensorActive = false;
        Serial.println("[CRITICAL] MPU6050 Register Write Failed!");
    }
}

bool readMPU6050(float &ax, float &ay, float &az, float &gx, float &gy, float &gz) {
    Wire.beginTransmission(MPU6050_ADDR);
    Wire.write(0x3B);
    if (Wire.endTransmission(false) != 0) { sensorActive = false; return false; }
    if (Wire.requestFrom(MPU6050_ADDR, (size_t)14, true) != 14) { sensorActive = false; return false; }

    int16_t rawAx = (Wire.read() << 8) | Wire.read();
    int16_t rawAy = (Wire.read() << 8) | Wire.read();
    int16_t rawAz = (Wire.read() << 8) | Wire.read();
    Wire.read(); Wire.read();
    int16_t rawGx = (Wire.read() << 8) | Wire.read();
    int16_t rawGy = (Wire.read() << 8) | Wire.read();
    int16_t rawGz = (Wire.read() << 8) | Wire.read();

    ax = (rawAx / ACCEL_SCALE) * CONVERT_G_MS2;
    ay = (rawAy / ACCEL_SCALE) * CONVERT_G_MS2;
    az = (rawAz / ACCEL_SCALE) * CONVERT_G_MS2;
    gx = rawGx / GYRO_SCALE;
    gy = rawGy / GYRO_SCALE;
    gz = rawGz / GYRO_SCALE;
    return true;
}

void configureMPU6050() {
    writeRegister(0x6B, 0x00);
    writeRegister(0x1C, 0x00);
    writeRegister(0x1B, 0x00);
    writeRegister(0x19, 0x09);
}

// ---- Interrupt: button press (FRIEND'S - unchanged) --------
void IRAM_ATTR onButtonPress() {
    hardwareButtonFlag = true;
}

// ---- Task: Bluetooth init on Core 0 (FRIEND'S - unchanged) -
void bluetoothInitTask(void * pvParameters) {
    Serial.println("[BOOT-CORE0] Starting Bluetooth stack...");
    ESP_BT.begin("Aegis_Link_Secure");
    bluetoothReady = true;
    Serial.println("[BOOT-CORE0] Bluetooth ready!");
    vTaskDelete(NULL);
}

// ---- YOUR BLE Init Task (added on Core 0) ------------------
void bleInitTask(void * pvParameters) {
    Serial.println("[BOOT-CORE0] Starting BLE stack...");
    BLEDevice::init("ESP32_ALERT_DEVICE");
    BLEServer *pServer = BLEDevice::createServer();
    pServer->setCallbacks(new MyServerCallbacks());

    BLEService *pService = pServer->createService(SERVICE_UUID);
    pCharacteristic = pService->createCharacteristic(
                        CHARACTERISTIC_UUID,
                        BLECharacteristic::PROPERTY_READ |
                        BLECharacteristic::PROPERTY_NOTIFY
                      );
    pCharacteristic->addDescriptor(new BLE2902());
    pCharacteristic->setValue("START");
    pService->start();

    BLEAdvertising *pAdvertising = BLEDevice::getAdvertising();
    pAdvertising->addServiceUUID(SERVICE_UUID);
    pAdvertising->setScanResponse(true);
    BLEDevice::startAdvertising();

    Serial.println("[BLE] Advertising started 🚀");
    vTaskDelete(NULL);
}

// ---- Task: Edge AI Inference on Core 0 (FRIEND'S - unchanged)
void inferenceTask(void * pvParameters) {
    static float buffer[EI_CLASSIFIER_DSP_INPUT_FRAME_SIZE];

    for (;;) {
        if (!sensorActive) {
            vTaskDelay(pdMS_TO_TICKS(500));
            continue;
        }

        for (size_t ix = 0; ix < EI_CLASSIFIER_DSP_INPUT_FRAME_SIZE;
             ix += EI_CLASSIFIER_RAW_SAMPLES_PER_FRAME) {

            int64_t next_tick = (int64_t)micros() + (int64_t)(EI_CLASSIFIER_INTERVAL_MS * 1000);

            float ax, ay, az, gxv, gyv, gzv;
            if (readMPU6050(ax, ay, az, gxv, gyv, gzv)) {
                buffer[ix + 0] = ax;
                buffer[ix + 1] = ay;
                buffer[ix + 2] = az;
                buffer[ix + 3] = gxv;
                buffer[ix + 4] = gyv;
                buffer[ix + 5] = gzv;
            }

            int64_t wait_us = next_tick - (int64_t)micros();
            if (wait_us > 0) delayMicroseconds((uint32_t)wait_us);
        }

        signal_t signal;
        int err = numpy::signal_from_buffer(buffer, EI_CLASSIFIER_DSP_INPUT_FRAME_SIZE, &signal);
        if (err != 0) {
            Serial.printf("[AI] signal_from_buffer error: %d\n", err);
            continue;
        }

        ei_impulse_result_t result = { 0 };
        err = run_classifier(&signal, &result, false);
        if (err != EI_IMPULSE_OK) {
            Serial.printf("[AI] run_classifier error: %d\n", err);
            continue;
        }

        float crash_score   = result.classification[0].value;
        float normal_score  = result.classification[1].value;
        float disrupt_score = result.classification[2].value;

        ai_crash_score   = crash_score;
        ai_normal_score  = normal_score;
        ai_disrupt_score = disrupt_score;

        Serial.printf("[AI] crash=%.3f  normal=%.3f  disrupt=%.3f\n",
                      crash_score, normal_score, disrupt_score);

        ai_crash_detected  = (crash_score >= CRASH_THRESHOLD);
        ai_inference_ready = true;

        vTaskDelay(pdMS_TO_TICKS(10));
    }
}

// ---- Task: Core Engine on Core 1 (FRIEND'S - unchanged except SOS block)
void coreEngine(void * pvParameters) {
    for (;;) {
        if (!sensorActive) {
            static unsigned long lastErrorTime = 0;
            if (millis() - lastErrorTime > 5000) {
                Serial.println("[WARNING] Degraded Mode: MPU6050 disconnected.");
                lastErrorTime = millis();
            }
        }

        if (currentState == STATE_NORMAL && sensorActive && ai_inference_ready) {
            ai_inference_ready = false;

            if (ai_crash_detected) {
                Serial.printf("\n[AI-ALERT] CRASH detected! (score=%.3f) Starting countdown...\n",
                              (float)ai_crash_score);
                hardwareButtonFlag = false;
                currentState = STATE_GRACE_PERIOD;
                gracePeriodStartTime = millis();
            } else if (ai_disrupt_score >= SLIGHT_DISRUPT_THRESHOLD) {
                Serial.printf("[AI-WARN] Slight disruption (score=%.3f) — monitoring...\n",
                              (float)ai_disrupt_score);
            }
        }

        switch (currentState) {

            case STATE_NORMAL:
                digitalWrite(buzzerPin, LOW);
                if (hardwareButtonFlag) {
                    hardwareButtonFlag = false;
                    Serial.println("[INFO] Manual ping button pressed.");
                    if (bluetoothReady && ESP_BT.connected()) {
                        ESP_BT.println("PING_OK");
                    }
                }
                break;

            case STATE_GRACE_PERIOD:
                digitalWrite(buzzerPin, (millis() / 150) % 2);

                if (hardwareButtonFlag) {
                    hardwareButtonFlag = false;
                    digitalWrite(buzzerPin, LOW);
                    Serial.println("\n[SAFE] User cancelled. Returning to guard mode.");
                    ai_crash_detected = false;
                    currentState = STATE_NORMAL;
                } else if (millis() - gracePeriodStartTime >= GRACE_DURATION) {
                    currentState = STATE_ALERT_TRIGGERED;
                }
                break;

            case STATE_ALERT_TRIGGERED:
                digitalWrite(buzzerPin, HIGH);
                Serial.println("\n[ALERT] *** CRASH CONFIRMED — SENDING SOS ***");
                Serial.printf("[ALERT] Crash=%.3f | Normal=%.3f | Disrupt=%.3f\n",
                              (float)ai_crash_score, (float)ai_normal_score, (float)ai_disrupt_score);

                // FRIEND'S classic BT message (unchanged)
                if (bluetoothReady && ESP_BT.connected()) {
                    ESP_BT.println("CRASH_DETECTED_TRIGGER_SOS_LOCATION");
                } else {
                    Serial.println("[ERROR] Classic BT not connected.");
                }

                // YOUR BLE message (added) — sends "CRASH" to your Flutter app
                if (bleDeviceConnected) {
                    pCharacteristic->setValue("CRASH");
                    pCharacteristic->notify();
                    Serial.println("[BLE] Sent: CRASH");
                } else {
                    Serial.println("[BLE] Not connected! Flutter app missed the alert ⚠️");
                }

                vTaskDelay(pdMS_TO_TICKS(5000));

                Serial.println("[INFO] Resetting to guard mode.\n");
                ai_crash_detected  = false;
                ai_inference_ready = false;
                hardwareButtonFlag = false;
                currentState = STATE_NORMAL;
                break;
        }

        vTaskDelay(pdMS_TO_TICKS(10));
    }
}

// ---- setup() -----------------------------------------------
void setup() {
    Serial.begin(115200);
    delay(500);
    Serial.println("[BOOT] Aegis Link AI System initializing...");

    Wire.begin(21, 22);
    Wire.setClock(400000);
    Wire.setTimeOut(10);

    pinMode(mpuInterruptPin, INPUT);
    pinMode(buttonPin, INPUT_PULLUP);
    pinMode(buzzerPin, OUTPUT);

    configureMPU6050();
    Serial.println("[BOOT] MPU6050 configured (ax,ay,az,gx,gy,gz @ 100Hz).");
    Serial.printf("[BOOT] Model input: %d samples × %d axes = %d floats\n",
                  EI_CLASSIFIER_RAW_SAMPLE_COUNT,
                  EI_CLASSIFIER_RAW_SAMPLES_PER_FRAME,
                  EI_CLASSIFIER_DSP_INPUT_FRAME_SIZE);
    Serial.printf("[BOOT] Labels: crash | normal | slight disrupt\n");

    attachInterrupt(digitalPinToInterrupt(buttonPin), onButtonPress, FALLING);

    // Core 0: Classic BT + BLE + AI inference
    xTaskCreatePinnedToCore(bluetoothInitTask, "BT_Init",   4096, NULL, 1, NULL, 0);
    xTaskCreatePinnedToCore(bleInitTask,       "BLE_Init",  4096, NULL, 1, NULL, 0); // YOUR BLE (added)
    xTaskCreatePinnedToCore(inferenceTask,     "AI_Infer",  8192, NULL, 1, NULL, 0);

    // Core 1: state machine + buzzer + BT messaging
    xTaskCreatePinnedToCore(coreEngine,        "CoreEngine",4096, NULL, 1, NULL, 1);

    Serial.println("[BOOT] All tasks launched. System active.");
}

// ---- loop() ------------------------------------------------
void loop() {
    vTaskDelete(NULL); // All logic is in FreeRTOS tasks
}