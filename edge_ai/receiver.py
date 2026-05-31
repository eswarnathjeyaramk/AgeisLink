#!/usr/bin/env python
import argparse
import os
import uuid
import serial
import serial.tools.list_ports
from datetime import datetime
import time

# --- Fallback Default Settings ---
DEFAULT_BAUD = 115200       # Matches our ESP32's Baud Rate config
DEFAULT_LABEL = "unknown"   # Prepend label fallback if none provided

def main():
    # 1. Setup Command Line Arguments (Argparse Feature)
    parser = argparse.ArgumentParser(description="Aegis Link High-Speed Data Collector Pipeline")
    parser.add_argument('-p', '--port', dest='port', type=str, required=True,
                        help="The serial COM port your ESP32 is plugged into")
    parser.add_argument('-b', '--baud', dest='baud', type=int, default=DEFAULT_BAUD,
                        help=f"Baud rate speed configuration (default = {DEFAULT_BAUD})")
    parser.add_argument('-d', '--directory', dest='directory', type=str, default=".",
                        help="Output storage folder directory path (default = current folder)")
    parser.add_argument('-l', '--label', dest='label', type=str, default=DEFAULT_LABEL,
                        help=f"Movement behavior label prefix (default = {DEFAULT_LABEL})")
    
    args = parser.parse_args()
    
    # 2. On-The-Fly Directory Builder (os.makedirs Feature)
    try:
        os.makedirs(args.directory, exist_ok=True)
    except Exception as e:
        print(f"❌ ERROR: Could not create folder directory layout: {e}")
        return

    # 3. Initialize and Open Serial Bus Link
    ser = serial.Serial()
    ser.port = args.port
    ser.baudrate = args.baud
    ser.timeout = 1  # 1-second read timeout escape boundary

    try:
        ser.open()
        ser.reset_input_buffer() # Flush internal USB cache buffer immediately
    except Exception as e:
        print(f"❌ ERROR: Failed to connect to port {args.port}!")
        print("Verify your USB connection or close any open Serial Monitors/Wokwi browser frames.")
        print(f"Details: {e}")
        return

    print("\n=======================================================")
    print(f"🔌 Connected to ESP32 on {args.port} at {args.baud} Baud.")
    print(f"📁 Target Output Folder: {os.path.abspath(args.directory)}")
    print(f"🏷️ Behavior Session Label: {args.label.upper()}")
    print("=======================================================")
    print("\n🚀 System Idle. Press the physical breadboard button to start...")

    csv_file = None
    is_logging = False
    sample_counter = 0

    try:
        while True:
            if ser.in_waiting > 0:
                try:
                    # Read lines directly crossing the copper USB rail
                    raw_line = ser.readline().decode('utf-8', errors='ignore').strip()
                except Exception:
                    continue # Skip deformed bytes during sudden physical impacts
                
                # --- State Machine Event Handling Logic ---
                
                if "--- WARMUP_HOLD_STILL ---" in raw_line:
                    print("\n⏳ WARMUP ACTIVATED: Get into position and hold completely still...")
                    
                elif "--- LOGGING_START ---" in raw_line:
                    is_logging = True
                    sample_counter = 0
                    
                    # Cryptographic Unique Suffix String Generation (UUID Feature)
                    unique_id = str(uuid.uuid4())[-12:]
                    filename = f"{args.label}_{unique_id}.csv"
                    full_file_path = os.path.join(args.directory, filename)
                    
                    # Initialize clean data file
                    csv_file = open(full_file_path, 'w', newline='')
                    csv_file.write("timestamp_ms,ax,ay,az,gx,gy,gz\n") # Inject pristine csv headers
                    
                    print(f"🔴 RECORDING: Writing streaming data rows to -> {filename}")
                    
                elif "--- LOGGING_STOP ---" in raw_line:
                    if is_logging and csv_file:
                        csv_file.flush()
                        csv_file.close() # Safely lock file to local memory disk
                        print(f"\n💾 RECORDING STOPPED: Preserved all {sample_counter} rows successfully.\nAwaiting next trigger...")
                        
                        # Reset tracking states cleanly
                        is_logging = False
                        csv_file = None
                        sample_counter = 0
                        
                elif "BUS_ERROR" in raw_line:
                    print("\n⚠️ HARDWARE WARNING: MPU6050 bus connection severed mid-run!")
                    
                else:
                    # Handle incoming continuous numerical time-series lines
                    if is_logging and csv_file:
                        # Verify the row contains exactly 7 data columns before writing
                        if len(raw_line.split(',')) == 7:
                            csv_file.write(raw_line + "\n")
                            sample_counter += 1
                            # Asynchronous Zero-Lag Live UI In-Terminal Counter Refresh
                            print(f"\r⚡ Samples Captured: [{sample_counter}]", end="", flush=True)

            # High-accuracy time yielding to maintain 0% background CPU thread overhead
            time.sleep(0.001)

    except KeyboardInterrupt:
        print("\n\nStopping script execution...")
    finally:
        # Emergency hardware safety cleanup boundary
        if csv_file:
            csv_file.close()
        if ser.is_open:
            ser.close()
        print("🔌 Serial connection released safely. Data Collector Off.")

if __name__ == "__main__":
    main()