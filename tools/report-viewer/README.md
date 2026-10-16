# HTML report viewer asset

`viewer.js` is the source for the browser half of Antenna Turtle's portable
simulation report. It is bundled so an exported report never needs a network
connection, package manager, web server, or `file:` fetch.

Rebuild with `npm install && npm run build`. The dependency versions are pinned
in `package.json`; the checked-in bundle is a runtime asset, not a generated
simulation report. Three.js is MIT licensed; its license is retained beside the
bundle.

During viewer development, `npm run refresh -- REPORT.html` replaces only the
embedded viewer bundle in an existing report. It deliberately leaves the large,
compressed geometry and field-data JSON untouched, so visual changes can be
tested without rerunning openEMS or recompressing captures.

`npm test` checks both Poynting-vector math and Milestone 3 surface boundary
conditions. The latter covers one- and two-sided `n × delta-H` current,
normal-`D` free charge, complex magnitude, and RF phase reconstruction.

`npm run validate:surface -- REPORT.html` additionally reconstructs the solid
dipole fixture from its embedded geometry and shell captures. Pass `generic`
after the report path for an arbitrary triangulated model such as the Moxon
array; that profile checks geometry association plus finite, nonzero current
and charge without imposing a dipole-specific axial distribution.
