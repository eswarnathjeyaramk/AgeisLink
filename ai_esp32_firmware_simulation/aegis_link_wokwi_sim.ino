// ============================================================
// AEGIS LINK — Edge AI Crash Detection (WOKWI SIMULATION)
//
// This file runs in Wokwi. Since the Edge Impulse TFLite Micro
// library cannot compile in Wokwi's browser environment, this
// version faithfully simulates the full AI pipeline:
//
//  • Reads real MPU6050 I²C data (Wokwi simulates the sensor)
//  • Collects 150-sample × 6-axis window (1.5s @ 100Hz)
//  • Runs a simulated spectral analysis + decision tree that
//    mimics crash / normal / slight-disrupt classification
//  • All state machine, buzzer, button, and BT logic is REAL
//
// On real hardware: use aegis_link_ai_hardware.ino instead.
// ============================================================

#define SIMULATION_MODE

#include <Wire.h>
#include <BluetoothSerial.h>

// ---- Pin Mappings ------------------------------------------
const int buttonPin         = 32;
const int mpuInterruptPin   = 33;
const int buzzerPin         = 25;

// ---- MPU6050 Registers ------------------------------------
const uint8_t MPU6050_ADDR = 0x68;

// ---- System State Machine ----------------------------------
enum SystemState { STATE_NORMAL, STATE_GRACE_PERIOD, STATE_ALERT_TRIGGERED };
volatile SystemState currentState = STATE_NORMAL;

// ---- Timing ------------------------------------------------
volatile unsigned long gracePeriodStartTime = 0;
const unsigned long GRACE_DURATION = 20000;

// ---- Flags -------------------------------------------------
volatile bool hardwareButtonFlag  = false;
volatile bool sensorActive        = true;
volatile bool bluetoothReady      = false;

// ---- Model Constants (mirrors model_metadata.h) ------------
#define EI_CLASSIFIER_RAW_SAMPLE_COUNT     150
#define EI_CLASSIFIER_RAW_SAMPLES_PER_FRAME 6
#define EI_CLASSIFIER_DSP_INPUT_FRAME_SIZE (EI_CLASSIFIER_RAW_SAMPLE_COUNT * EI_CLASSIFIER_RAW_SAMPLES_PER_FRAME)
#define EI_CLASSIFIER_INTERVAL_MS          10
#define EI_CLASSIFIER_LABEL_COUNT          3

// Confidence thresholds
#define CRASH_THRESHOLD          0.75f
#define SLIGHT_DISRUPT_THRESHOLD 0.60f

// ---- IMU Scale Factors -------------------------------------
#define ACCEL_SCALE   16384.0f
#define GYRO_SCALE    131.0f
#define CONVERT_G_MS2 9.80665f

// ---- AI Result Cache ---------------------------------------
volatile float ai_crash_score    = 0.0f;
volatile float ai_normal_score   = 1.0f;
volatile float ai_disrupt_score  = 0.0f;
volatile bool  ai_crash_detected = false;
volatile bool  ai_inference_ready = false;

BluetoothSerial ESP_BT;

// ============================================================
// SIMULATED EDGE AI INFERENCE ENGINE
// Approximates Edge Impulse spectral analysis + MLP classifier
// using statistics computed over the 1.5s sample window.
// ============================================================

struct InferenceResult {
    float crash;
    float normal;
    float slight_disrupt;
};

// Compute RMS of an array
float computeRMS(float* arr, int len) {
    float sum = 0;
    for (int i = 0; i < len; i++) sum += arr[i] * arr[i];
    return sqrt(sum / len);
}

// Compute peak-to-peak range
float computeRange(float* arr, int len) {
    float mn = arr[0], mx = arr[0];
    for (int i = 1; i < len; i++) {
        if (arr[i] < mn) mn = arr[i];
        if (arr[i] > mx) mx = arr[i];
    }
    return mx - mn;
}

// Compute magnitude of 3D vector array
float computeVectorMag(float* x, float* y, float* z, int len) {
    float sum = 0;
    for (int i = 0; i < len; i++) {
        float m = sqrt(x[i]*x[i] + y[i]*y[i] + z[i]*z[i]);
        sum += m;
    }
    return sum / len;
}

