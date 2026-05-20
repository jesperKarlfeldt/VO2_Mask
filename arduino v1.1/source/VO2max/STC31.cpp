#include "STC31.h"

// Kommandon (no CRC path)
#define STC_DISABLE_CRC     0x3768
#define STC_SET_BINARY_GAS  0x3615  // arg 0x0003 => CO2 i luft
#define STC_MEASURE_ONESHOT 0x3639
#define STC_DISABLE_ASC     0x3FEF
#define STC_SET_RH          0x3624
#define STC_SET_PRESSURE    0x362F
#define STC_FORCED_RECAL    0x3661

bool STC31::writeCmd(uint16_t cmd) {
  _wire->beginTransmission(_addr);
  _wire->write(uint8_t(cmd >> 8));
  _wire->write(uint8_t(cmd));
  return _wire->endTransmission() == 0;
}
bool STC31::writeCmdArg(uint16_t cmd, uint16_t arg) {
  _wire->beginTransmission(_addr);
  _wire->write(uint8_t(cmd >> 8));
  _wire->write(uint8_t(cmd));
  _wire->write(uint8_t(arg >> 8));
  _wire->write(uint8_t(arg));
  return _wire->endTransmission() == 0;
}
bool STC31::readWordsNoCRC(uint8_t nWords, uint16_t *out) {
  // STC31 can return words either with CRC (3 bytes/word) or without (2 bytes/word).
  // Try reading with CRC first, and fall back to no-CRC if only 2 bytes/word are returned.
  const uint8_t nBytesCrc = nWords * 3;
  const uint8_t nBytes = nWords * 2;
  uint8_t got = _wire->requestFrom(int(_addr), int(nBytesCrc));
  if (got == nBytesCrc) {
    for (uint8_t i = 0; i < nWords; i++) {
      uint8_t msb = _wire->read();
      uint8_t lsb = _wire->read();
      (void)_wire->read(); // CRC byte (ignored)
      out[i] = (uint16_t(msb) << 8) | lsb;
    }
    return true;
  }
  if (got == nBytes) {
    for (uint8_t i = 0; i < nWords; i++) {
      uint8_t msb = _wire->read();
      uint8_t lsb = _wire->read();
      out[i] = (uint16_t(msb) << 8) | lsb;
    }
    return true;
  }
  while (_wire->available()) (void)_wire->read();
  return false;
}

bool STC31::begin(TwoWire &w) {
  _wire = &w;
  // prova alla kandidater tills någon ackar DISABLE_CRC
  for (uint8_t i = 0; i < 4; i++) {
    _addr = STC_ADDR_CAND[i];
    _wire->beginTransmission(_addr);
    _wire->write(uint8_t(STC_DISABLE_CRC >> 8));
    _wire->write(uint8_t(STC_DISABLE_CRC));
    if (_wire->endTransmission() == 0) { break; }
  }
  // välj "CO2 i luft" (0..25 vol%)
  if (!writeCmdArg(STC_SET_BINARY_GAS, 0x0003)) { _ok = false; return false; }
  delay(5);
  // Disable automatic self-calibration (assumes zero CO2 background, not valid for mask)
  writeCmdArg(STC_DISABLE_ASC, 0x0000);
  delay(5);
  // Set default pressure compensation (1013 mbar)
  //writeCmdArg(STC_SET_PRESSURE, 1013);
  //delay(5);
  _ok = true;
  return true;
}

bool STC31::readCO2(float &co2_volpct, float &tempC) {
  if (!writeCmd(STC_MEASURE_ONESHOT)) return false;
  delay(70); // t_meas ~66 ms
  uint16_t w[3] = {0};
  if (!readWordsNoCRC(3, w)) return false;

  // Skalning enligt STC31-datablad:
  // conc[vol%] = (raw - 2^14)/2^15*100 , temp[°C] = raw/200
  co2_volpct = (( (float)w[0] - 16384.0f ) / 32768.0f) * 100.0f;
  tempC      = ( (int16_t)w[1] ) / 200.0f;
  return true;
}

bool STC31::setRelativeHumidity(float rh_percent) {
  uint16_t raw = (uint16_t)(rh_percent * 65535.0f / 100.0f);
  return writeCmdArg(STC_SET_RH, raw);
}

bool STC31::setPressure(uint16_t pressure_mbar) {
  return writeCmdArg(STC_SET_PRESSURE, pressure_mbar);
}

bool STC31::forcedRecalibration(float reference_volpct) {
  // Encode reference concentration in same format as measurement output:
  //   raw = concentration_vol% * 32768 / 100 + 16384
  uint16_t raw = (uint16_t)(reference_volpct * 327.68f + 16384.0f);
  return writeCmdArg(STC_FORCED_RECAL, raw);
}
