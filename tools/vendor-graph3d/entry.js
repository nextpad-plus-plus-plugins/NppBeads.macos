// Single classic-script bundle for the Graph view's 3D mode. three.js no
// longer ships a UMD build, and graph.js needs THREE itself (node meshes),
// so one bundle exposes everything with a single shared copy of three.
//
// Rebuild: cd tools/vendor-graph3d && npm ci && npm run build
import ForceGraph3D from '3d-force-graph';
import * as THREE from 'three';
import SpriteText from 'three-spritetext';
import * as d3Force3d from 'd3-force-3d';

window.ForceGraph3D = ForceGraph3D;
window.THREE = THREE;
window.SpriteText = SpriteText;
window.d3Force3d = d3Force3d;
