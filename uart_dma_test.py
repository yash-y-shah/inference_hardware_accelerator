import serial
import struct
import random
import time
import sys

# UPDATED CONFIGURATION
COM_PORT = 'COM11'  
BAUD_RATE = 115200
ARRAY_LENGTH = 4000  # Increased for backpressure stress testing
BYTES_TO_READ = (ARRAY_LENGTH * 4) + 4 # 16,000 bytes of data + 4 bytes for the timer

# --- NEW: Loop Configuration ---
NUM_ITERATIONS = 10 # Change N here

def run_hardware_validation(iterations=NUM_ITERATIONS):
    try:
        # OPEN SERIAL PORT ONCE BEFORE THE LOOP
        ser = serial.Serial(COM_PORT, BAUD_RATE, timeout=10) 
        print(f"[*] Successfully opened {COM_PORT}")
    except Exception as e:
        print(f"[!] Failed to open port {COM_PORT}: {e}")
        sys.exit(1)

    total_successes = 0

    # --- NEW: Outer Loop ---
    for iteration in range(iterations):
        print(f"\n==================================================")
        print(f"[*] Starting Iteration {iteration + 1} of {iterations}")
        print(f"==================================================")

        print(f"[*] Generating {ARRAY_LENGTH} random 32-bit integers...")
        input_array = [random.randint(0, 100000) for _ in range(ARRAY_LENGTH)]
        tx_bytes = struct.pack(f'<{ARRAY_LENGTH}I', *input_array)

        print("[*] Initiating handshake with ZedBoard...")
        ser.write(b'S')
        ready_resp = ser.read(1)
        if ready_resp != b'R':
            print(f"[!] Handshake failed. Received: {ready_resp}")
            ser.close()
            sys.exit(1)
            
        print("[*] Handshake successful. Transmitting 16KB to DDR3...")
        start_time = time.time()
        ser.write(tx_bytes)

        # 5. Receive Data
        print("[*] Waiting for hardware accelerator...")
        rx_bytes = b''
        while len(rx_bytes) < BYTES_TO_READ:
            chunk = ser.read(BYTES_TO_READ - len(rx_bytes))
            if not chunk:
                print(f"[!] Serial timeout occurred. Received {len(rx_bytes)} out of {BYTES_TO_READ} bytes.")
                break
            rx_bytes += chunk

        end_time = time.time()
        
        # 6. Advanced Debugging Unpack
        hw_cycles = None
        if len(rx_bytes) == BYTES_TO_READ:
            # Perfect reception
            data_bytes = rx_bytes[:-4]
            timer_bytes = rx_bytes[-4:]
            output_array = struct.unpack(f'<{ARRAY_LENGTH}I', data_bytes)
            hw_cycles = struct.unpack('<I', timer_bytes)[0]
        elif len(rx_bytes) == (ARRAY_LENGTH * 4):
            # We got the data, but dropped the timer
            print("[!] WARNING: Timer bytes dropped by UART FIFO. Verifying array data anyway...")
            output_array = struct.unpack(f'<{ARRAY_LENGTH}I', rx_bytes)
        else:
            # Fatal data loss
            print(f"[!] FATAL: Received corrupted payload length ({len(rx_bytes)} bytes).")
            ser.close()
            sys.exit(1)

        # 7. Verification
        print("--- Verification Results ---")
        error_count = 0
        for i in range(ARRAY_LENGTH):
            expected_val = input_array[i]
            if output_array[i] != expected_val:
                error_count += 1
                if error_count <= 5: 
                    print(f"[ERROR] Index {i}: Expected {expected_val}, Got {output_array[i]}")

        if error_count == 0:
            print(f"[SUCCESS] Iteration {iteration + 1}: All {ARRAY_LENGTH} elements passed hardware verification!")
            print(f"[INFO] Full PC-to-Board Round Trip Latency: {(end_time - start_time):.4f} seconds")
            
            if hw_cycles is not None:
                # SCU Timer runs at half the Cortex-A9 frequency (667 MHz / 2 = 333.33 MHz)
                hw_seconds = hw_cycles / 333333333.0
                print(f"[INFO] TRUE SILICON LATENCY: {hw_cycles} clock cycles ({hw_seconds * 1000000:.2f} microseconds)")
                
                megabytes = (ARRAY_LENGTH * 4) / 1048576.0
                throughput = megabytes / hw_seconds
                print(f"[INFO] Achieved DMA Bandwidth: {throughput:.2f} MB/s")
            
            total_successes += 1
        else:
            print(f"[FAILED] Iteration {iteration + 1}: {error_count} elements failed verification.")
            print("[!] Halting stress test due to data corruption.")
            break # Stop looping if we encounter a hardware failure

    # --- NEW: Final Summary ---
    print(f"\n==================================================")
    print(f"[*] STRESS TEST COMPLETE: {total_successes}/{iterations} Iterations Successful.")
    print(f"==================================================")
    
    # CLOSE SERIAL PORT ONCE AT THE END
    ser.close()

if __name__ == '__main__':
    run_hardware_validation()