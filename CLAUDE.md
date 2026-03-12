# Klaus Avatar

Animated 3D wolf avatar for Klaus (Maxwell's AI assistant).

## Stack
- **VRM model**: Avatar 035 Wolfman from opensourceavatars.com (CC0)
- **Animation**: Mixamo FBX → retargeted for VRM humanoid skeleton
- **Retargeting**: @pixiv/three-vrm formula (`parentRestWorldRot * animQ * inv(boneRestWorldRot)`)
- **Viewer**: three.js + @pixiv/three-vrm in browser (drag-and-drop VRM + FBX)
- **Target**: SceneKit + VRMKit for native macOS rendering, Mission Control integration

## Structure
```
assets/          # VRM model + FBX animations + retargeted JSON
scripts/         # Node.js retargeting pipeline
viewer/          # Browser-based viewer (drag & drop)
```

## Commands
```bash
npm install                           # Install deps
npx serve viewer -p 8888             # Launch viewer at localhost:8888
node scripts/retarget.mjs <vrm> <fbx> [output.json]  # CLI retarget
```

## Pipeline
1. Load VRM (wolfman.vrm) in viewer
2. Drop Mixamo FBX animation → auto-retargets and plays
3. Export retargeted JSON for SceneKit consumption
4. Render in Mission Control or as Telegram stickers

## Next Steps
- [ ] Download Mixamo idle animation (Breathing Idle, FBX Without Skin)
- [ ] Test retargeting in viewer
- [ ] Build SceneKit/VRMKit Swift renderer
- [ ] Integrate into Mission Control dashboard
- [ ] Generate animated stickers for Telegram
