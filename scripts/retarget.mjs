/**
 * Mixamo FBX → VRM-compatible JSON keyframes
 *
 * Retargeting formula from @pixiv/three-vrm:
 *   rotation: parentRestWorldRot * animQ * inv(boneRestWorldRot)
 *   position: scaled by vrmHipsHeight / mixamoHipsHeight
 *
 * Usage:
 *   node scripts/retarget.mjs <vrm-file> <fbx-file> [output.json]
 */

import * as THREE from 'three';
import { GLTFLoader } from 'three/addons/loaders/GLTFLoader.js';
import { FBXLoader } from 'three/addons/loaders/FBXLoader.js';
import { VRMLoaderPlugin, VRMHumanBoneName } from '@pixiv/three-vrm';
import fs from 'fs';
import path from 'path';

// Mixamo bone name → VRM HumanBoneName mapping
const MIXAMO_TO_VRM = {
  'mixamorigHips': VRMHumanBoneName.Hips,
  'mixamorigSpine': VRMHumanBoneName.Spine,
  'mixamorigSpine1': VRMHumanBoneName.Chest,
  'mixamorigSpine2': VRMHumanBoneName.UpperChest,
  'mixamorigNeck': VRMHumanBoneName.Neck,
  'mixamorigHead': VRMHumanBoneName.Head,
  'mixamorigLeftShoulder': VRMHumanBoneName.LeftShoulder,
  'mixamorigLeftArm': VRMHumanBoneName.LeftUpperArm,
  'mixamorigLeftForeArm': VRMHumanBoneName.LeftLowerArm,
  'mixamorigLeftHand': VRMHumanBoneName.LeftHand,
  'mixamorigRightShoulder': VRMHumanBoneName.RightShoulder,
  'mixamorigRightArm': VRMHumanBoneName.RightUpperArm,
  'mixamorigRightForeArm': VRMHumanBoneName.RightLowerArm,
  'mixamorigRightHand': VRMHumanBoneName.RightHand,
  'mixamorigLeftUpLeg': VRMHumanBoneName.LeftUpperLeg,
  'mixamorigLeftLeg': VRMHumanBoneName.LeftLowerLeg,
  'mixamorigLeftFoot': VRMHumanBoneName.LeftFoot,
  'mixamorigLeftToeBase': VRMHumanBoneName.LeftToes,
  'mixamorigRightUpLeg': VRMHumanBoneName.RightUpperLeg,
  'mixamorigRightLeg': VRMHumanBoneName.RightLowerLeg,
  'mixamorigRightFoot': VRMHumanBoneName.RightFoot,
  'mixamorigRightToeBase': VRMHumanBoneName.RightToes,
  // Fingers
  'mixamorigLeftHandThumb1': VRMHumanBoneName.LeftThumbMetacarpal,
  'mixamorigLeftHandThumb2': VRMHumanBoneName.LeftThumbProximal,
  'mixamorigLeftHandThumb3': VRMHumanBoneName.LeftThumbDistal,
  'mixamorigLeftHandIndex1': VRMHumanBoneName.LeftIndexProximal,
  'mixamorigLeftHandIndex2': VRMHumanBoneName.LeftIndexIntermediate,
  'mixamorigLeftHandIndex3': VRMHumanBoneName.LeftIndexDistal,
  'mixamorigLeftHandMiddle1': VRMHumanBoneName.LeftMiddleProximal,
  'mixamorigLeftHandMiddle2': VRMHumanBoneName.LeftMiddleIntermediate,
  'mixamorigLeftHandMiddle3': VRMHumanBoneName.LeftMiddleDistal,
  'mixamorigLeftHandRing1': VRMHumanBoneName.LeftRingProximal,
  'mixamorigLeftHandRing2': VRMHumanBoneName.LeftRingIntermediate,
  'mixamorigLeftHandRing3': VRMHumanBoneName.LeftRingDistal,
  'mixamorigLeftHandPinky1': VRMHumanBoneName.LeftLittleProximal,
  'mixamorigLeftHandPinky2': VRMHumanBoneName.LeftLittleIntermediate,
  'mixamorigLeftHandPinky3': VRMHumanBoneName.LeftLittleDistal,
  'mixamorigRightHandThumb1': VRMHumanBoneName.RightThumbMetacarpal,
  'mixamorigRightHandThumb2': VRMHumanBoneName.RightThumbProximal,
  'mixamorigRightHandThumb3': VRMHumanBoneName.RightThumbDistal,
  'mixamorigRightHandIndex1': VRMHumanBoneName.RightIndexProximal,
  'mixamorigRightHandIndex2': VRMHumanBoneName.RightIndexIntermediate,
  'mixamorigRightHandIndex3': VRMHumanBoneName.RightIndexDistal,
  'mixamorigRightHandMiddle1': VRMHumanBoneName.RightMiddleProximal,
  'mixamorigRightHandMiddle2': VRMHumanBoneName.RightMiddleIntermediate,
  'mixamorigRightHandMiddle3': VRMHumanBoneName.RightMiddleDistal,
  'mixamorigRightHandRing1': VRMHumanBoneName.RightRingProximal,
  'mixamorigRightHandRing2': VRMHumanBoneName.RightRingIntermediate,
  'mixamorigRightHandRing3': VRMHumanBoneName.RightRingDistal,
  'mixamorigRightHandPinky1': VRMHumanBoneName.RightLittleProximal,
  'mixamorigRightHandPinky2': VRMHumanBoneName.RightLittleIntermediate,
  'mixamorigRightHandPinky3': VRMHumanBoneName.RightLittleDistal,
};

