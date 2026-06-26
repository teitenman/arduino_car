#include <ArduinoBLE.h>
#include "Arduino_LED_Matrix.h"

ArduinoLEDMatrix matrix;

BLEService ledService("FFE0");
BLEByteCharacteristic ledChar("FFE1", BLEWrite | BLERead);

// アドバタイズ中：行スキャンアニメーション
const uint32_t advAnim[][4] = {
  {0xFFF00000, 0x00000000, 0x00000000, 100},
  {0x000FFF00, 0x00000000, 0x00000000, 100},
  {0x000000FF, 0xF0000000, 0x00000000, 100},
  {0x00000000, 0x0FFF0000, 0x00000000, 100},
  {0x00000000, 0x0000FFF0, 0x00000000, 100},
  {0x00000000, 0x0000000F, 0xFF000000, 100},
  {0x00000000, 0x00000000, 0x00FFF000, 100},
  {0x00000000, 0x00000000, 0x00000FFF, 100},
};

// BLE エラー：高速点滅
const uint32_t errAnim[][4] = {
  {0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 150},
  {0x00000000, 0x00000000, 0x00000000, 150},
};

const uint32_t FRAME_ALL_ON[3]  = { 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF };
const uint32_t FRAME_ALL_OFF[3] = { 0x00000000, 0x00000000, 0x00000000 };
const uint32_t FRAME_LED_ON[3]  = { 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF };
const uint32_t FRAME_LED_OFF[3] = { 0xFFF80180, 0x18018018, 0x01801FFF };

// N 回点滅（全点灯 ↔ 全消灯）
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

void setup() {
  Serial.begin(115200);
  pinMode(LED_BUILTIN, OUTPUT);
  digitalWrite(LED_BUILTIN, LOW);

  matrix.begin();
  // BLE.begin();

  if (!BLE.begin()) {
    // BLE 初期化失敗 → 高速点滅でエラー通知
    matrix.loadSequence(errAnim);
    matrix.play(true);
    while (1);
  }

  BLE.setLocalName("LED Controller");
  BLE.setAdvertisedService(ledService);
  ledService.addCharacteristic(ledChar);
  BLE.addService(ledService);
  ledChar.writeValue(0);

  BLE.advertise();

  // 起動 OK：3 回素早く点滅 → スキャンアニメーション
  flash(3, 150, 100);
  startAdvertising();

  Serial.println("BLE advertising as 'LED Controller'");
}

void loop() {
  BLEDevice central = BLE.central();
  if (!central) return;

  Serial.print("Connected: ");
  Serial.println(central.address());

  // 接続成功：2 回点滅 → 外枠
  flash(2, 200, 150);
  matrix.loadFrame(FRAME_LED_OFF);

  while (central.connected()) {
    BLE.poll();
    if (ledChar.written()) {
      byte val = ledChar.value();
      digitalWrite(LED_BUILTIN, val ? HIGH : LOW);
      matrix.loadFrame(val ? FRAME_LED_ON : FRAME_LED_OFF);
      Serial.println(val ? "LED ON" : "LED OFF");
    }
  }

  Serial.println("Disconnected");

  // 切断：1 回点滅 → アドバタイズ再開
  flash(1, 300, 0);
  startAdvertising();
}
