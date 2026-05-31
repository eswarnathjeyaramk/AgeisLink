#include <Wire.h>

// --- Configuration Constants ---
#define SAMPLE_RATE_HZ 100
#define SAMPLE_INTERVAL_MS (1000 / SAMPLE_RATE_HZ) // Exactly 10ms for 100Hz streaming
#define INITIAL_WARMUP_DELAY_MS 2000               // 2-second hands-clear stabilization window

// --- Hardware Pins ---
const int TOGGLE_BUTTON_PIN = 32;

// --- FreeRTOS Task Handles ---
TaskHandle_t DataCollectorTask;

// --- State Machine Variables ---
volatile bool loggingActive = false;
volatile bool inWarmupPhase = false;
unsigned long lastSampleTime = 0;
unsigned long warmupStartTime = 0;

// --- Low-Latency Button Logic for Wokwi Simulation Sandbox ---
bool checkButtonToggle() {
  static unsigned long lastDebounceTime = 0;
  static bool lastButtonState = HIGH;
  bool currentButtonState = digitalRead(TOGGLE_BUTTON_PIN);
  
  // If the mechanical state changed, track the clock snapshot
  if (currentButtonState != lastButtonState) {
    lastDebounceTime = millis();
    lastButtonState = currentButtonState;
  }
  
  // 10ms contact verification window optimized for digital execution
  if ((millis() - lastDebounceTime) >= 10) { 
    if (currentButtonState == LOW) { 
      return true; // Button is actively grounded
    }
  }
  return false;
}

// --- High-Speed MPU6050 Scale Calibration ---
void configureCollectorMPU() {
  Wire.begin(21, 22, 400000); // 400kHz Fast Mode I2C Configuration
  Wire.setTimeOut(10);        // 10ms Sudden Disconnection Escape Boundary
  
  // Wake up sensor array (Register 0x6B)
  Wire.beginTransmission(0x68);
  Wire.write(0x6B);
  Wire.write(0x00);
  Wire.endTransmission(true);

  // Set Accelerometer to Max Range: +/- 16G (Register 0x1C)
  Wire.beginTransmission(0x68);
  Wire.write(0x1C);
  Wire.write(0x18); 
  Wire.endTransmission(true);

  // Set Gyroscope to Max Range: +/- 2000 deg/s (Register 0x1B)
  Wire.beginTransmission(0x68);
  Wire.write(0x1B);
  Wire.write(0x18);
  Wire.endTransmission(true);
}

// --- Low-Overhead High-Speed Data Streaming ---
void streamSensorData() {
  int16_t rawAX, rawAY, rawAZ, rawGX, rawGY, rawGZ;

  Wire.beginTransmission(0x68);
  Wire.write(0x3B); // Starting register address for 6-Axis data block
  if (Wire.endTransmission(false) != 0) {
    Serial.println("BUS_ERROR: MPU6050 Disconnected!");
    return; // Safe breakout to prevent CPU lock if wire pops loose
  }
  
  Wire.requestFrom(0x68, 14, true); // Pull 14 bytes sequentially (6 Accel, 2 Temp, 6 Gyro)

  if (Wire.available() >= 14) {
    rawAX = (Wire.read() << 8) | Wire.read();
    rawAY = (Wire.read() << 8) | Wire.read();
    rawAZ = (Wire.read() << 8) | Wire.read();
    
    Wire.read(); Wire.read(); // Skip 2 bytes of internal temperature registers
    
    rawGX = (Wire.read() << 8) | Wire.read();
    rawGY = (Wire.read() << 8) | Wire.read();
    rawGZ = (Wire.read() << 8) | Wire.read();

    // Scaling conversions based on maximum register bounds
    float ax = (float)rawAX / 2048.0;   // 16G Scale Factor
    float ay = (float)rawAY / 2048.0;
    float az = (float)rawAZ / 2048.0;
    
    float gx = (float)rawGX / 16.4;    // 2000 deg/s Scale Factor
    float gy = (float)rawGY / 16.4;
    float gz = (float)rawGZ / 16.4;

    // Stream out as pristine CSV format: timestamp_ms,ax,ay,az,gx,gy,gz
    Serial.printf("%lu,%0.3f,%0.3f,%0.3f,%0.3f,%0.3f,%0.3f\n", millis(), ax, ay, az, gx, gy, gz);
  }
}

void setup() {
  Serial.begin(115200); // Set Baud Rate to 115200 bits per second
  
  // Point 2 Optimization: Enforce a dedicated, zero-lag internal TX transmission buffer
  Serial.setTxBufferSize(1024); 
  
  pinMode(TOGGLE_BUTTON_PIN, INPUT_PULLUP); // Active low internal resistor anchor
  
  configureCollectorMPU();

  // Create the isolated data collection loop on Core 1 via FreeRTOS
  xTaskCreatePinnedToCore(
    collectorEngine,
    "DataCollectorTask",
    4096,
    NULL,
    1,
    &DataCollectorTask,
    1 // Tied exclusively to Core 1 execution domain
  );
}

// --- Isolated Core 1 Execution Architecture ---
void collectorEngine(void * pvParameters) {
  bool lastLatchState = false;

  for(;;) {
    bool currentButtonPress = checkButtonToggle();

    // Catch the exact millisecond transition edge of a manual click
    if (currentButtonPress && !lastLatchState) {
      lastLatchState = true; // Engage execution latch to block repeat triggers

      if (!loggingActive && !inWarmupPhase) {
        // Step A: Trigger the non-blocking warmup countdown timer
        inWarmupPhase = true;
        warmupStartTime = millis();
        Serial.println("--- WARMUP_HOLD_STILL ---");
      } else {
        // Step B: If logging is currently active, cut execution instantly
        loggingActive = false;
        inWarmupPhase = false;
        Serial.println("--- LOGGING_STOP ---");
      }
    }

    // Release the trigger latch edge once the user lets go of the switch button
    if (!currentButtonPress) {
      lastLatchState = false;
    }

    // Handle Non-Blocking 2-Second Warm-up Pipeline (Point 1 Modification)
    if (inWarmupPhase) {
      if (millis() - warmupStartTime >= INITIAL_WARMUP_DELAY_MS) {
        inWarmupPhase = false;
        loggingActive = true;
        lastSampleTime = millis(); // Align timing timeline clock to drop initial jump artifact
        Serial.println("--- LOGGING_START ---");
      }
    }

    // Handle High-Speed Deterministic Data Sampling
    if (loggingActive) {
      unsigned long currentTime = millis();
      // Strict 10ms hardware clock gating threshold
      if (currentTime - lastSampleTime >= SAMPLE_INTERVAL_MS) {
        lastSampleTime = currentTime;
        streamSensorData();
      }
    }

    vTaskDelay(pdMS_TO_TICKS(1)); // Yield briefly to avoid starvation issues
  }
}

// --- Core 0 Loop (Completely unburdened, isolated background task domain) ---
void loop() {
  vTaskDelay(pdMS_TO_TICKS(100));
}