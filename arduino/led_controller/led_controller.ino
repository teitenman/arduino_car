#include <ArduinoBLE.h>

// BLE サービス / キャラクタリスティック UUID
BLEService ledService("FFE0");
BLEByteCharacteristic ledChar("FFE1", BLEWrite | BLERead);

void setup() {
  Serial.begin(115200);
  pinMode(LED_BUILTIN, OUTPUT);
  digitalWrite(LED_BUILTIN, LOW);

  if (!BLE.begin()) {
    Serial.println("BLE start failed");
    while (1);
  }

  BLE.setLocalName("LED Controller");  // Flutter からこの名前でスキャン
  BLE.setAdvertisedService(ledService);
  ledService.addCharacteristic(ledChar);
  BLE.addService(ledService);
  ledChar.writeValue(0);

  BLE.advertise();
  Serial.println("BLE advertising as 'LED Controller'");
}

void loop() {
  BLEDevice central = BLE.central();
  if (!central) return;

  Serial.print("Connected: ");
  Serial.println(central.address());

  while (central.connected()) {
    if (ledChar.written()) {
      byte val = ledChar.value();
      digitalWrite(LED_BUILTIN, val ? HIGH : LOW);
      Serial.println(val ? "LED ON" : "LED OFF");
    }
  }

  Serial.println("Disconnected");
}
