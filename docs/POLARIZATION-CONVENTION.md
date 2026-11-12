# Polarization Convention

Antenna Turtle represents frequency-domain electric fields as complex phasors
and reconstructs an instantaneous field as

```text
Re(E exp(j omega t)).
```

For antenna-facing RHCP and LHCP labels, the observer stands behind the
antenna and looks outward in the direction of propagation. Clockwise electric
field rotation from that viewpoint is right-hand circular polarization
(RHCP); counterclockwise rotation is left-hand circular polarization (LHCP).

For transverse spherical components `(E_theta, E_phi)`, Antenna Turtle uses

```text
S0 = |E_theta|^2 + |E_phi|^2
S1 = |E_theta|^2 - |E_phi|^2
S2 = 2 Re(E_theta conjugate(E_phi))
S3 = 2 Im(E_theta conjugate(E_phi)).
```

Consequently, normalized `(E_theta, E_phi) = (1, -j) / sqrt(2)` is RHCP and
has `S3/S0 = +1`; changing `-j` to `+j` is LHCP and has `S3/S0 = -1`.
Signed circularity is `S3/S0`.

The circular components are

```text
E_R = (E_theta + j E_phi) / sqrt(2)
E_L = (E_theta - j E_phi) / sqrt(2).
```

They obey `|E_R|^2 + |E_L|^2 = S0` and
`|E_R|^2 - |E_L|^2 = S3`.

The ellipse tilt is `atan2(S2, S1) / 2`. Ellipticity is
`asin(S3/S0) / 2`, ranging from -45 degrees for LHCP through zero for linear
polarization to +45 degrees for RHCP. Axial ratio is the major-to-minor field
ratio: 1 for circular polarization and positive infinity for linear
polarization. Tilt is undefined for a perfect circle, and all normalized
polarization quantities are undefined for a zero field.

These definitions describe the local transverse basis for each propagation
direction. They do not impose a single global horizontal/vertical basis on
the radiation sphere.

## Operator-facing reference

The viewpoint and clockwise-RHCP terminology follow AMSAT's operator-facing
usage. Its polarization article describes an observer standing behind the
antenna, looking toward maximum gain, and identifies clockwise field rotation
as RHCP:

- [AMSAT Journal, March/April 2007 — Polarization, Part 1](https://www.amsat.org/amsat/articles/i8cvs/Part_1_AMSATJournal_MarApr07_I8CVS_Polarization-1.pdf)
- [AMSAT beginner compilation](https://amsat.org/wordpress/wp-content/uploads/2023/06/For_Beginners_Compilation.pdf)
