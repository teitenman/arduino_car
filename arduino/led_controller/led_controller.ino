#include <ArduinoBLE.h>
#include "Arduino_LED_Matrix.h"

ArduinoLEDMatrix matrix;

BLEService carService("FFE0");
// 2-byte max to support combined commands: "F","B","L","R","FL","FR","BL","BR","S"
BLECharacteristic carChar("FFE1", BLEWrite | BLEWriteWithoutResponse | BLERead, 2);

// ── Advertising & error animations ────────────────────────────────────────────

const uint32_t advAnim[][4] = {
  {0xFFF00000, 0x00000000, 0x00000000, 80},
  {0x000FFF00, 0x00000000, 0x00000000, 80},
  {0x000000FF, 0xF0000000, 0x00000000, 80},
  {0x00000000, 0x0FFF0000, 0x00000000, 80},
  {0x00000000, 0x0000FFF0, 0x00000000, 80},
  {0x00000000, 0x0000000F, 0xFF000000, 80},
  {0x00000000, 0x00000000, 0x00FFF000, 80},
  {0x00000000, 0x00000000, 0x00000FFF, 80},
};

const uint32_t errAnim[][4] = {
  {0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 150},
  {0x00000000, 0x00000000, 0x00000000, 150},
};

// ── Direction patterns ────────────────────────────────────────────────────────
//
// 12×8 LED matrix.  Each row is a 12-bit value, MSB = col 0.
//
//  ▲ Forward       ▽ Backward      ← Left          → Right
//  . . . . X X .   . . . . X X .   . . . . . . .   . . . . . . .
//  . . . X X X X   . . . . X X .   . . . X . . .   . . . . . X .
//  . . X X X X X   . . . . X X .   . . X X . . .   . . . . . X X
//  . X X X X X X   . . . . X X .   X X X X X X X   X X X X X X X
//  . . . . X X .   . X X X X X X   . . X X . . .   . . . . . X X
//  . . . . X X .   . . X X X X X   . . . X . . .   . . . . . X .
//  . . . . X X .   . . . X X X X   . . . . . . .   . . . . . . .
//  . . . . X X .   . . . . X X .   . . . . . . .   . . . . . . .
//
//  ↖ Fwd-Left      ↗ Fwd-Right     ↙ Brk-Left      ↘ Brk-Right
//  X X X X X X X   X X X X X X X   . . X . . . .   . . . . . X X
//  X X X . . . .   . . . . X X X   . . . X . . .   . . . . X . .
//  X X . X . . .   . . . X . X X   . . . . X . .   . . . X . . .
//  X . . . X . .   . . X . . . X   . . . . . X .   . . X . . . .
//  . . . . . X .   . X . . . . .   X . . . X . .   . X . . . . X
//  . . . . . . X   X . . . . . .   X X . X . . .   X . . . . X X
//  . . . . . . . X . . . . . . .   X X X . . . .   . . . . X X X
//  . . . . . . . .   . . . . . .   X X X X X X X   X X X X X X X

// Row patterns (12-bit, MSB = col 0)
const uint16_t rowsF[8]  = {0x060,0x0F0,0x1F8,0x3FC,0x060,0x060,0x060,0x060};
const uint16_t rowsB[8]  = {0x060,0x060,0x060,0x060,0x3FC,0x1F8,0x0F0,0x060};
const uint16_t rowsL[8]  = {0x000,0x100,0x300,0xFFE,0x300,0x100,0x000,0x000};
const uint16_t rowsR[8]  = {0x000,0x008,0x00C,0x7FF,0x00C,0x008,0x000,0x000};
// Diagonal arrows: ↖↗↙↘
const uint16_t rowsFL[8] = {0xFE0,0xE00,0xD00,0x840,0x020,0x010,0x008,0x000};
const uint16_t rowsFR[8] = {0x07F,0x007,0x00B,0x021,0x040,0x080,0x100,0x000};
const uint16_t rowsBL[8] = {0x000,0x008,0x010,0x020,0x840,0xD00,0xE00,0xFE0};
const uint16_t rowsBR[8] = {0x000,0x100,0x080,0x040,0x021,0x00B,0x007,0x07F};
const uint16_t rowsS[8]  = {0x000,0x1F8,0x1F8,0x1F8,0x1F8,0x1F8,0x1F8,0x000};

