#include "xparameters.h"
#include "xaxidma.h"
#include "xuartps.h"
#include "xil_cache.h"
#include "xil_printf.h"
#include "xscutimer.h" // NEW: Hardware Timer Library

// Increased to 4000 elements (16,000 bytes). 
// Kept strictly under 16,383 bytes to avoid DMA 14-bit length register overflow.
#define ARRAY_LENGTH 4000 
#define MAX_PKT_LEN (ARRAY_LENGTH * 4) 

#define DMA_BASE_ADDR XPAR_XAXIDMA_0_BASEADDR
#define UART_BASE_ADDR XPAR_XUARTPS_0_BASEADDR
#define TIMER_BASE_ADDR XPAR_XSCUTIMER_0_BASEADDR // SDT Timer Base Address

XAxiDma AxiDma;
XUartPs Uart_Ps;
XScuTimer Timer; // NEW: Timer Instance

u32 TxBuffer[ARRAY_LENGTH] __attribute__((aligned(32)));
u32 RxBuffer[ARRAY_LENGTH] __attribute__((aligned(32)));

int main() {
    // 1. Initialize DMA
    XAxiDma_Config *DmaCfgPtr = XAxiDma_LookupConfig(DMA_BASE_ADDR);
    XAxiDma_CfgInitialize(&AxiDma, DmaCfgPtr);
    XAxiDma_IntrDisable(&AxiDma, XAXIDMA_IRQ_ALL_MASK, XAXIDMA_DEVICE_TO_DMA);
    XAxiDma_IntrDisable(&AxiDma, XAXIDMA_IRQ_ALL_MASK, XAXIDMA_DMA_TO_DEVICE);

    // 2. Initialize UART
    XUartPs_Config *UartCfgPtr = XUartPs_LookupConfig(UART_BASE_ADDR);
    XUartPs_CfgInitialize(&Uart_Ps, UartCfgPtr, UartCfgPtr->BaseAddress);
    XUartPs_SetBaudRate(&Uart_Ps, 115200);

    // 3. Initialize SCU Private Timer
    XScuTimer_Config *TMRConfigPtr = XScuTimer_LookupConfig(TIMER_BASE_ADDR);
    XScuTimer_CfgInitialize(&Timer, TMRConfigPtr, TMRConfigPtr->BaseAddr);

    u8 *tx_byte_ptr = (u8 *)TxBuffer;
    u8 *rx_byte_ptr = (u8 *)RxBuffer;

    while(1) {
        // Handshake
        u8 sync_byte = 0;
        while(sync_byte != 'S') { XUartPs_Recv(&Uart_Ps, &sync_byte, 1); }
        sync_byte = 'R';
        XUartPs_Send(&Uart_Ps, &sync_byte, 1);

        // Receive Data
        int received_bytes = 0;
        while(received_bytes < MAX_PKT_LEN) {
            received_bytes += XUartPs_Recv(&Uart_Ps, &tx_byte_ptr[received_bytes], MAX_PKT_LEN - received_bytes);
        }

        Xil_DCacheFlushRange((UINTPTR)TxBuffer, MAX_PKT_LEN);
        Xil_DCacheFlushRange((UINTPTR)RxBuffer, MAX_PKT_LEN);

        // === TIMING START ===
        XScuTimer_LoadTimer(&Timer, 0xFFFFFFFF); // Load max 32-bit value
        XScuTimer_Start(&Timer);

        XAxiDma_SimpleTransfer(&AxiDma, (UINTPTR)RxBuffer, MAX_PKT_LEN, XAXIDMA_DEVICE_TO_DMA);
        XAxiDma_SimpleTransfer(&AxiDma, (UINTPTR)TxBuffer, MAX_PKT_LEN, XAXIDMA_DMA_TO_DEVICE);

        while (XAxiDma_Busy(&AxiDma, XAXIDMA_DEVICE_TO_DMA) || XAxiDma_Busy(&AxiDma, XAXIDMA_DMA_TO_DEVICE)) {}

        XScuTimer_Stop(&Timer);
        // === TIMING END ===

        Xil_DCacheInvalidateRange((UINTPTR)RxBuffer, MAX_PKT_LEN);

        // Calculate actual hardware clock cycles taken
        u32 clock_cycles = 0xFFFFFFFF - XScuTimer_GetCounterValue(&Timer);

        // 1. Send the 16,000 data bytes back to Python
        int sent_bytes = 0;
        while(sent_bytes < MAX_PKT_LEN) {
            sent_bytes += XUartPs_Send(&Uart_Ps, &rx_byte_ptr[sent_bytes], MAX_PKT_LEN - sent_bytes);
        }
        
        // 2. WAIT FOR FIFO: Ensure the previous 16,000 bytes have space clearing up
        while (XUartPs_IsSending(&Uart_Ps)) {
            // Block until the UART hardware has physically shifted out the data
        }

        // 3. Send the timing data (4 bytes) safely
        int timer_sent = 0;
        u8* timer_ptr = (u8*)&clock_cycles;
        while(timer_sent < 4) {
            timer_sent += XUartPs_Send(&Uart_Ps, &timer_ptr[timer_sent], 4 - timer_sent);
        }
    }
    return 0;
}