// Simulated spectral energy (variance proxy)
float computeVariance(float* arr, int len) {
    float mean = 0;
    for (int i = 0; i < len; i++) mean += arr[i];
    mean /= len;
    float var = 0;
    for (int i = 0; i < len; i++) {
        float d = arr[i] - mean;
        var += d * d;
    }
    return var / len;
}

// The main simulated inference function
// buffer layout: [ax0,ay0,az0,gx0,gy0,gz0, ax1,ay1,az1,gx1,gy1,gz1, ...]
InferenceResult runSimulatedInference(float* buffer, int total_len) {
    int n = total_len / EI_CLASSIFIER_RAW_SAMPLES_PER_FRAME; // = 150

    // De-interleave axes
    static float ax[150], ay[150], az[150], gx[150], gy[150], gz[150];
    for (int i = 0; i < n; i++) {
        int base = i * EI_CLASSIFIER_RAW_SAMPLES_PER_FRAME;
        ax[i] = buffer[base + 0];
        ay[i] = buffer[base + 1];
        az[i] = buffer[base + 2];
        gx[i] = buffer[base + 3];
        gy[i] = buffer[base + 4];
        gz[i] = buffer[base + 5];
    }

    // Extract features (mirrors spectral analysis block)
    float rms_ax   = computeRMS(ax, n);
    float rms_ay   = computeRMS(ay, n);
    float rms_az   = computeRMS(az, n);
    float rms_gx   = computeRMS(gx, n);
    float rms_gy   = computeRMS(gy, n);
    float rms_gz   = computeRMS(gz, n);

    float range_ax = computeRange(ax, n);
    float range_ay = computeRange(ay, n);
    float range_az = computeRange(az, n);
    float range_g  = computeRange(gx, n) + computeRange(gy, n) + computeRange(gz, n);

    float var_accel = computeVariance(ax, n) + computeVariance(ay, n) + computeVariance(az, n);
    float var_gyro  = computeVariance(gx, n) + computeVariance(gy, n) + computeVariance(gz, n);

    float accel_mag = computeVectorMag(ax, ay, az, n);
    float gyro_mag  = computeVectorMag(gx, gy, gz, n);

    // ---- Simulated Decision Logic --------------------------
    // Tuned to match typical crash / normal / slight-disrupt signatures:
    //  CRASH:          high accel_mag (>20), high range_ax/ay (>15), high var_gyro
    //  SLIGHT DISRUPT: moderate accel (8-20), moderate variance
    //  NORMAL:         low accel_mag (<8), low variance, stable orientation

    float crash_score   = 0.0f;
    float disrupt_score = 0.0f;
    float normal_score  = 0.0f;

    // --- Crash indicators ---
    if (accel_mag > 20.0f)    crash_score += 0.35f;
    else if (accel_mag > 12.0f) crash_score += 0.15f;

    if (range_ax > 15.0f || range_ay > 15.0f || range_az > 15.0f)
        crash_score += 0.25f;

    if (var_accel > 50.0f)    crash_score += 0.20f;
    else if (var_accel > 20.0f) crash_score += 0.10f;

    if (var_gyro > 100.0f)    crash_score += 0.15f;
    else if (var_gyro > 30.0f)  crash_score += 0.05f;

    if (gyro_mag > 50.0f)     crash_score += 0.05f;

    crash_score = constrain(crash_score, 0.0f, 0.97f);

    // --- Slight disrupt indicators ---
    if (crash_score < 0.5f) {
        if (accel_mag > 4.0f && accel_mag <= 12.0f)
            disrupt_score += 0.40f;
        if (var_accel > 2.0f && var_accel <= 20.0f)
            disrupt_score += 0.30f;
        if (range_g > 3.0f && range_g <= 30.0f)
            disrupt_score += 0.20f;
        if (gyro_mag > 5.0f && gyro_mag <= 50.0f)
            disrupt_score += 0.10f;
        disrupt_score = constrain(disrupt_score, 0.0f, 0.90f);
    }

    // --- Normal fills the rest ---
    // Softmax-like normalization
    float total = crash_score + disrupt_score;
    if (total < 0.01f) {
        normal_score  = 0.97f;
        crash_score   = 0.015f;
        disrupt_score = 0.015f;
    } else if (crash_score >= 0.75f) {
        // Clear crash: redistribute residual
        normal_score  = 1.0f - crash_score - disrupt_score * 0.3f;
        disrupt_score = disrupt_score * 0.3f;
        normal_score  = constrain(normal_score, 0.01f, 1.0f);
    } else if (disrupt_score >= 0.6f) {
        normal_score = 1.0f - disrupt_score - crash_score;
        normal_score = constrain(normal_score, 0.01f, 1.0f);
    } else {
        normal_score  = 1.0f - crash_score - disrupt_score;
        normal_score  = constrain(normal_score, 0.01f, 1.0f);
    }

    // Final normalize to sum = 1
    float sum = crash_score + disrupt_score + normal_score;
    InferenceResult res;
    res.crash          = crash_score   / sum;
    res.slight_disrupt = disrupt_score / sum;
    res.normal         = normal_score  / sum;
    return res;
}

