// ---------------------------------------------------------------
//  Claude Code status light — Arduino Nano firmware
//
//  Drives 3 LEDs cut from a WS2812B strip over the USB serial port.
//  The three LEDs are independent: several can be lit at once (one
//  instance waiting for a response while another is still working).
//
//  Protocol: a 4-character frame describes the full state.
//
//      S<red><orange><green>      e.g. S201, S010, S003
//
//  Each digit is a mode:
//      0  off
//      1  on
//      2  blinking
//      3  idle animation
//
//  Two shortcuts: X turns everything off, ? returns the current frame.
//
//  The strip is mounted DIN-down: index 0 = bottom LED.
//  Required library: FastLED.
// ---------------------------------------------------------------

#include <FastLED.h>

#define LED_PIN      6      // strip DIN
#define NUM_LEDS     3
#define BRIGHTNESS   200    // 0-255, applies to red/orange/green
#define BLINK_MS     450
#define DIM_SCALE    64     // idle mode, out of 255 (~25 %)

CRGB leds[NUM_LEDS];

const uint8_t I_GREEN  = 0;   // bottom LED (closest to DIN)
const uint8_t I_ORANGE = 1;
const uint8_t I_RED    = 2;   // top LED

const CRGB C_RED    = CRGB(255,   0,   0);
const CRGB C_ORANGE = CRGB(255,  90,   0);
const CRGB C_GREEN  = CRGB(  0, 255,   0);
const CRGB C_WHITE  = CRGB(255, 255, 255);

const unsigned long KNIGHT_MS    = 350;  // idle sweep speed (ms/step)
const uint8_t        KNIGHT_SCALE = 50;  // idle sweep brightness, out of 255
                                          // (lower than BRIGHTNESS's ratio would
                                          // give, to keep the sweep as soft as before)

uint8_t       mode[NUM_LEDS] = { 0, 0, 0 };
bool          phase   = true;
unsigned long tPhase  = 0;

bool    inFrame = false;
uint8_t received[3];
uint8_t nReceived = 0;

// Idle = nothing working or waiting for a while (frame S003, see
// traffic-light.ps1). Rather than a plain dim green on a single LED, all
// three LEDs do a soft white Knight Rider-style sweep for as long as it lasts.
bool          idleAnim = false;
uint8_t       kPos    = 0;
int8_t        kDir    = 1;
unsigned long tKnight = 0;

CRGB colorFor(uint8_t i) {
  if (i == I_RED)    return C_RED;
  if (i == I_ORANGE) return C_ORANGE;
  return C_GREEN;
}

void render() {
  for (uint8_t i = 0; i < NUM_LEDS; i++) {
    CRGB c = colorFor(i);
    switch (mode[i]) {
      case 1:  leds[i] = c;                                   break;
      case 2:  leds[i] = phase ? c : (CRGB)CRGB::Black;       break;
      case 3:  leds[i] = c; leds[i].nscale8_video(DIM_SCALE); break;
      default: leds[i] = CRGB::Black;                         break;
    }
  }
  FastLED.show();
}

void animateIdle() {
  if (millis() - tKnight < KNIGHT_MS) return;
  tKnight = millis();

  FastLED.clear();
  leds[kPos] = C_WHITE;
  leds[kPos].nscale8_video(KNIGHT_SCALE);
  FastLED.show();

  if (kPos == 0)                kDir = 1;
  else if (kPos == NUM_LEDS - 1) kDir = -1;
  kPos += kDir;
}

void selfTest() {
  const uint8_t order[3]  = { I_RED, I_ORANGE, I_GREEN };
  const CRGB    colors[3] = { C_RED, C_ORANGE, C_GREEN };
  for (uint8_t i = 0; i < 3; i++) {
    FastLED.clear();
    leds[order[i]] = colors[i];
    FastLED.show();
    delay(180);
  }
}

void setup() {
  Serial.begin(115200);
  FastLED.addLeds<WS2812B, LED_PIN, GRB>(leds, NUM_LEDS);
  FastLED.setBrightness(BRIGHTNESS);
  FastLED.clear();
  FastLED.show();

  selfTest();                 // sweeps top -> bottom, checks the wiring

  render();                   // everything off while waiting for the first frame
}

void loop() {
  while (Serial.available()) {
    char c = Serial.read();

    if (inFrame) {
      if (c >= '0' && c <= '3') {
        received[nReceived++] = c - '0';
        if (nReceived == 3) {
          mode[I_RED]    = received[0];
          mode[I_ORANGE] = received[1];
          mode[I_GREEN]  = received[2];
          inFrame = false;
          phase   = true;
          tPhase  = millis();

          bool nowIdle = (mode[I_RED] == 0 && mode[I_ORANGE] == 0 && mode[I_GREEN] == 3);
          if (nowIdle && !idleAnim) {
            // entering idle: restart the sweep from the beginning, but a
            // plain re-send of the same frame (the bridge's periodic
            // refresh) must not make it jump
            kPos    = 0;
            kDir    = 1;
            tKnight = 0;
          }
          idleAnim = nowIdle;

          if (!idleAnim) render();
        }
      } else {
        inFrame = false;      // malformed frame, drop it
      }
      continue;
    }

    switch (c) {
      case 'S':
        inFrame   = true;
        nReceived = 0;
        break;
      case 'X':
        mode[0] = mode[1] = mode[2] = 0;
        idleAnim = false;
        render();
        break;
      case '?':
        Serial.print('S');
        Serial.print(mode[I_RED]);
        Serial.print(mode[I_ORANGE]);
        Serial.println(mode[I_GREEN]);
        break;
      default:
        break;                // \r, \n and noise ignored
    }
  }

  if (idleAnim) {
    animateIdle();
    return;
  }

  bool blinking = (mode[0] == 2 || mode[1] == 2 || mode[2] == 2);
  if (blinking && millis() - tPhase >= BLINK_MS) {
    tPhase = millis();
    phase  = !phase;
    render();
  }
}
