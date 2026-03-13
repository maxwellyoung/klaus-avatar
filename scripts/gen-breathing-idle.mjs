/**
 * Generate a procedural "Breathing Idle" animation as VRM-compatible keyframe JSON.
 * No FBX needed — pure sine-wave chest/spine movement.
 * Output matches the format expected by the viewer's animation player.
 */

import fs from 'fs';

const FPS = 30;
const DURATION = 3.0; // seconds for one breath cycle
const FRAMES = Math.ceil(FPS * DURATION);
const BREATH_AMPLITUDE = 0.012; // subtle chest rise
const BODY_ROCK = 0.004;       // tiny side sway
const HEAD_NOD = 0.006;        // gentle head bob

const tracks = {};

function quatFromEuler(x, y, z) {
  // Simple Euler XYZ to quaternion
  const cx = Math.cos(x/2), sx = Math.sin(x/2);
  const cy = Math.cos(y/2), sy = Math.sin(y/2);
  const cz = Math.cos(z/2), sz = Math.sin(z/2);
  return [
    sx*cy*cz + cx*sy*sz,
    cx*sy*cz - sx*cy*sz,
    cx*cy*sz + sx*sy*cz,
    cx*cy*cz - sx*sy*sz,
  ];
}

const times = Array.from({ length: FRAMES }, (_, i) => i / FPS);

// Generate keyframes for each bone
const bones = {
  'chest': (t) => {
    const breath = Math.sin((t / DURATION) * Math.PI * 2);
    return quatFromEuler(breath * BREATH_AMPLITUDE, 0, 0);
  },
  'upperChest': (t) => {
    const breath = Math.sin((t / DURATION) * Math.PI * 2 + 0.2);
    return quatFromEuler(breath * BREATH_AMPLITUDE * 0.6, 0, 0);
  },
  'spine': (t) => {
    const sway = Math.sin((t / DURATION) * Math.PI * 2 * 0.5);
    return quatFromEuler(0, sway * BODY_ROCK, sway * BODY_ROCK * 0.5);
  },
  'neck': (t) => {
    const nod = Math.sin((t / DURATION) * Math.PI * 2 + 0.3);
    return quatFromEuler(nod * HEAD_NOD * 0.5, 0, 0);
  },
  'head': (t) => {
    const nod = Math.sin((t / DURATION) * Math.PI * 2 + 0.4);
    const turn = Math.sin((t / DURATION) * Math.PI * 2 * 0.3) * 0.003;
    return quatFromEuler(nod * HEAD_NOD, turn, 0);
  },
  'leftShoulder': (t) => {
    const breath = Math.sin((t / DURATION) * Math.PI * 2);
    return quatFromEuler(0, 0, breath * 0.008);
  },
  'rightShoulder': (t) => {
    const breath = Math.sin((t / DURATION) * Math.PI * 2);
    return quatFromEuler(0, 0, -breath * 0.008);
  },
};

const keyframes = {};
for (const [bone, fn] of Object.entries(bones)) {
  keyframes[bone] = times.map(t => ({ time: t, rotation: fn(t) }));
}

// Hips position — very subtle up/down with breath
keyframes['hips_position'] = times.map(t => ({
  time: t,
  position: [0, Math.sin((t / DURATION) * Math.PI * 2) * 0.003, 0]
}));

const output = {
  name: 'BreathingIdle',
  duration: DURATION,
  loop: true,
  fps: FPS,
  keyframes,
};

fs.writeFileSync('assets/animations/breathing-idle.json', JSON.stringify(output, null, 2));
console.log(`✅ Generated breathing-idle.json — ${FRAMES} frames @ ${FPS}fps, ${DURATION}s loop`);
console.log('Bones animated:', Object.keys(keyframes).join(', '));