// ---- MPU6050 Setup -----------------------------------------
void writeRegister(uint8_t reg, uint8_t value) {
    if (!sensorActive) return;
    Wire.beginTransmission(MPU6050_ADDR);
    Wire.write(reg);
    Wire.write(value);
    if (Wire.endTransmission() != 0) {
        sensorActive = false;
        Serial.println("[CRITICAL] MPU6050 Write Failed!");
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
    Wire.read(); Wire.read(); // temperature
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
    writeRegister(0x6B, 0x00); // Wake up
    writeRegister(0x1C, 0x00); // Accel ±2g
    writeRegister(0x1B, 0x00); // Gyro ±250°/s
}

// ---- Interrupt: button -------------------------------------
void IRAM_ATTR onButtonPress() {
    hardwareButtonFlag = true;
}

// ---- Task: Bluetooth (Core 0) ------------------------------
void bluetoothInitTask(void * pvParameters) {
    Serial.println("[BOOT-CORE0] [SIM] Emulating Bluetooth stack...");
    vTaskDelay(pdMS_TO_TICKS(100));
    bluetoothReady = true;
    Serial.println("[BOOT-CORE0] Bluetooth ready (simulation).");
    vTaskDelete(NULL);
}

// ---- Task: AI Inference (Core 0) ---------------------------
void inferenceTask(void * pvParameters) {
    static float buffer[EI_CLASSIFIER_DSP_INPUT_FRAME_SIZE]; // 900 floats

    for (;;) {
        if (!sensorActive) {
            vTaskDelay(pdMS_TO_TICKS(500));
            continue;
        }

        // Collect 150 samples at 100Hz (10ms each)
        for (int ix = 0; ix < EI_CLASSIFIER_DSP_INPUT_FRAME_SIZE;
             ix += EI_CLASSIFIER_RAW_SAMPLES_PER_FRAME) {

            int64_t next_tick = (int64_t)micros() + (int64_t)(EI_CLASSIFIER_INTERVAL_MS * 1000);

            float axv, ayv, azv, gxv, gyv, gzv;
            if (readMPU6050(axv, ayv, azv, gxv, gyv, gzv)) {
                buffer[ix + 0] = axv;
                buffer[ix + 1] = ayv;
                buffer[ix + 2] = azv;
                buffer[ix + 3] = gxv;
                buffer[ix + 4] = gyv;
                buffer[ix + 5] = gzv;
            }

            int64_t wait_us = next_tick - (int64_t)micros();
            if (wait_us > 0) delayMicroseconds((uint32_t)wait_us);
        }

        // Run simulated classifier
        InferenceResult result = runSimulatedInference(buffer, EI_CLASSIFIER_DSP_INPUT_FRAME_SIZE);

        ai_crash_score   = result.crash;
        ai_normal_score  = result.normal;
        ai_disrupt_score = result.slight_disrupt;

        Serial.printf("[AI-SIM] crash=%.3f  normal=%.3f  disrupt=%.3f\n",
                      result.crash, result.normal, result.slight_disrupt);

        ai_crash_detected = (result.crash >= CRASH_THRESHOLD);
        ai_inference_ready = true;

        vTaskDelay(pdMS_TO_TICKS(10));
    }
}

// ---- Task: Core Engine (Core 1) ----------------------------
void coreEngine(void * pvParameters) {
    for (;;) {
        if (!sensorActive) {
            static unsigned long lastErrTime = 0;
            if (millis() - lastErrTime > 5000) {
                Serial.println("[WARNING] Degraded mode: MPU6050 disconnected.");
                lastErrTime = millis();
            }
        }

        // AI result → trigger grace period
        if (currentState == STATE_NORMAL && sensorActive && ai_inference_ready) {
            ai_inference_ready = false;
            if (ai_crash_detected) {
                Serial.printf("\n[AI-ALERT] CRASH detected! (confidence=%.1f%%) — countdown started.\n",
                              (float)ai_crash_score * 100.0f);
                hardwareButtonFlag  = false;
                currentState        = STATE_GRACE_PERIOD;
                gracePeriodStartTime = millis();
            } else if (ai_disrupt_score >= SLIGHT_DISRUPT_THRESHOLD) {
                Serial.printf("[AI-WARN] Slight disruption detected (%.1f%%) — monitoring.\n",
                              (float)ai_disrupt_score * 100.0f);
            }
        }

        switch (currentState) {

            case STATE_NORMAL:
                digitalWrite(buzzerPin, LOW);
                if (hardwareButtonFlag) {
                    hardwareButtonFlag = false;
                    Serial.println("[INFO] Manual ping. System OK.");
                    #ifdef SIMULATION_MODE
                        Serial.println("[VIRTUAL_BT] >> PING_OK");
                    #else
                        if (bluetoothReady && ESP_BT.connected()) ESP_BT.println("PING_OK");
                    #endif
                }
                break;

            case STATE_GRACE_PERIOD:
                digitalWrite(buzzerPin, (millis() / 150) % 2);

                if (hardwareButtonFlag) {
                    hardwareButtonFlag = false;
                    digitalWrite(buzzerPin, LOW);
                    Serial.println("\n[SAFE] Alert cancelled by user. Back to guard mode.");
                    ai_crash_detected = false;
                    currentState = STATE_NORMAL;
                } else if (millis() - gracePeriodStartTime >= GRACE_DURATION) {
                    currentState = STATE_ALERT_TRIGGERED;
                }
                break;

            case STATE_ALERT_TRIGGERED:
                digitalWrite(buzzerPin, HIGH);
                Serial.println("\n[ALERT] *** CRASH CONFIRMED — BROADCASTING SOS ***");
                Serial.printf("[ALERT] crash=%.3f | normal=%.3f | disrupt=%.3f\n",
                              (float)ai_crash_score, (float)ai_normal_score, (float)ai_disrupt_score);

                #ifdef SIMULATION_MODE
                    Serial.println("[VIRTUAL_BT] >> CRASH_DETECTED_TRIGGER_SOS_LOCATION");
                    Serial.println("[SIM] Holding alert for 5 seconds...");
                #else
                    if (bluetoothReady && ESP_BT.connected()) {
                        ESP_BT.println("CRASH_DETECTED_TRIGGER_SOS_LOCATION");
                    } else {
                        Serial.println("[ERROR] BT not connected.");
                    }
                #endif

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
    Serial.println("[BOOT] Aegis Link AI System (Wokwi Simulation)");
    Serial.println("[BOOT] Model: crash | normal | slight disrupt");
    Serial.printf( "[BOOT] Window: %d samples × %d axes @ %dHz\n",
                   EI_CLASSIFIER_RAW_SAMPLE_COUNT,
                   EI_CLASSIFIER_RAW_SAMPLES_PER_FRAME,
                   1000 / EI_CLASSIFIER_INTERVAL_MS);

    Wire.begin(21, 22);
    Wire.setClock(400000);
    Wire.setTimeOut(10);

    pinMode(mpuInterruptPin, INPUT);
    pinMode(buttonPin, INPUT_PULLUP);
    pinMode(buzzerPin, OUTPUT);

    configureMPU6050();
    Serial.println("[BOOT] MPU6050 configured.");

    attachInterrupt(digitalPinToInterrupt(buttonPin), onButtonPress, FALLING);

    xTaskCreatePinnedToCore(bluetoothInitTask, "BT_Init",   4096, NULL, 1, NULL, 0);
    xTaskCreatePinnedToCore(inferenceTask,     "AI_Infer",  8192, NULL, 1, NULL, 0);
    xTaskCreatePinnedToCore(coreEngine,        "CoreEngine",4096, NULL, 1, NULL, 1);

    Serial.println("[BOOT] System active. Monitoring started.\n");
}

// ---- loop() ------------------------------------------------
void loop() {
    vTaskDelete(NULL);
}
