# Polarization Workbench M5 Far-Field Trajectories

## Goal

Overlay readable tangent-plane polarization trajectories on the accepted M4
surface. Ellipse shape communicates axial ratio, major-axis orientation
communicates polarization tilt, and a globally phase-coherent bead shows the
instantaneous E-field position and direction of rotation.

## Geometry

- Each glyph is centered just outside the ARRL total-gain surface at one
  sampled propagation direction.
- Clearance is curvature-aware rather than a fixed radial offset: perimeter
  probes trace the actual rendered surface and lift the complete ring only as
  far as needed to clear steep gradients and neighboring triangles.
- The major and minor axes are constructed in the local spherical
  `E_theta`/`E_phi` tangent basis using the analyzed tilt and axial ratio.
- Glyph major-axis size is constant in model space. Perspective may change its
  apparent size slightly, but gain and field magnitude never change it.
- Linear states render as a narrow blade, circular states as a circle, and
  elliptical states with minor/major ratio `1 / axial-ratio`. The blade has a
  small diagrammatic minimum width so an exact linear state stays visible.
- Each glyph is an unfilled white ribbon, with a shallow extrusion so oblique
  views retain some thickness. A white spherical bead travels around the path
  using the complex `E_theta` and `E_phi` phase supplied by the solver.

## Sampling and controls

- `SHOW GLYPHS` toggles the complete overlay without changing the accepted M4
  surface, camera, or selection state, enabling direct A/B evaluation. The
  overlay defaults to off so the accepted surface remains the primary view.
- A `TARGET GLYPH SPACING` slider sets the desired surface-space separation at
  peak gain. Its limits are derived from the grid resolution.
- Sampling is greedily distributed over the displayed ARRL surface. Large
  lobes receive more glyphs, while collapsed weak lobes receive fewer instead
  of packing equal angular samples into a tiny area.
- The densest end approaches every solver sample; the initial peak-lobe target
  is approximately 10 degrees.
- Available 0/90/180-degree theta samples and 0/90/180/270-degree phi samples
  are always included. Duplicate pole glyphs collapse to one stable glyph.
- Density changes rebuild only the glyph decoration and cached scene. Camera
  motion continues to replace only the camera.

## Automated acceptance

1. Tangent frames are orthonormal and perpendicular to propagation.
2. Exact linear, 2:1 elliptical, and circular fixtures produce the expected
   minor/major ratios and tilt orientations.
3. Sampling is deterministic, follows displayed surface area, includes
   available axial/cardinal directions, and deduplicates poles.
4. The native PoC opens and closes with the glyph layer disabled by default.
5. Existing tests and the full suite remain green.

## Manual acceptance

1. The dipole displays line glyphs aligned with its linear polarization.
2. The quadrature crossed dipoles display circles in circular regions and
   progressively flatter, correctly tilted ellipses through transitions.
3. The helix main lobe displays near-circular glyphs; rear/side regions expose
   their differing axial ratios and tilts.
4. White rings and beads remain readable over every M3/M4 color and at oblique
   camera angles.
5. Back-side glyphs remain hidden by the opaque surface.
6. Move the spacing slider from every sample to its coarsest value and confirm
   that large/strong lobes gain density before small/weak lobes, placement is
   stable, and orbit/zoom remain responsive during bead animation.
7. Toggle the overlay repeatedly and decide whether glyphs add useful intuition
   or make the accepted surface view unnecessarily busy.