/**
 * Get the world rest rotation of a bone by traversing up the hierarchy
 */
function getWorldRestRotation(bone) {
  const worldRot = new THREE.Quaternion();
  let current = bone;
  const chain = [];

  while (current) {
    chain.unshift(current);
    current = current.parent;
  }

  for (const node of chain) {
    const localRot = new THREE.Quaternion();
    // Rest pose rotation (initial quaternion)
    localRot.copy(node.quaternion);
    worldRot.multiply(localRot);
  }

  return worldRot;
}

/**
 * Retarget a single rotation keyframe from Mixamo space to VRM space
 *
 * Formula: parentRestWorldRot * animQ * inv(boneRestWorldRot)
 */
function retargetRotation(animQ, boneRestWorldRot, parentRestWorldRot) {
  const result = new THREE.Quaternion();
  result.copy(parentRestWorldRot);
  result.multiply(animQ);
  result.multiply(boneRestWorldRot.clone().invert());
  return result;
}

async function loadFileAsArrayBuffer(filePath) {
  const buffer = fs.readFileSync(filePath);
  return buffer.buffer.slice(buffer.byteOffset, buffer.byteOffset + buffer.byteLength);
}

async function main() {
  const args = process.argv.slice(2);

  if (args.length < 2) {
    console.log('Usage: node retarget.mjs <vrm-file> <fbx-file> [output.json]');
    console.log('');
    console.log('Example:');
    console.log('  node retarget.mjs assets/wolfman.vrm assets/idle.fbx assets/idle-retargeted.json');
    process.exit(1);
  }

  const [vrmPath, fbxPath, outputPath = 'assets/retargeted-animation.json'] = args;

  // Validate files exist
  if (!fs.existsSync(vrmPath)) {
    console.error(`VRM file not found: ${vrmPath}`);
    process.exit(1);
  }
  if (!fs.existsSync(fbxPath)) {
    console.error(`FBX file not found: ${fbxPath}`);
    process.exit(1);
  }

  console.log(`VRM:    ${vrmPath}`);
  console.log(`FBX:    ${fbxPath}`);
  console.log(`Output: ${outputPath}`);
  console.log('');

  // --- Load FBX animation ---
  console.log('Loading FBX animation...');
  const fbxBuffer = await loadFileAsArrayBuffer(fbxPath);
  const fbxLoader = new FBXLoader();
  const fbxScene = fbxLoader.parse(fbxBuffer, '');

  const animations = fbxScene.animations;
  if (!animations || animations.length === 0) {
    console.error('No animations found in FBX file');
    process.exit(1);
  }

  const clip = animations[0];
  console.log(`Animation: "${clip.name}", duration: ${clip.duration.toFixed(2)}s, tracks: ${clip.tracks.length}`);

  // --- Build Mixamo bone rest poses ---
  console.log('Building Mixamo skeleton rest poses...');
  const mixamoBones = {};

  fbxScene.traverse((obj) => {
    if (obj.isBone || obj.type === 'Bone') {
      mixamoBones[obj.name] = obj;
    }
  });

  // Get Mixamo hips height for position scaling
  const mixamoHips = mixamoBones['mixamorigHips'];
  const mixamoHipsHeight = mixamoHips ? mixamoHips.position.y : 1.0;
  console.log(`Mixamo hips height: ${mixamoHipsHeight.toFixed(4)}`);

  // --- Extract and retarget keyframes ---
  console.log('Retargeting animation tracks...');

  const retargetedTracks = [];
  let mappedCount = 0;
  let skippedCount = 0;

  for (const track of clip.tracks) {
    // Track names look like "mixamorigHips.quaternion" or "mixamorigHips.position"
    const dotIndex = track.name.indexOf('.');
    const boneName = track.name.substring(0, dotIndex);
    const property = track.name.substring(dotIndex + 1);

    const vrmBoneName = MIXAMO_TO_VRM[boneName];
    if (!vrmBoneName) {
      skippedCount++;
      continue;
    }

    const mixamoBone = mixamoBones[boneName];
    if (!mixamoBone) {
      skippedCount++;
      continue;
    }

    if (property === 'quaternion') {
      // Get rest poses for retargeting
      const boneRestWorldRot = getWorldRestRotation(mixamoBone);
      const parentRestWorldRot = mixamoBone.parent
        ? getWorldRestRotation(mixamoBone.parent)
        : new THREE.Quaternion();

      // Retarget each keyframe
      const values = [];
      for (let i = 0; i < track.values.length; i += 4) {
        const animQ = new THREE.Quaternion(
          track.values[i],
          track.values[i + 1],
          track.values[i + 2],
          track.values[i + 3]
        );
        const retargeted = retargetRotation(animQ, boneRestWorldRot, parentRestWorldRot);
        values.push(retargeted.x, retargeted.y, retargeted.z, retargeted.w);
      }

      retargetedTracks.push({
        bone: vrmBoneName,
        property: 'rotation',
        times: Array.from(track.times),
        values,
        interpolation: track.getInterpolation?.() ?? 'linear',
      });
      mappedCount++;

    } else if (property === 'position' && vrmBoneName === VRMHumanBoneName.Hips) {
      // Only retarget hip position (root motion)
      // Scale will be applied at load time based on VRM hips height
      const values = [];
      for (let i = 0; i < track.values.length; i += 3) {
        values.push(
          track.values[i],
          track.values[i + 1],
          track.values[i + 2]
        );
      }

      retargetedTracks.push({
        bone: vrmBoneName,
        property: 'position',
        times: Array.from(track.times),
        values,
        interpolation: 'linear',
        mixamoHipsHeight,
      });
      mappedCount++;
    }
  }

  console.log(`Mapped: ${mappedCount} tracks, Skipped: ${skippedCount} tracks`);

  // --- Write output ---
  const output = {
    version: 1,
    source: {
      vrm: path.basename(vrmPath),
      fbx: path.basename(fbxPath),
      generator: 'klaus-avatar-retarget',
    },
    animation: {
      name: clip.name,
      duration: clip.duration,
      fps: clip.tracks[0] ? Math.round(clip.tracks[0].times.length / clip.duration) : 30,
      mixamoHipsHeight,
    },
    tracks: retargetedTracks,
  };

  const outputDir = path.dirname(outputPath);
  if (!fs.existsSync(outputDir)) {
    fs.mkdirSync(outputDir, { recursive: true });
  }

  fs.writeFileSync(outputPath, JSON.stringify(output, null, 2));
  const sizeMB = (fs.statSync(outputPath).size / 1024 / 1024).toFixed(2);
  console.log(`\nWrote ${outputPath} (${sizeMB} MB)`);
  console.log('Done.');
}

main().catch((err) => {
  console.error('Fatal:', err.message);
  process.exit(1);
});
