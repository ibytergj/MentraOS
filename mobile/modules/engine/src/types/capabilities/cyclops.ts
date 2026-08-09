/**
 * @fileoverview Cyclops Hardware Capabilities (OpenWearableAI)
 *
 * Capability profile for the Cyclops wearable — a displayless camera + mic
 * device (OpenWearableAI project). Values reflect what the current firmware
 * actually delivers, not the silicon's theoretical maximums.
 */

import type { Capabilities } from "../hardware";

/**
 * Cyclops capability profile
 */
export const cyclops: Capabilities = {
  modelName: "Cyclops",

  // Camera - OV3660, stills only at 720p (driver cap; sensor is 3 MP)
  hasCamera: true,
  camera: {
    resolution: { width: 1280, height: 720 },
    hasHDR: false,
    hasFocus: false,
    video: {
      canRecord: false,
      canStream: false,
      supportedStreamTypes: [],
      supportedResolutions: [{ width: 1280, height: 720 }],
    },
  },

  // Displayless is the point of the device
  hasDisplay: false,
  display: null,

  // Dual analog mic array feeding one 16 kHz mono LC3 stream
  hasMicrophone: true,
  microphone: {
    count: 2,
    hasVAD: false,
  },

  // A2DP speaker path (arm speakers on the product; devkit speakers today)
  hasSpeaker: true,
  speaker: {
    count: 2,
    isPrivate: false,
  },

  // No IMU exposed by current firmware
  hasIMU: false,
  imu: null,

  // Four buttons: SET (capture), MODE, VOL+, VOL-
  hasButton: true,
  button: {
    count: 4,
    buttons: [
      {
        type: "press",
        events: ["press"],
        isCapacitive: false,
      },
    ],
  },

  // WS2812 RGB status LED
  hasLight: true,
  light: {
    count: 1,
    lights: [
      {
        id: "status",
        purpose: "user_feedback",
        isFullColor: true,
        color: "rgb",
        position: "user_facing",
      },
    ],
  },

  power: {
    hasExternalBattery: false,
  },

  // Wi-Fi silicon exists but current firmware does not expose it
  hasWifi: false,
};