uint32_t frameF[3], frameB[3], frameL[3], frameR[3];
uint32_t frameFL[3], frameFR[3], frameBL[3], frameBR[3];
uint32_t frameS[3];

void rowsToFrame(const uint16_t rows[8], uint32_t frame[3]) {
  frame[0] = frame[1] = frame[2] = 0;
  for (int r = 0; r < 8; r++) {
    for (int c = 0; c < 12; c++) {
      if ((rows[r] >> (11 - c)) & 1) {
        int idx = r * 12 + c;
        frame[idx / 32] |= (1UL << (31 - idx % 32));
      }
    }
  }
}

// ── Helpers ───────────────────────────────────────────────────────────────────

const uint32_t FRAME_ALL_ON[3]  = {0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF};
const uint32_t FRAME_ALL_OFF[3] = {0x00000000, 0x00000000, 0x00000000};

void flash(int n, int onMs, int offMs) {
  for (int i = 0; i < n; i++) {
    matrix.loadFrame(FRAME_ALL_ON);
    delay(onMs);
    matrix.loadFrame(FRAME_ALL_OFF);
    delay(offMs);
  }
}

void startAdvertising() {
  BLE.advertise();
  matrix.loadSequence(advAnim);
  matrix.play(true);
}

// ── Setup ─────────────────────────────────────────────────────────────────────

void setup() {
  Serial.begin(115200);
  pinMode(LED_BUILTIN, OUTPUT);
  digitalWrite(LED_BUILTIN, LOW);

  matrix.begin();

  rowsToFrame(rowsF,  frameF);
  rowsToFrame(rowsB,  frameB);
  rowsToFrame(rowsL,  frameL);
  rowsToFrame(rowsR,  frameR);
  rowsToFrame(rowsFL, frameFL);
  rowsToFrame(rowsFR, frameFR);
  rowsToFrame(rowsBL, frameBL);
  rowsToFrame(rowsBR, frameBR);
  rowsToFrame(rowsS,  frameS);

  if (!BLE.begin()) {
    matrix.loadSequence(errAnim);
    matrix.play(true);
    while (1);
  }

  BLE.setLocalName("LED Controller");
  BLE.setAdvertisedService(carService);
  carService.addCharacteristic(carChar);
  BLE.addService(carService);

  flash(3, 150, 100);
  startAdvertising();

  Serial.println("BLE advertising as 'LED Controller'");
}

// ── Loop ──────────────────────────────────────────────────────────────────────

void loop() {
  BLEDevice central = BLE.central();
  if (!central) return;

  Serial.print("Connected: ");
  Serial.println(central.address());

  flash(2, 200, 150);
  matrix.loadFrame(frameS);

  while (central.connected()) {
    BLE.poll();
    if (carChar.written()) {
      // Read up to 2 bytes as a command string
      char cmd[3] = {0, 0, 0};
      int len = min((int)carChar.valueLength(), 2);
      memcpy(cmd, carChar.value(), len);

      Serial.print("CMD: ");
      Serial.println(cmd);

      uint32_t* frame = frameS;
      bool motorOn = true;

      if      (strcmp(cmd, "F")  == 0) frame = frameF;
      else if (strcmp(cmd, "B")  == 0) frame = frameB;
      else if (strcmp(cmd, "L")  == 0) frame = frameL;
      else if (strcmp(cmd, "R")  == 0) frame = frameR;
      else if (strcmp(cmd, "FL") == 0) frame = frameFL;
      else if (strcmp(cmd, "FR") == 0) frame = frameFR;
      else if (strcmp(cmd, "BL") == 0) frame = frameBL;
      else if (strcmp(cmd, "BR") == 0) frame = frameBR;
      else { motorOn = false; }

      matrix.loadFrame(frame);
      digitalWrite(LED_BUILTIN, motorOn ? HIGH : LOW);
    }
  }

  Serial.println("Disconnected");
  flash(1, 300, 0);
  startAdvertising();
}
