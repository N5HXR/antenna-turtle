#lang racket/base

(require file/sha1
         json
         racket/file
         racket/format
         racket/list
         racket/match
         racket/math
         racket/path
         racket/port
         racket/runtime-path
         racket/string
         racket/system
         (prefix-in m: manifold)
         "core.rkt"
         "nec2c.rkt"
         "network.rkt"
         "openems-material.rkt"
         "solid-core.rkt"
         "wire-solid.rkt")

(provide
 octave-executable
 (struct-out openems-artifacts)
 (struct-out openems-run-info)
 (struct-out openems-port-sample)
 (struct-out openems-sweep-result)
 (struct-out openems-result-port)
 (struct-out openems-s-parameter-sample)
 (struct-out openems-multiport-result)
 (struct-out exn:fail:openems)
 openems-sweep
 openems-load-artifacts
 openems-radiation-grid
 openems-sweep->network-sweep
 openems-close!
 parse-openems-port-results
 parse-openems-s-parameter-results
 parse-openems-nf2ff-results)

(struct openems-artifacts
  (directory driver-path simulation-directory manifest-path
             temporary? available?)
  #:mutable
  #:transparent)

(struct openems-run-info
  (octave-executable elapsed-ms exit-code stdout stderr artifacts manifest)
  #:transparent)

(struct openems-port-sample
  (frequency-mhz reflection-coefficient impedance s11-db)
  #:transparent)

(struct openems-sweep-result
  (run port-name reference-impedance samples)
  #:transparent)

(struct openems-result-port (name reference-impedance) #:transparent)

(struct openems-s-parameter-sample
  (frequency-mhz output-port input-port value db)
  #:transparent)

(struct openems-multiport-result
  (run ports s-parameters input-samples)
  #:transparent)

(struct exn:fail:openems exn:fail (run-info) #:transparent)

(struct exported-body
  (name filename material priority minimum maximum sha1 triangles
        metal-thickness surface-facets)
  #:transparent)

(struct exported-facet (points-2d transform plane-axis plane-coordinate)
  #:transparent)

(struct exported-sheet
  (name material priority points-2d transform minimum maximum mesh-edges thickness
        polygons-2d boundaries-2d trace-width)
  #:transparent)

(struct exported-mesh-constraint
  (kind plane user-point solver-point axes)
  #:transparent)

(define octave-executable
  (make-parameter
   #f
   (lambda (value)
     (unless (or (not value) (path-string? value))
       (raise-argument-error 'octave-executable "(or/c #f path-string?)" value))
     value)))

;; Distribution packages commonly register openEMS as Octave packages, while
;; upstream installs (including update_openEMS.sh) install ordinary .m files
;; below PREFIX/share. Support both layouts and prefer an explicit root.
(define (write-octave-openems-loader line)
  (line "if exist('InitFDTD', 'file') ~~= 2")
  (line "  openems_root = getenv('OPENEMS_ROOT');")
  (line "  if isempty(openems_root), openems_root = '/usr/local'; end")
  (line "  addpath([openems_root '/share/CSXCAD/matlab']);")
  (line "  addpath([openems_root '/share/openEMS/matlab']);")
  (line "  if exist([openems_root '/share/CTB/matlab'], 'dir'), addpath([openems_root '/share/CTB/matlab']); end")
  (line "end")
  (line "if exist('InitFDTD', 'file') ~~= 2")
  (line "  try, pkg load openems; pkg load csxcad; catch, end")
  (line "end")
  (line "if exist('InitFDTD', 'file') ~~= 2 || exist('InitCSX', 'file') ~~= 2")
  (line "  error('openEMS Octave interface not found; set OPENEMS_ROOT to its installation prefix');")
  (line "end"))

(define speed-of-light 299792458.0)
(define default-maximum-timesteps 100000)
(define default-end-criteria 1e-5)
(define default-minimum-dielectric-cells 4)
(define default-minimum-trace-cells 3)
(define identity-rigid-transform
  '((1 0 0 0) (0 1 0 0) (0 0 1 0)))
(define-runtime-path openems-progress-path "openems-progress.rkt")

(define openems-progress-line-rx
  #px"\\[@[[:space:]]+([^]]+)\\][[:space:]]+Timestep:[[:space:]]+([0-9]+).*Speed:[[:space:]]+([0-9.]+)[[:space:]]+MC/s.*Energy:.*\\([[:space:]]*([+-]?[[:space:]]*[0-9.]+)dB\\)")
(define openems-excitation-line-rx
  #px"Antenna Turtle excitation ([0-9]+) of ([0-9]+)")

(define (finite-real? value)
  (and (real? value) (rational? value)))

(define (positive-real who value description)
  (unless (and (finite-real? value) (> value 0))
    (raise-arguments-error who
                           (format "~a must be a positive finite real" description)
                           description value))
  value)

(define (resolve-octave requested)
  (define candidate
    (or requested
        (octave-executable)
        (getenv "OCTAVE")
        (find-executable-path "octave")))
  (unless candidate
    (raise-user-error
     'openems
     (string-append
      "could not find GNU Octave; set (octave-executable), the OCTAVE "
      "environment variable, or PATH")))
  (define complete (simplify-path (path->complete-path candidate)))
  (unless (file-exists? complete)
    (raise-user-error 'openems "Octave executable does not exist: ~a" complete))
  complete)

(define (point->list point)
  (list (point3-x point) (point3-y point) (point3-z point)))

(define (m-point->list point)
  (list (m:point3-x point) (m:point3-y point) (m:point3-z point)))

(define (dot first second)
  (for/sum ([a (in-list first)] [b (in-list second)]) (* a b)))

(define (cross first second)
  (match-define (list ax ay az) first)
  (match-define (list bx by bz) second)
  (list (- (* ay bz) (* az by))
        (- (* az bx) (* ax bz))
        (- (* ax by) (* ay bx))))

(define (normalize who vector)
  (define magnitude (sqrt (dot vector vector)))
  (when (zero? magnitude) (error who "direction vector must be nonzero"))
  (map (lambda (value) (/ value magnitude)) vector))

;; Use the complete turtle-local port frame rather than merely aligning its
;; direction. This fixes the otherwise-underdetermined roll and maps width,
;; depth, and gap onto solver X, Y, and Z respectively without reflection.
(define (port-user->solver-transform port)
  (define direction
    (normalize 'openems (point->list (lumped-port-direction port))))
  (define transverse-u
    (normalize 'openems (point->list (lumped-port-transverse-u port))))
  (define transverse-v (normalize 'openems (cross direction transverse-u)))
  (define center (point->list (lumped-port-center port)))
  (for/list ([row (in-list (list transverse-u transverse-v direction))])
    (append row (list (- (dot row center))))))

(define (signed-axis? vector)
  (define values (point->list vector))
  (and (= (length (filter (lambda (value) (> (abs value) 1e-8)) values)) 1)
       (for/and ([value (in-list values)])
         (or (< (abs value) 1e-8)
             (< (abs (- (abs value) 1)) 1e-8)))))

(define (signed-axis-index values)
  (define nonzero
    (for/list ([value (in-list values)] [axis (in-naturals)]
               #:when (> (abs value) 1e-8))
      axis))
  (and (= (length nonzero) 1)
       (for/and ([value (in-list values)])
         (or (< (abs value) 1e-8)
             (< (abs (- (abs value) 1)) 1e-8)))
       (first nonzero)))

(define (validate-multiport-alignment! ports)
  (define reference-impedances
    (remove-duplicates (map lumped-port-impedance ports) =))
  (unless (= (length reference-impedances) 1)
    (raise-user-error
     'openems-sweep
     (string-append
      "the initial multiport backend requires every port to use the same "
      "reference impedance; mixed-impedance power-wave normalization is "
      "not implemented yet")))
  (for ([port (in-list ports)])
    (unless (and (signed-axis? (lumped-port-direction port))
                 (signed-axis? (lumped-port-transverse-u port))
                 (signed-axis? (lumped-port-transverse-v port)))
      (raise-user-error
       'openems-sweep
       (string-append
        "multiport models are not rotated automatically; port ~a must have "
        "its direction, width, and depth axes aligned with the model's "
        "global X/Y/Z axes")
       (lumped-port-name port)))))

(define (simulation-transform ports)
  (if (= (length ports) 1)
      (port-user->solver-transform (first ports))
      (begin
        (validate-multiport-alignment! ports)
        identity-rigid-transform)))

(define (transform-port port transform)
  (lumped-port
   (lumped-port-name port)
   (lumped-port-impedance port)
   (apply point3 (transform-point transform (lumped-port-center port)))
   (apply point3 (transform-vector transform (lumped-port-direction port)))
   (apply point3 (transform-vector transform (lumped-port-transverse-u port)))
   (apply point3 (transform-vector transform (lumped-port-transverse-v port)))
   (lumped-port-gap port)
   (lumped-port-width port)
   (lumped-port-depth port)
   (lumped-port-priority port)
   (lumped-port-placement-transform port)))

(define (transform-component component transform)
  (lumped-component
   (lumped-component-name component)
   (lumped-component-resistance component)
   (lumped-component-inductance component)
   (lumped-component-capacitance component)
   (lumped-component-topology component)
   (lumped-component-caps component)
   (apply point3 (transform-point transform (lumped-component-center component)))
   (apply point3 (transform-vector transform (lumped-component-direction component)))
   (apply point3 (transform-vector transform (lumped-component-transverse-u component)))
   (apply point3 (transform-vector transform (lumped-component-transverse-v component)))
   (lumped-component-gap component)
   (lumped-component-width component)
   (lumped-component-depth component)
   (lumped-component-priority component)
   (lumped-component-placement-transform component)))

(define (validate-component-alignment! components)
  (for ([component (in-list components)])
    (unless (and (signed-axis? (lumped-component-direction component))
                 (signed-axis? (lumped-component-transverse-u component))
                 (signed-axis? (lumped-component-transverse-v component)))
      (raise-user-error
       'openems-sweep
       (string-append
        "lumped element ~a is not aligned with the OpenEMS Yee grid after "
        "the model-to-solver transform; align its turtle frame with the grid")
       (lumped-component-name component)))))

(define (transform-mesh-constraint constraint transform)
  (define user-point (point->list (mesh-constraint-point constraint)))
  (define solver-point
    (transform-point transform (mesh-constraint-point constraint)))
  (case (mesh-constraint-kind constraint)
    [(point)
     (exported-mesh-constraint
      'point #f user-point solver-point '(0 1 2))]
    [(plane)
     (define solver-normal
       (transform-vector transform (mesh-constraint-normal constraint)))
     (define axis (signed-axis-index solver-normal))
     (unless axis
       (raise-user-error
        'openems-sweep
        (string-append
         "mesh plane ~a at ~a is not aligned with the OpenEMS Yee grid after "
         "the model-to-solver rotation; use mesh-point, align the port/model, "
         "or remove the plane constraint")
        (mesh-constraint-plane constraint)
        user-point))
     (exported-mesh-constraint
      'plane (mesh-constraint-plane constraint)
      user-point solver-point (list axis))]
    [else
     (error 'openems-sweep "unknown mesh constraint kind: ~e"
            (mesh-constraint-kind constraint))]))

(define (mesh-constraint-manifest constraint)
  (hash 'kind (symbol->string (exported-mesh-constraint-kind constraint))
        'plane (or (and (exported-mesh-constraint-plane constraint)
                        (symbol->string
                         (exported-mesh-constraint-plane constraint)))
                   'null)
        'user_point_m
        (map exact->inexact (exported-mesh-constraint-user-point constraint))
        'solver_point_m
        (map exact->inexact (exported-mesh-constraint-solver-point constraint))
        'solver_axes (exported-mesh-constraint-axes constraint)))

(define (inverse-rigid-transform transform)
  (define rotation (map (lambda (row) (take row 3)) transform))
  (define inverse-rotation (apply map list rotation))
  (define translation (map fourth transform))
  (define inverse-translation
    (for/list ([row (in-list inverse-rotation)])
      (- (dot row translation))))
  (for/list ([row (in-list inverse-rotation)]
             [offset (in-list inverse-translation)])
    (append row (list offset))))

(define (number-string value)
  (~r (exact->inexact value) #:precision '(= 17)))

(define (octave-vector values)
  (format "[~a]" (string-join (map number-string values) " ")))

(define (octave-point-matrix points)
  (format "[~a; ~a]"
          (string-join (map (lambda (point) (number-string (first point))) points) " ")
          (string-join (map (lambda (point) (number-string (second point))) points) " ")))

(define (csx-matrix-string matrix)
  (define homogeneous
    (append (map (lambda (row) (append (take row 3) (list (fourth row)))) matrix)
            (list '(0 0 0 1))))
  ;; CSTransform::Transform indexes the serialized matrix as 4*row+column.
  (string-join
   (append* (map (lambda (row) (map number-string row)) homogeneous))
   ","))

(define (matrix->lists matrix)
  (for/list ([row (in-list matrix)])
    (map exact->inexact row)))

(define (transform-point transform point)
  (define coordinates (point->list point))
  (for/list ([row (in-list transform)])
    (+ (dot (take row 3) coordinates) (fourth row))))

(define (transform-vector transform point)
  (define coordinates (point->list point))
  (for/list ([row (in-list transform)])
    (dot (take row 3) coordinates)))

(define (sanitize-label value)
  (define source (if (symbol? value) (symbol->string value) value))
  (define cleaned (regexp-replace* #px"[^A-Za-z0-9_]+" source "_"))
  (if (regexp-match? #px"^[A-Za-z]" cleaned)
      cleaned
      (string-append "g_" cleaned)))

(define (file-sha1 path)
  (call-with-input-file path sha1))

(define (material-manifest material start-mhz stop-mhz)
  (define model-frequency-mhz (model-frequency))
  (define loss (em-material-loss-spec material))
  (hash 'name (format "~a" (em-material-name material))
        'kind (format "~a" (em-material-kind material))
        'relative_permittivity (or (em-material-relative-permittivity material) 'null)
        'relative_permeability (or (em-material-relative-permeability material) 'null)
        'electric_conductivity_s_per_m
        (if (eq? (em-material-kind material) 'dielectric)
            (dielectric-effective-conductivity material model-frequency-mhz)
            (or (em-material-electric-conductivity material) 'null))
        'magnetic_conductivity (or (em-material-magnetic-conductivity material) 'null)
        'thickness_m (or (em-material-thickness material) 'null)
        'loss_tangent (if loss (material-loss-value loss) 'null)
        'loss_reference_frequency_mhz
        (or (dielectric-reference-frequency-mhz material model-frequency-mhz) 'null)
        'effective_loss_tangent_at_sweep_start
        (if loss
            (dielectric-effective-loss-tangent material start-mhz model-frequency-mhz)
            'null)
        'effective_loss_tangent_at_sweep_stop
        (if loss
            (dielectric-effective-loss-tangent material stop-mhz model-frequency-mhz)
            'null)))

(define (body-manifest body start-mhz stop-mhz)
  (hash 'representation
        (if (eq? (em-material-kind (exported-body-material body)) 'conductor)
            "rectilinear-conducting-boundary"
            "volume-stl")
        'name (format "~a" (exported-body-name body))
        'file (or (exported-body-filename body) 'null)
        'sha1 (or (exported-body-sha1 body) 'null)
        'priority (exported-body-priority body)
        'material (material-manifest (exported-body-material body) start-mhz stop-mhz)
        'minimum (map exact->inexact (exported-body-minimum body))
        'maximum (map exact->inexact (exported-body-maximum body))
        'triangle_count (exported-body-triangles body)
        'metal_thickness_m (or (exported-body-metal-thickness body) 'null)
        'effective_metal_thickness_m
        (if (exported-body-metal-thickness body)
            (conductor-effective-sheet-thickness
             (exported-body-material body)
             (exported-body-metal-thickness body)
             (model-frequency))
            'null)
        'surface_facet_count (length (exported-body-surface-facets body))))

(define (axis-aligned-surface-facets who name solid)
  (define mesh (m:solid->mesh solid))
  (define vertices (m:mesh-vertices mesh))
  (for/list ([face (in-vector (m:mesh-triangles mesh))])
    (define points
      (for/list ([index (in-list (list (m:triangle-a face)
                                       (m:triangle-b face)
                                       (m:triangle-c face)))])
        (m-point->list (vector-ref vertices index))))
    (define scale
      (max 1 (for*/fold ([maximum 0]) ([point (in-list points)]
                                       [coordinate (in-list point)])
               (max maximum (abs coordinate)))))
    (define flat-axes
      (for/list ([axis (in-range 3)]
                 #:when
                 (<= (- (apply max (map (lambda (p) (list-ref p axis)) points))
                        (apply min (map (lambda (p) (list-ref p axis)) points)))
                     (* 1e-9 scale)))
        axis))
    (unless (= (length flat-axes) 1)
      (raise-arguments-error
       who
       "finite-conductivity bodies require every boundary facet to align with the Yee grid"
       "body" name "triangle" points))
    (define normal-axis (first flat-axes))
    (define in-plane-axes (remove normal-axis '(0 1 2)))
    (define origin (first points))
    (define u
      (for/list ([axis (in-range 3)])
        (if (= axis (first in-plane-axes)) 1 0)))
    (define v
      (for/list ([axis (in-range 3)])
        (if (= axis (second in-plane-axes)) 1 0)))
    (define n
      (for/list ([axis (in-range 3)])
        (if (= axis normal-axis) 1 0)))
    (define transform
      (for/list ([axis (in-range 3)])
        (list (list-ref u axis) (list-ref v axis) (list-ref n axis)
              (list-ref origin axis))))
    (define points-2d
      (for/list ([point (in-list points)])
        (list (- (list-ref point (first in-plane-axes))
                 (list-ref origin (first in-plane-axes)))
              (- (list-ref point (second in-plane-axes))
                 (list-ref origin (second in-plane-axes))))))
    (exported-facet points-2d transform normal-axis
                    (list-ref origin normal-axis))))

(define (sheet-manifest sheet start-mhz stop-mhz)
  (hash 'representation "planar-polygon"
        'name (format "~a" (exported-sheet-name sheet))
        'priority (exported-sheet-priority sheet)
        'material (material-manifest (exported-sheet-material sheet) start-mhz stop-mhz)
        'thickness_m (or (exported-sheet-thickness sheet) 'null)
        'effective_thickness_m
        (if (and (exported-sheet-thickness sheet)
                 (memq (em-material-kind (exported-sheet-material sheet))
                        '(conductor conducting-sheet)))
            (conductor-effective-sheet-thickness
             (exported-sheet-material sheet)
             (exported-sheet-thickness sheet)
             (model-frequency))
            'null)
        'points_2d (map (lambda (point) (map exact->inexact point))
                        (exported-sheet-points-2d sheet))
        'polygon_count (length (exported-sheet-polygons-2d sheet))
        'local_to_solver_transform (matrix->lists (exported-sheet-transform sheet))
        'minimum (map exact->inexact (exported-sheet-minimum sheet))
        'maximum (map exact->inexact (exported-sheet-maximum sheet))
        'mesh_edges (symbol->string (exported-sheet-mesh-edges sheet))))

(define (component-manifest component priority)
  (define-values (minimum maximum) (component-bounds component))
  (hash 'representation "lumped-element"
        'name (format "~a" (lumped-component-name component))
        'resistance_ohms (or (lumped-component-resistance component) 'null)
        'inductance_henries (or (lumped-component-inductance component) 'null)
        'capacitance_farads (or (lumped-component-capacitance component) 'null)
        'topology (symbol->string (lumped-component-topology component))
        'caps (lumped-component-caps component)
        'gap_m (lumped-component-gap component)
        'width_m (lumped-component-width component)
        'depth_m (lumped-component-depth component)
        'minimum_m (map exact->inexact minimum)
        'maximum_m (map exact->inexact maximum)
        'direction (map exact->inexact
                        (point->list (lumped-component-direction component)))
        'priority priority
        'priority_source
        (if (lumped-component-priority component) "explicit" "automatic")))

(define (json-safe value)
  (cond
    [(hash? value)
     (for/hash ([(key item) (in-hash value)])
       (values key (json-safe item)))]
    [(list? value) (map json-safe value)]
    [(and (number? value) (exact? value)) (exact->inexact value)]
    [else value]))

(define (write-manifest directory manifest)
  (define rktd-path (build-path directory "simulation-manifest.rktd"))
  (define json-path (build-path directory "simulation-manifest.json"))
  (call-with-output-file rktd-path
    #:exists 'truncate/replace
    (lambda (out) (write manifest out) (newline out)))
  (call-with-output-file json-path
    #:exists 'truncate/replace
    (lambda (out) (write-json (json-safe manifest) out) (newline out)))
  rktd-path)

(define (transform-and-export-bodies directory transform)
  (for/list ([body (in-list (model-bodies))]
             [index (in-naturals 1)])
    (unless (memq (em-material-kind (solid-body-material body))
                  '(pec dielectric conductor))
      (raise-arguments-error
       'openems-sweep
       "OpenEMS volume bodies must use PEC, dielectric, or conductor material"
       "body" (solid-body-name body)
       "material" (solid-body-material body)))
    (define transformed (m:transform (solid-body-solid body) transform))
    (dynamic-wind
      void
      (lambda ()
        (define conductor?
          (eq? (em-material-kind (solid-body-material body)) 'conductor))
        (define filename (and (not conductor?) (format "body-~a.stl" index)))
        (define path (and filename (build-path directory filename)))
        (unless conductor?
          (m:write-stl transformed path #:name (sanitize-label (solid-body-name body))))
        (define-values (minimum maximum) (m:solid-bounds transformed))
        (exported-body
         (solid-body-name body)
         filename
         (solid-body-material body)
         (or (solid-body-priority body) 10)
         (m-point->list minimum)
         (m-point->list maximum)
         (and path (file-sha1 path))
         (m:solid-num-triangles transformed)
         (solid-body-metal-thickness body)
         (if conductor?
             (axis-aligned-surface-facets
              'openems-sweep (solid-body-name body) transformed)
             '())))
      (lambda () (m:solid-close! transformed)))))

(define (list-subtract first second)
  (map - first second))

(define (transform-and-export-sheets transform)
  (for/list ([sheet (in-list (model-sheets))])
    (define polygons
      (for/list ([polygon (in-list (planar-sheet-polygons sheet))])
        (map (lambda (point) (transform-point transform point)) polygon)))
    (define boundaries
      (for/list ([boundary (in-list (planar-sheet-boundaries sheet))])
        (map (lambda (point) (transform-point transform point)) boundary)))
    ;; Use the sheet's authoritative outline to establish a stable local
    ;; frame. Its fill polygons may have been triangulated for concavity.
    (define points
      (map (lambda (point) (transform-point transform point))
           (planar-sheet-points sheet)))
    (define origin (first points))
    (define u (normalize 'openems-sweep (list-subtract (second points) origin)))
    (define transformed-normal
      (normalize 'openems-sweep
                 (transform-vector transform (planar-sheet-normal sheet))))
    ;; Recompute v from n and u to remove floating-point drift while retaining
    ;; the source polygon's orientation in its local XY plane.
    (define v (normalize 'openems-sweep (cross transformed-normal u)))
    (define points-2d
      (for/list ([point (in-list points)])
        (define offset (list-subtract point origin))
        (list (dot offset u) (dot offset v))))
    (define (project-polygon polygon)
      (for/list ([point (in-list polygon)])
        (define offset (list-subtract point origin))
        (list (dot offset u) (dot offset v))))
    (define polygons-2d (map project-polygon polygons))
    (define boundaries-2d (map project-polygon boundaries))
    ;; The polygon lives in local z=0, so the transform's basis columns are u,
    ;; v, and n; csx-matrix-string serializes the matrix row-major for CSXCAD.
    (define local-to-solver
      (list (list (first u) (first v) (first transformed-normal) (first origin))
            (list (second u) (second v) (second transformed-normal) (second origin))
            (list (third u) (third v) (third transformed-normal) (third origin))))
    (define all-points (append* polygons))
    (define minimum
      (for/list ([axis (in-range 3)]) (apply min (map (lambda (p) (list-ref p axis)) all-points))))
    (define maximum
      (for/list ([axis (in-range 3)]) (apply max (map (lambda (p) (list-ref p axis)) all-points))))
    (exported-sheet (planar-sheet-name sheet)
                    (planar-sheet-material sheet)
                    (or (planar-sheet-priority sheet) 10)
                    points-2d local-to-solver minimum maximum
                    (planar-sheet-mesh-edges sheet)
                    (planar-sheet-thickness sheet)
                    polygons-2d boundaries-2d
                    (planar-sheet-trace-width sheet))))

(define (geometry-minimum geometry)
  (if (exported-body? geometry)
      (exported-body-minimum geometry)
      (exported-sheet-minimum geometry)))

(define (geometry-maximum geometry)
  (if (exported-body? geometry)
      (exported-body-maximum geometry)
      (exported-sheet-maximum geometry)))

(define (geometry-material geometry)
  (if (exported-body? geometry)
      (exported-body-material geometry)
      (exported-sheet-material geometry)))

(define (geometry-priority geometry)
  (if (exported-body? geometry)
      (exported-body-priority geometry)
      (exported-sheet-priority geometry)))

(define (bounds-intersect? geometry minimum maximum [relative-tolerance 1e-12])
  (for/and ([low (in-list (geometry-minimum geometry))]
            [high (in-list (geometry-maximum geometry))]
            [other-low (in-list minimum)]
            [other-high (in-list maximum)])
    (define tolerance
      (* relative-tolerance
         (max 1 (abs low) (abs high) (abs other-low) (abs other-high))))
    (and (<= low (+ other-high tolerance))
         (<= other-low (+ high tolerance)))))

(define (oriented-box-bounds center-point direction-point u-point v-point
                             gap width depth)
  (define center (point->list center-point))
  (define axes
    (list (point->list u-point) (point->list v-point)
          (point->list direction-point)))
  (define half-extents
    (list (/ width 2) (/ depth 2) (/ gap 2)))
  (define corners
    (for*/list ([u-sign (in-list '(-1 1))]
                [v-sign (in-list '(-1 1))]
                [d-sign (in-list '(-1 1))])
      (for/list ([coordinate (in-list center)] [axis-index (in-naturals)])
        (+ coordinate
           (for/sum ([axis (in-list axes)]
                     [extent (in-list half-extents)]
                     [sign (in-list (list u-sign v-sign d-sign))])
             (* sign extent (list-ref axis axis-index)))))))
  (values (for/list ([axis (in-range 3)])
            (apply min (map (lambda (corner) (list-ref corner axis)) corners)))
          (for/list ([axis (in-range 3)])
            (apply max (map (lambda (corner) (list-ref corner axis)) corners)))))

(define (port-bounds port)
  (oriented-box-bounds
   (lumped-port-center port) (lumped-port-direction port)
   (lumped-port-transverse-u port) (lumped-port-transverse-v port)
   (lumped-port-gap port) (lumped-port-width port) (lumped-port-depth port)))

(define (component-bounds component)
  (oriented-box-bounds
   (lumped-component-center component) (lumped-component-direction component)
   (lumped-component-transverse-u component)
   (lumped-component-transverse-v component)
   (lumped-component-gap component) (lumped-component-width component)
   (lumped-component-depth component)))

(define (derive-port-priority geometry port)
  ;; A lumped port must replace dielectric inside its box, while the metal at
  ;; either terminal must remain authoritative.  Follow the ordering used by
  ;; the OpenEMS patch reference: dielectric < port < conductor.  Restrict the
  ;; calculation to geometry touching the port so unrelated scene priorities
  ;; do not constrain it.
  (or
   (lumped-port-priority port)
   (let ()
     (define-values (minimum maximum) (port-bounds port))
     (define touching
       (filter (lambda (item) (bounds-intersect? item minimum maximum)) geometry))
     (define dielectric-priorities
       (for/list ([item (in-list touching)]
                  #:when (eq? (em-material-kind (geometry-material item))
                              'dielectric))
         (geometry-priority item)))
     (define conductor-priorities
       (for/list ([item (in-list touching)]
                  #:when (memq (em-material-kind (geometry-material item))
                               '(pec conductor conducting-sheet)))
         (geometry-priority item)))
     (cond
       [(and (pair? dielectric-priorities) (pair? conductor-priorities))
        (define dielectric-priority (apply max dielectric-priorities))
        (define conductor-priority (apply min conductor-priorities))
        (unless (>= (- conductor-priority dielectric-priority) 2)
          (raise-user-error
           'openems-sweep
           (string-append
            "geometry touching the port must leave an integer priority between "
            "the dielectric and conductor priorities")
           "dielectric priority" dielectric-priority
           "conductor priority" conductor-priority))
        (quotient (+ dielectric-priority conductor-priority) 2)]
       [(pair? conductor-priorities) (sub1 (apply min conductor-priorities))]
       [(pair? dielectric-priorities) (add1 (apply max dielectric-priorities))]
       [else 10]))))

(define (derive-component-priority geometry component)
  (or
   (lumped-component-priority component)
   (let ()
     (define-values (minimum maximum) (component-bounds component))
     (define touching
       (filter (lambda (item) (bounds-intersect? item minimum maximum)) geometry))
     (define dielectric-priorities
       (for/list ([item (in-list touching)]
                  #:when (eq? (em-material-kind (geometry-material item))
                              'dielectric))
         (geometry-priority item)))
     (define conductor-priorities
       (for/list ([item (in-list touching)]
                  #:when (memq (em-material-kind (geometry-material item))
                               '(pec conductor conducting-sheet)))
         (geometry-priority item)))
     (cond
       [(and (pair? dielectric-priorities) (pair? conductor-priorities))
        (define dielectric-priority (apply max dielectric-priorities))
        (define conductor-priority (apply min conductor-priorities))
        (unless (>= (- conductor-priority dielectric-priority) 2)
          (raise-user-error
           'openems-sweep
           (string-append
            "geometry touching lumped element ~a must leave an integer "
            "priority between dielectric and conductor priorities")
           (lumped-component-name component)))
        (quotient (+ dielectric-priority conductor-priority) 2)]
       [(pair? conductor-priorities) (sub1 (apply min conductor-priorities))]
       [(pair? dielectric-priorities) (add1 (apply max dielectric-priorities))]
       [else 10]))))

(define (validate-component-contacts! geometry components)
  ;; Bounding boxes can prove that a terminal is disconnected. A positive
  ;; bounding-box match for an arbitrary STL is only a candidate, so OpenEMS
  ;; remains the final authority for more intricate contact geometry.
  (for ([component (in-list components)])
    (define axis
      (signed-axis-index (point->list (lumped-component-direction component))))
    (define-values (minimum maximum) (component-bounds component))
    (for ([face (in-list (list (list-ref minimum axis)
                               (list-ref maximum axis)))])
      (define terminal-min (list-set minimum axis (- face 1e-12)))
      (define terminal-max (list-set maximum axis (+ face 1e-12)))
      (define conductors
        (filter
         (lambda (item)
           (and (memq (em-material-kind (geometry-material item))
                      '(pec conductor conducting-sheet))
                (bounds-intersect? item terminal-min terminal-max)))
         geometry))
      (when (null? conductors)
        (raise-user-error
         'openems-sweep
         "lumped element ~a has a terminal that does not touch conductive geometry"
         (lumped-component-name component))))))

(define (axis-values geometry accessor axis)
  (for/list ([item (in-list geometry)])
    (list-ref (accessor item) axis)))

(define (exported-sheet-points-3d sheet)
  (for/list ([point (in-list (exported-sheet-points-2d sheet))])
    (transform-point (exported-sheet-transform sheet)
                     (point3 (first point) (second point) 0))))

(define (exported-sheet-boundaries-3d sheet)
  (for/list ([boundary (in-list (exported-sheet-boundaries-2d sheet))])
    (for/list ([point (in-list boundary)])
      (transform-point (exported-sheet-transform sheet)
                       (point3 (first point) (second point) 0)))))

(define (near? first second [scale 1])
  (<= (abs (- first second)) (* 1e-9 (max 1 scale))))

(define (metal-sheet-plane-axis sheet)
  (unless (memq (em-material-kind (exported-sheet-material sheet))
                '(pec conductor conducting-sheet))
    (raise-arguments-error
     'openems-sweep
     "metal edge treatment requires a PEC or conducting sheet"
     "sheet" (exported-sheet-name sheet)))
  (define minimum (exported-sheet-minimum sheet))
  (define maximum (exported-sheet-maximum sheet))
  (define extents (map - maximum minimum))
  (define scale (apply max extents))
  (define flat-axes
    (for/list ([extent (in-list extents)] [axis (in-naturals)]
               #:when (near? extent 0 scale))
      axis))
  (unless (= (length flat-axes) 1)
    (raise-arguments-error
     'openems-sweep
     "metal edge treatment requires an axis-aligned planar sheet"
     "sheet" (exported-sheet-name sheet)))
  (first flat-axes))

(define (boundary-segments-3d sheet)
  (append*
   (for/list ([boundary (in-list (exported-sheet-boundaries-3d sheet))])
     (map list boundary (append (rest boundary) (list (first boundary)))))))

(define (segment-varying-axes segment)
  (define first-point (first segment))
  (define second-point (second segment))
  (define scale
    (max 1 (apply max (map abs (append first-point second-point)))))
  (for/list ([axis (in-range 3)]
             #:unless (near? (list-ref first-point axis)
                             (list-ref second-point axis) scale))
    axis))

(define (sheet-has-oblique-edges? sheet)
  (for/or ([segment (in-list (boundary-segments-3d sheet))])
    (> (length (segment-varying-axes segment)) 1)))

(define (trace-mesh-treatment sheet)
  (define segments (boundary-segments-3d sheet))
  (define aligned-count
    (count (lambda (segment)
             (= (length (segment-varying-axes segment)) 1))
           segments))
  (cond [(= aligned-count (length segments)) 'ideal-orthogonal]
        [(zero? aligned-count) 'oblique]
        [else 'hybrid]))

(define (point-in-loop? point loop)
  (define x (first point))
  (define y (second point))
  (odd?
   (for/sum ([a (in-list loop)]
             [b (in-list (append (rest loop) (list (first loop))))])
     (if (and (not (eq? (> (second a) y) (> (second b) y)))
              (< x (+ (first a)
                      (* (- y (second a))
                         (/ (- (first b) (first a))
                            (- (second b) (second a)))))))
         1 0))))

(define (point-in-sheet-region? sheet point-3d)
  (define transform (exported-sheet-transform sheet))
  (define origin (map fourth transform))
  (define u (map first transform))
  (define v (map second transform))
  (define offset (map - point-3d origin))
  (define point-2d (list (dot offset u) (dot offset v)))
  (odd?
   (for/sum ([boundary (in-list (exported-sheet-boundaries-2d sheet))])
     (if (point-in-loop? point-2d boundary) 1 0))))

(define (metal-boundary-edges-for-axis sheet axis resolution)
  (define plane-axis (metal-sheet-plane-axis sheet))
  (if (= axis plane-axis)
      '()
      (for/list ([segment (in-list (boundary-segments-3d sheet))]
                 #:when
                 (let ([varying (segment-varying-axes segment)])
                   (and (= (length varying) 1)
                        (not (= (first varying) axis)))))
        (define first-point (first segment))
        (define second-point (second segment))
        (define coordinate (list-ref first-point axis))
        (define midpoint (map (lambda (a b) (/ (+ a b) 2))
                              first-point second-point))
        (define probe-distance (/ resolution 20))
        (define plus (list-set midpoint axis (+ coordinate probe-distance)))
        (define minus (list-set midpoint axis (- coordinate probe-distance)))
        (define plus-inside? (point-in-sheet-region? sheet plus))
        (define minus-inside? (point-in-sheet-region? sheet minus))
        (list sheet
              (cond [(and plus-inside? (not minus-inside?)) 'low]
                    [(and minus-inside? (not plus-inside?)) 'high]
                    [else
                     ;; Degenerate probes can occur at a nearby corner.  The
                     ;; symmetric exact-edge fallback is safer than guessing.
                     'exact])
              coordinate))))

(define (metal-edge-sheets geometry)
  (filter (lambda (item)
            (and (exported-sheet? item)
                 (eq? (exported-sheet-mesh-edges item) 'metal)))
          geometry))

(define (ordinary-geometry-axis-values geometry axis)
  (append*
   (for/list ([item (in-list geometry)])
     (cond
       [(and (exported-sheet? item)
             (eq? (exported-sheet-mesh-edges item) 'metal))
        (define normal-axis (metal-sheet-plane-axis item))
        ;; The sheet elevation remains an exact material boundary. Its
        ;; in-plane edges are represented only by the shifted metal-edge pair.
        (if (= axis normal-axis)
            (list (list-ref (exported-sheet-minimum item) axis))
            '())]
       [(and (exported-body? item)
             (eq? (em-material-kind (exported-body-material item)) 'conductor))
        (remove-duplicates
         (for/list ([facet (in-list (exported-body-surface-facets item))]
                    #:when (= axis (exported-facet-plane-axis facet)))
           (exported-facet-plane-coordinate facet)))]
       [else
        (list (list-ref (geometry-minimum item) axis)
              (list-ref (geometry-maximum item) axis))]))))

(define (trace-metal-edge-resolution sheet resolution minimum-trace-cells)
  (define trace-width (exported-sheet-trace-width sheet))
  (if trace-width
      (min resolution (/ trace-width minimum-trace-cells))
      resolution))

(define (metal-edge-axis-values geometry axis resolution minimum-trace-cells
                                fixed-values)
  ;; DetectEdges/AddEdges2Grid place two grid lines around each 2-D metal
  ;; boundary: resolution/3 inside and 2*resolution/3 outside. If another
  ;; required line would make either shifted line excessively close, retain
  ;; the exact edge instead of creating a pathological sliver cell.
  (define edges
    (append*
     (for/list ([sheet (in-list (metal-edge-sheets geometry))]
                #:unless (= axis (metal-sheet-plane-axis sheet)))
       (metal-boundary-edges-for-axis
        sheet axis
        (trace-metal-edge-resolution
         sheet resolution minimum-trace-cells)))))
  (define-values (_existing added)
    (for/fold ([existing fixed-values] [added '()]) ([edge (in-list edges)])
      (match-define (list sheet side coordinate) edge)
      (define edge-resolution
        (trace-metal-edge-resolution sheet resolution minimum-trace-cells))
      (define minimum-separation (/ edge-resolution 4))
      (define candidates
        (case side
          [(low) (list (- coordinate (* 2/3 edge-resolution))
                       (+ coordinate (/ edge-resolution 3)))]
          [(high) (list (- coordinate (/ edge-resolution 3))
                        (+ coordinate (* 2/3 edge-resolution)))]
          [else (list coordinate)]))
      (define conflict?
        (for/or ([candidate (in-list candidates)])
          (for/or ([line (in-list existing)])
            (< (abs (- candidate line)) minimum-separation))))
      (if conflict?
          (let ([nearby-edge-line?
                 (for/or ([line (in-list existing)])
                   (< (abs (- coordinate line)) minimum-separation))])
            (eprintf
             (string-append
              "OpenEMS mesh warning: metal-edge lines for sheet ~a at ~a m "
              "would be too close to another required line; ~a on this axis\n")
             (exported-sheet-name sheet) coordinate
             (if nearby-edge-line?
                 "using the nearby existing line"
                 "using the exact edge"))
            (if nearby-edge-line?
                (values existing added)
                (values (cons coordinate existing) (cons coordinate added))))
          (values (append candidates existing) (append candidates added)))))
  added)

(define (metal-boundary-coordinates-for-axis sheet axis)
  (define plane-axis (metal-sheet-plane-axis sheet))
  (if (= axis plane-axis)
      '()
      (remove-duplicates
       (for/list ([segment (in-list (boundary-segments-3d sheet))]
                  #:when
                  (let ([varying (segment-varying-axes segment)])
                    (and (= (length varying) 1)
                         (not (= (first varying) axis)))))
         (list-ref (first segment) axis))
       =)))

(define (port-boundary-coincident-with-metal-edge?
         geometry port axis coordinate)
  (define-values (port-minimum port-maximum) (port-bounds port))
  (for/or ([sheet (in-list (metal-edge-sheets geometry))]
           #:when (bounds-intersect? sheet port-minimum port-maximum))
    (for/or ([edge-coordinate
              (in-list (metal-boundary-coordinates-for-axis sheet axis))])
      (near? coordinate edge-coordinate
             (max 1 (abs coordinate) (abs edge-coordinate))))))

(define (port-mesh-axis-values geometry ports axis)
  (append*
   (for/list ([port (in-list ports)])
     (define-values (minimum maximum) (port-bounds port))
     (define direction-axis
       (signed-axis-index (point->list (lumped-port-direction port))))
     (for/list ([coordinate
                 (in-list (list (list-ref minimum axis)
                                (list-ref maximum axis)))]
                #:unless
                (and (not (= axis direction-axis))
                     (port-boundary-coincident-with-metal-edge?
                      geometry port axis coordinate)))
       coordinate))))

(define (trace-refinement-axis-values geometry axis minimum-trace-cells)
  (append*
   (for/list ([sheet (in-list (metal-edge-sheets geometry))]
              #:when (and (exported-sheet-trace-width sheet)
                          (sheet-has-oblique-edges? sheet))
              #:unless (= axis (metal-sheet-plane-axis sheet)))
     (define low (list-ref (exported-sheet-minimum sheet) axis))
     (define high (list-ref (exported-sheet-maximum sheet) axis))
     (define target (/ (exported-sheet-trace-width sheet)
                       minimum-trace-cells))
     (define count (max 1 (ceiling (/ (- high low) target))))
     ;; These are width-resolution helpers, not geometric boundary locks.
     ;; Keeping the bounding endpoints out avoids putting an exact grid line
     ;; back on an orthogonal edge that already received a 1/3--2/3 pair.
     (for/list ([index (in-range 1 count)])
       (+ low (* (- high low) (/ index count)))))))

(define (dielectric-subdivision-values geometry axis max-resolution
                                       minimum-dielectric-cells)
  ;; SmoothMeshLines limits large cells but does not guarantee that an
  ;; electrically thin material gets enough cells between its interfaces.
  ;; Add interior critical coordinates only where the wavelength-based limit
  ;; would otherwise permit fewer than the minimum number of cells.  In the
  ;; port-aligned solver coordinates this gives an ordinary planar substrate
  ;; the requested number of cells through its thickness without imposing that
  ;; resolution on the entire simulation domain.
  (append*
   (for/list ([item (in-list geometry)]
              #:when
              (and (exported-body? item)
                   (eq? (em-material-kind (exported-body-material item))
                        'dielectric)))
     (define low (list-ref (exported-body-minimum item) axis))
     (define high (list-ref (exported-body-maximum item) axis))
     (define extent (- high low))
     (if (and (positive? extent)
              (< extent
                 (* minimum-dielectric-cells max-resolution)))
         (for/list ([index
                     (in-range 1 minimum-dielectric-cells)])
           (+ low (* extent
                     (/ index minimum-dielectric-cells))))
         '()))))

(define (mesh-constraint-axis-values constraints axis)
  (for/list ([constraint (in-list constraints)]
             #:when (member axis (exported-mesh-constraint-axes constraint)))
    (list-ref (exported-mesh-constraint-solver-point constraint) axis)))

;; Turtle motion, rotations, and independently transformed geometry can arrive
;; at the same intended coordinate through different floating-point operation
;; sequences.  Passing both representations to SmoothMeshLines makes it grade
;; outward from an effectively zero-width cell, sometimes adding hundreds of
;; spurious lines.  Coalesce only differences consistent with accumulated
;; binary64 roundoff.  A wavelength-derived tolerance would be unsafe here:
;; electrically small gaps and metal thicknesses may be intentional.
(define binary64-epsilon (expt 2.0 -52))

(define (mesh-coordinate-roundoff-close? left right max-resolution)
  (define numerical-scale
    (max (abs left) (abs right) max-resolution))
  (<= (abs (- left right))
      (* 128 binary64-epsilon numerical-scale)))

(define (coalesce-nearby-mesh-values values max-resolution)
  (reverse
   (for/fold ([kept '()]) ([value (in-list (sort values <))])
     (if (and (pair? kept)
              (mesh-coordinate-roundoff-close?
               (car kept) value max-resolution))
         kept
         (cons value kept)))))

(define (critical-axis-values geometry ports components constraints axis domain-min domain-max
                              max-resolution minimum-dielectric-cells
                              minimum-trace-cells metal-edge-resolution)
  ;; Port terminal planes in the excitation direction are mandatory. A
  ;; transverse port face that exactly follows a selected metal boundary is
  ;; not: retaining it would put an exact grid line on the conductor edge and
  ;; suppress the requested 1/3--2/3 treatment.
  (define port-values (port-mesh-axis-values geometry ports axis))
  (define component-values
    (append*
     (for/list ([component (in-list components)])
       (define-values (minimum maximum) (component-bounds component))
       (list (list-ref minimum axis) (list-ref maximum axis)))))
  (define user-values (mesh-constraint-axis-values constraints axis))
  (define fixed-values
    (append (list domain-min domain-max 0)
            user-values
            port-values
            component-values
            (ordinary-geometry-axis-values geometry axis)
            (dielectric-subdivision-values
             geometry axis max-resolution minimum-dielectric-cells)))
  (coalesce-nearby-mesh-values
   (append fixed-values
           (trace-refinement-axis-values
            geometry axis minimum-trace-cells)
           (metal-edge-axis-values
            geometry axis metal-edge-resolution minimum-trace-cells
            fixed-values))
   max-resolution))

(define (validate-mesh-constraint-domain! constraints domain-min domain-max)
  (for ([constraint (in-list constraints)])
    (define point (exported-mesh-constraint-solver-point constraint))
    (for ([axis (in-list (exported-mesh-constraint-axes constraint))])
      (define coordinate (list-ref point axis))
      (unless (<= (list-ref domain-min axis) coordinate
                  (list-ref domain-max axis))
        (raise-arguments-error
         'openems-sweep
         "mesh constraint lies outside the automatically padded simulation domain"
         "kind" (exported-mesh-constraint-kind constraint)
         "plane" (or (exported-mesh-constraint-plane constraint) 'none)
         "user point" (exported-mesh-constraint-user-point constraint)
         "solver coordinate" coordinate
         "solver axis" axis)))))

(define (scene-bounds geometry)
  (values
   (for/list ([axis (in-range 3)])
     (apply min (axis-values geometry geometry-minimum axis)))
   (for/list ([axis (in-range 3)])
     (apply max (axis-values geometry geometry-maximum axis)))))

(define (write-octave-driver directory bodies sheets ports port-priorities
                             components component-priorities
                             start-mhz stop-mhz steps
                             critical-x critical-y critical-z max-resolution
                             required-x required-y required-z
                             mesh-grading maximum-timesteps end-criteria
                             geometry-minimum geometry-maximum wavelength-min)
  (define path (build-path directory "run-openems.m"))
  (define port-count (length ports))
  (define budget-frequency-hz (* (model-frequency) 1e6))
  (define lossy-dielectric?
    (for/or ([body (in-list bodies)])
      (and (eq? (em-material-kind (exported-body-material body)) 'dielectric)
           (> (dielectric-effective-conductivity
               (exported-body-material body) (model-frequency))
              0))))
  (call-with-output-file path
    #:exists 'truncate/replace
    (lambda (out)
      (define (line format-string . values)
        (apply fprintf out (string-append format-string "\n") values))
      (write-octave-openems-loader line)
      (when (pair? components)
        (line "lumped_source = fileread(which('AddLumpedElement'));")
        (line "if isempty(regexp(lumped_source, 'LEtype', 'once')), error('Antenna Turtle lumped elements require openEMS 0.37/CSXCAD 0.7 or newer'); end"))
      (line "physical_constants;")
      (line "unit = 1.0;")
      (line "f_start = ~a;" (number-string (* start-mhz 1e6)))
      (line "f_stop = ~a;" (number-string (* stop-mhz 1e6)))
      (line "budget_frequency = ~a;" (number-string budget-frequency-hz))
      ;; Exciting continuously from DC through f_stop avoids pathologically
      ;; long pulses for narrow sweeps while still recording every requested
      ;; postprocessing frequency in a single solver run.
      (line "f0 = 0;")
      (line "fc = f_stop;")
      (line "max_timesteps = ~a;" maximum-timesteps)
      (line "end_criteria = ~a;" (number-string end-criteria))
      (line "fprintf('Antenna Turtle: at most %d timesteps; residual-energy stop threshold %.1e (%.1f dB)\\n', max_timesteps, end_criteria, 10*log10(end_criteria));")
      (line "mesh.x = SmoothMeshLines(~a, ~a, ~a);"
            (octave-vector critical-x) (number-string max-resolution)
            (number-string mesh-grading))
      (line "mesh.y = SmoothMeshLines(~a, ~a, ~a);"
            (octave-vector critical-y) (number-string max-resolution)
            (number-string mesh-grading))
      (line "mesh.z = SmoothMeshLines(~a, ~a, ~a);"
            (octave-vector critical-z) (number-string max-resolution)
            (number-string mesh-grading))
      ;; SmoothMeshLines should retain every supplied coordinate. Verify the
      ;; user-authored hard constraints before spending time in FDTD.
      (for ([axis-name (in-list '(x y z))]
            [required (in-list (list required-x required-y required-z))])
        (line "required_~a = ~a;" axis-name (octave-vector required))
        (line "for required = required_~a" axis-name)
        (line "  if min(abs(mesh.~a - required)) > 1e-9 * max(1, abs(required))" axis-name)
        (line "    error('SmoothMeshLines did not retain a required ~a-axis mesh coordinate');" axis-name)
        (line "  end")
        (line "end"))
      ;; Match the dimensions and total reported by OpenEMS itself. Its FDTD
      ;; operator count uses the number of mesh lines on each Yee axis.
      (line "mesh_cells = numel(mesh.x) * numel(mesh.y) * numel(mesh.z);")
      (line "mesh_min_spacing = min([diff(mesh.x), diff(mesh.y), diff(mesh.z)]);")
      (line "fprintf('Antenna Turtle mesh: %d x %d x %d lines; %d cells; minimum spacing %.6g m; max resolution %.6g m\\n', numel(mesh.x), numel(mesh.y), numel(mesh.z), mesh_cells, mesh_min_spacing, ~a);"
            (number-string max-resolution))
      (line "if exist('simulation', 'dir'), rmdir('simulation', 's'); end")
      (line "mkdir('simulation');")
      (line "dlmwrite('simulation/mesh-x.csv', mesh.x(:)', 'precision', '%.17g');")
      (line "dlmwrite('simulation/mesh-y.csv', mesh.y(:)', 'precision', '%.17g');")
      (line "dlmwrite('simulation/mesh-z.csv', mesh.z(:)', 'precision', '%.17g');")
      (line "fid = fopen('simulation/versions.txt', 'w');")
      (line "fprintf(fid, 'octave=%s\\n', version);")
      (line "packages = pkg('list');")
      (line "for k = 1:numel(packages), fprintf(fid, '%s=%s\\n', packages{k}.name, packages{k}.version); end")
      (line "fclose(fid);")
      (line "freq = linspace(f_start, f_stop, ~a);" steps)
      (line "all_s = [];")
      (for ([active-index (in-range 1 (add1 port-count))])
        (define simulation-name
          (if (= port-count 1)
              "simulation"
              (format "simulation/excitation-~a" active-index)))
        (line "fprintf('Antenna Turtle excitation ~a of ~a\\n');"
              active-index port-count)
        (line "FDTD = InitFDTD('NrTS', max_timesteps, 'EndCriteria', end_criteria);")
        (line "FDTD = SetGaussExcite(FDTD, f0, fc);")
        (line "FDTD = SetBoundaryCond(FDTD, {'PML_8' 'PML_8' 'PML_8' 'PML_8' 'PML_8' 'PML_8'});")
        (line "CSX = InitCSX();")
        (line "CSX = DefineRectGrid(CSX, unit, mesh);")
        (line "Sim_Path = '~a';" simulation-name)
        (line "Sim_XML = 'model.xml';")
        (when (> port-count 1) (line "mkdir(Sim_Path);"))
        (for ([body (in-list bodies)] [index (in-naturals 1)])
          (define property (format "body_~a" index))
          (define material (exported-body-material body))
          (case (em-material-kind material)
            [(pec)
             (line "copyfile('~a', [Sim_Path '/~a']);"
                   (exported-body-filename body) (exported-body-filename body))
             (line "CSX = AddMetal(CSX, '~a');" property)
             (line "CSX = ImportSTL(CSX, '~a', ~a, '~a');"
                   property (exported-body-priority body)
                   (exported-body-filename body))]
            [(dielectric)
             (line "copyfile('~a', [Sim_Path '/~a']);"
                   (exported-body-filename body) (exported-body-filename body))
             (line "CSX = AddMaterial(CSX, '~a');" property)
             ;; Density does not affect the electromagnetic solve.  A unit
             ;; density makes the raw-SAR machinery usable as a volumetric
             ;; dielectric power-loss integrator.
             (line "CSX = SetMaterialProperty(CSX, '~a', 'Epsilon', ~a, 'Mue', ~a, 'Kappa', ~a, 'Density', 1);"
                   property
                   (number-string (em-material-relative-permittivity material))
                   (number-string (em-material-relative-permeability material))
                   (number-string
                    (dielectric-effective-conductivity material (model-frequency))))
             (line "CSX = ImportSTL(CSX, '~a', ~a, '~a');"
                   property (exported-body-priority body)
                   (exported-body-filename body))]
            [(conductor)
             (line "CSX = AddConductingSheet(CSX, '~a', ~a, ~a);"
                   property
                   (number-string (em-material-electric-conductivity material))
                   (number-string
                    (conductor-effective-sheet-thickness
                     material (exported-body-metal-thickness body)
                     (model-frequency))))
             (for ([facet (in-list (exported-body-surface-facets body))]
                   [facet-index (in-naturals 1)])
               (line "body_~a_facet_~a = ~a;" index facet-index
                     (octave-point-matrix (exported-facet-points-2d facet)))
               (line "CSX = AddPolygon(CSX, '~a', ~a, 2, 0, body_~a_facet_~a, 'Transform', {'Matrix', '~a'});"
                     property (exported-body-priority body) index facet-index
                     (csx-matrix-string (exported-facet-transform facet))))]))
        (for ([sheet (in-list sheets)] [index (in-naturals 1)])
          (define property (format "sheet_~a" index))
          (define material (exported-sheet-material sheet))
          (case (em-material-kind material)
            [(pec) (line "CSX = AddMetal(CSX, '~a');" property)]
            [(conductor conducting-sheet)
             (line "CSX = AddConductingSheet(CSX, '~a', ~a, ~a);"
                   property
                   (number-string (em-material-electric-conductivity material))
                   (number-string
                    (conductor-effective-sheet-thickness
                     material (exported-sheet-thickness sheet)
                     (model-frequency))))])
          (for ([polygon (in-list (exported-sheet-polygons-2d sheet))]
                [polygon-index (in-naturals 1)])
            (line "sheet_points_~a_~a = ~a;" index polygon-index
                  (octave-point-matrix polygon))
            (line "CSX = AddPolygon(CSX, '~a', ~a, 2, 0, sheet_points_~a_~a, 'Transform', {'Matrix', '~a'});"
                  property (exported-sheet-priority sheet) index polygon-index
                  (csx-matrix-string (exported-sheet-transform sheet)))))
        (for ([component (in-list components)]
              [priority (in-list component-priorities)]
              [component-index (in-naturals 1)])
          (define property (format "lumped_~a" component-index))
          (define axis
            (signed-axis-index
             (point->list (lumped-component-direction component))))
          (define-values (component-start component-stop)
            (component-bounds component))
          (define options
            (string-append
             (format ", 'Caps', ~a"
                     (if (lumped-component-caps component) 1 0))
             (if (lumped-component-resistance component)
                 (format ", 'R', ~a"
                         (number-string
                          (lumped-component-resistance component))) "")
             (if (lumped-component-inductance component)
                 (format ", 'L', ~a"
                         (number-string
                          (lumped-component-inductance component))) "")
             (if (lumped-component-capacitance component)
                 (format ", 'C', ~a"
                         (number-string
                          (lumped-component-capacitance component))) "")
             (format ", 'LEtype', ~a"
                     (if (eq? (lumped-component-topology component) 'series)
                         1 0))))
          (line "CSX = AddLumpedElement(CSX, '~a', ~a~a);"
                property axis options)
          (line "CSX = AddBox(CSX, '~a', ~a, ~a, ~a);"
                property priority (octave-vector component-start)
                (octave-vector component-stop))
          ;; Add non-material voltage/current probes around every component
          ;; that contains a resistor.  Their aggregate real power is the
          ;; lumped-element heat category; ideal L/C elements need no probe.
          (when (lumped-component-resistance component)
            (define direction-values
              (point->list (lumped-component-direction component)))
            (define direction-sign
              (if (negative? (list-ref direction-values axis)) -1 1))
            (line "component_u_start = 0.5*(~a + ~a);"
                  (octave-vector component-start)
                  (octave-vector component-stop))
            (line "component_u_stop = component_u_start;")
            (line "component_u_start(~a) = ~a;"
                  (add1 axis) (number-string (list-ref component-start axis)))
            (line "component_u_stop(~a) = ~a;"
                  (add1 axis) (number-string (list-ref component-stop axis)))
            (line "CSX = AddProbe(CSX, 'lumped_ut~a', 0, 'weight', -1);"
                  component-index)
            (line "CSX = AddBox(CSX, 'lumped_ut~a', ~a, component_u_start, component_u_stop);"
                  component-index priority)
            (line "component_i_start = ~a;"
                  (octave-vector component-start))
            (line "component_i_stop = ~a;"
                  (octave-vector component-stop))
            (line "component_i_start(~a) = 0.5*(~a + ~a);"
                  (add1 axis)
                  (number-string (list-ref component-start axis))
                  (number-string (list-ref component-stop axis)))
            (line "component_i_stop(~a) = component_i_start(~a);"
                  (add1 axis) (add1 axis))
            (line "CSX = AddProbe(CSX, 'lumped_it~a', 1, 'weight', ~a, 'NormDir', ~a);"
                  component-index direction-sign axis)
            (line "CSX = AddBox(CSX, 'lumped_it~a', ~a, component_i_start, component_i_stop);"
                  component-index priority)))
        (line "port = {};")
        (for ([port (in-list ports)]
              [priority (in-list port-priorities)]
              [port-index (in-naturals 1)])
          (define-values (port-start port-stop) (port-bounds port))
          (line "port_start = ~a;" (octave-vector port-start))
          (line "port_stop = ~a;" (octave-vector port-stop))
          (line "[CSX, port{~a}] = AddLumpedPort(CSX, ~a, ~a, ~a, port_start, port_stop, ~a, ~a);"
                port-index priority port-index
                (number-string (lumped-port-impedance port))
                (octave-vector (point->list (lumped-port-direction port)))
                (if (= port-index active-index) "true" "false")))
        ;; Keep a separate NF2FF recording for each independent excitation.
        (line "pml_cells = 8;")
        (line "if min([numel(mesh.x), numel(mesh.y), numel(mesh.z)]) <= 2*pml_cells, error('mesh too small for NF2FF box and PML'); end")
        (line "geometry_min = ~a;" (octave-vector geometry-minimum))
        (line "geometry_max = ~a;" (octave-vector geometry-maximum))
        (line "nf2ff_start = [mesh.x(pml_cells+1), mesh.y(pml_cells+1), mesh.z(pml_cells+1)];")
        (line "nf2ff_stop = [mesh.x(end-pml_cells), mesh.y(end-pml_cells), mesh.z(end-pml_cells)];")
        (line "if any(nf2ff_start >= geometry_min) || any(nf2ff_stop <= geometry_max), error('NF2FF box does not enclose all radiating geometry'); end")
        (line "nf2ff_resolution = ~a;" (number-string (/ wavelength-min 15)))
        (line "[CSX, nf2ff] = CreateNF2FFBox(CSX, 'nf2ff', nf2ff_start, nf2ff_stop, 'OptResolution', nf2ff_resolution);")
        (line "save([Sim_Path '/nf2ff-box.mat'], 'nf2ff', 'nf2ff_start', 'nf2ff_stop', 'nf2ff_resolution');")
        (when lossy-dielectric?
          (line "CSX = AddDump(CSX, 'dielectric_loss', 'DumpType', 29, 'Frequency', budget_frequency, 'FileType', 1, 'DumpMode', 2);")
          (line "CSX = AddBox(CSX, 'dielectric_loss', 0, geometry_min, geometry_max);"))
        (line "WriteOpenEMS([Sim_Path '/' Sim_XML], FDTD, CSX);")
        (line "settings.LogFile = 'openems.log'; settings.Silent = 0;")
        (line "RunOpenEMS(Sim_Path, Sim_XML, '--dump-statistics', settings);")
        (for ([port-index (in-range 1 (add1 port-count))])
          (line "port{~a} = calcPort(port{~a}, Sim_Path, freq);"
                port-index port-index))
        ;; Preserve absolute port powers at the exact model frequency.  These
        ;; are safer than deriving power solely from S-parameters and remain
        ;; valid for passive output ports, whose accepted power is negative.
        (line "all_port_power = [];")
        (for ([port-index (in-range 1 (add1 port-count))])
          (line "budget_port = calcPort(port{~a}, Sim_Path, budget_frequency);"
                port-index)
          (line "all_port_power = [all_port_power; budget_frequency, ~a, ~a, budget_port.P_inc(1), budget_port.P_ref(1), budget_port.P_acc(1)];"
                port-index active-index))
        (line "dlmwrite([Sim_Path '/port-power.csv'], all_port_power, 'precision', '%.17g');")
        (line "all_lumped_power = [];")
        (for ([component (in-list components)]
              [component-index (in-naturals 1)]
              #:when (lumped-component-resistance component))
          (line "lumped_u = ReadUI('lumped_ut~a', Sim_Path, budget_frequency);"
                component-index)
          (line "lumped_i = ReadUI('lumped_it~a', Sim_Path, budget_frequency);"
                component-index)
          (line "lumped_power = 0.5*abs(real(lumped_u.FD{1}.val(1)*conj(lumped_i.FD{1}.val(1))));")
          (line "all_lumped_power = [all_lumped_power; budget_frequency, ~a, ~a, lumped_power];"
                component-index active-index))
        (line "dlmwrite([Sim_Path '/lumped-power.csv'], all_lumped_power, 'precision', '%.17g');")
        (if lossy-dielectric?
            (begin
              (line "CalcSAR([Sim_Path '/dielectric_loss.h5'], [Sim_Path '/dielectric_loss_local.h5'], 'mass', 0);")
              (line "dielectric_power = ReadHDF5Attribute([Sim_Path '/dielectric_loss_local.h5'], '/FieldData/FD/f0', 'power');")
              (line "dlmwrite([Sim_Path '/dielectric-power.csv'], [budget_frequency, ~a, dielectric_power], 'precision', '%.17g');"
                    active-index))
            (line "dlmwrite([Sim_Path '/dielectric-power.csv'], [budget_frequency, ~a, 0], 'precision', '%.17g');"
                  active-index))
        (for ([output-index (in-range 1 (add1 port-count))])
          (line "s = port{~a}.uf.ref ./ port{~a}.uf.inc;"
                output-index active-index)
          (line "all_s = [all_s; freq(:), repmat(~a, numel(freq), 1), repmat(~a, numel(freq), 1), real(s(:)), imag(s(:)), 20*log10(abs(s(:)))];"
                output-index active-index))
        (line "sii = port{~a}.uf.ref ./ port{~a}.uf.inc;"
              active-index active-index)
        (line "zin = port{~a}.uf.tot ./ port{~a}.if.tot;"
              active-index active-index)
        (line "results = [freq(:), real(sii(:)), imag(sii(:)), real(zin(:)), imag(zin(:)), 20*log10(abs(sii(:)))];")
        (line "dlmwrite([Sim_Path '/port-results.csv'], results, 'precision', '%.17g');"))
      (line "dlmwrite('simulation/s-parameters.csv', all_s, 'precision', '%.17g');")))
  path)

(define (read-number-list path)
  (map string->number
       (filter (lambda (value) (not (string=? value "")))
               (regexp-split #px"[,[:space:]]+" (string-trim (file->string path))))))

(define (read-version-file path)
  (if (file-exists? path)
      (for/hash ([line (in-list (file->lines path))]
                 #:when (regexp-match? #px"=" line))
        (match-define (list key value) (string-split line "=" #:trim? #f))
        (values (string->symbol key) value))
      (hash)))

(define (read-openems-statistics path maximum-timesteps)
  (define values
    (and (file-exists? path)
         (for/list ([line (in-list (file->lines path))])
           (string->number (first (string-split line))))))
  (if (and values (= (length values) 6) (andmap number? values))
      (match-let ([(list reported-cells timestep iterations numerical-time
                          simulation-seconds cells-per-second)
                   values])
        (hash 'reported_cells reported-cells
              'timestep_seconds timestep
              'actual_timesteps iterations
              'numerical_time_seconds numerical-time
              'simulation_seconds simulation-seconds
              'cells_per_second cells-per-second
              'termination
              (if (< iterations maximum-timesteps)
                  "end-criteria"
                  "maximum-timesteps")))
      (hash)))

(define (parse-openems-port-results path)
  (unless (file-exists? path)
    (raise-user-error 'parse-openems-port-results
                      "OpenEMS result file does not exist: ~a" path))
  (for/list ([line (in-list (file->lines path))]
             #:unless (string=? (string-trim line) ""))
    (define fields (map string->number (string-split line ",")))
    (unless (and (= (length fields) 6) (andmap number? fields))
      (error 'parse-openems-port-results "invalid result row: ~e" line))
    (match-define (list frequency-hz s11-real s11-imaginary
                        impedance-real impedance-imaginary s11-db)
      fields)
    (openems-port-sample
     (/ frequency-hz 1e6)
     (make-rectangular s11-real s11-imaginary)
     (make-rectangular impedance-real impedance-imaginary)
     s11-db)))

(define (parse-openems-s-parameter-results path port-names)
  (unless (file-exists? path)
    (raise-user-error 'parse-openems-s-parameter-results
                      "OpenEMS S-parameter result file does not exist: ~a"
                      path))
  (for/list ([line (in-list (file->lines path))]
             #:unless (string=? (string-trim line) ""))
    (define fields (map string->number (string-split line ",")))
    (unless (and (= (length fields) 6) (andmap number? fields))
      (error 'parse-openems-s-parameter-results
             "invalid result row: ~e" line))
    (match-define
      (list frequency-hz output-index input-index real-value imaginary-value db)
      fields)
    (unless (and (exact-integer? output-index)
                 (exact-integer? input-index)
                 (<= 1 output-index (length port-names))
                 (<= 1 input-index (length port-names)))
      (error 'parse-openems-s-parameter-results
             "invalid port indexes in row: ~e" line))
    (openems-s-parameter-sample
     (/ frequency-hz 1e6)
     (list-ref port-names (sub1 output-index))
     (list-ref port-names (sub1 input-index))
     (make-rectangular real-value imaginary-value)
     db)))

(define (openems-load-artifacts directory)
  (unless (path-string? directory)
    (raise-argument-error 'openems-load-artifacts "path-string?" directory))
  (define root (simplify-path (path->complete-path directory)))
  (unless (directory-exists? root)
    (raise-user-error 'openems-load-artifacts
                      "artifact directory does not exist: ~a" root))
  (define manifest-path (build-path root "simulation-manifest.rktd"))
  (define simulation-directory (build-path root "simulation"))
  (unless (file-exists? manifest-path)
    (raise-user-error 'openems-load-artifacts
                      "artifact manifest does not exist: ~a" manifest-path))
  (define manifest
    (call-with-input-file manifest-path
      (lambda (in)
        (define value (read in))
        (unless (hash? value)
          (raise-user-error 'openems-load-artifacts
                            "artifact manifest is not a hash: ~a"
                            manifest-path))
        value)))
  (define saved-ports
    (let ([ports (hash-ref manifest 'ports #f)])
      (if (and (list? ports) (pair? ports))
          ports
          (let ([port (hash-ref manifest 'port #f)])
            (if (hash? port) (list port) '())))))
  (define format-version (hash-ref manifest 'format_version #f))
  (unless (equal? format-version 1)
    (raise-user-error 'openems-load-artifacts
                      "unsupported artifact manifest format: ~e"
                      format-version))
  (when (null? saved-ports)
    (raise-user-error 'openems-load-artifacts
                      "artifact manifest has no port description"))
  (define result-ports
    (for/list ([port-data (in-list saved-ports)])
      (define port-name (hash-ref port-data 'name #f))
      (define reference-impedance
        (hash-ref port-data 'impedance_ohms #f))
      (unless (and port-name (finite-real? reference-impedance)
                   (> reference-impedance 0))
        (raise-user-error 'openems-load-artifacts
                          "artifact manifest has an invalid port description"))
      (openems-result-port port-name reference-impedance)))
  (define solver (hash-ref manifest 'solver (hash)))
  (define saved-octave
    (let ([value (and (hash? solver)
                      (hash-ref solver 'octave_executable #f))])
      (and (path-string? value) value)))
  (define (saved-text name)
    (define path (build-path root name))
    (if (file-exists? path) (file->string path) ""))
  ;; A loaded directory is caller-owned. openems-close! invalidates this
  ;; handle but deliberately does not delete it from disk.
  (define artifacts
    (openems-artifacts root
                       (build-path root "run-openems.m")
                       simulation-directory manifest-path
                       #f #t))
  (define run
    (openems-run-info
     saved-octave
     (hash-ref manifest 'elapsed_ms 0)
     (hash-ref manifest 'exit_code 0)
     (saved-text "octave.stdout")
     (saved-text "octave.stderr")
     artifacts manifest))
  (if (= (length result-ports) 1)
      (let* ([port (first result-ports)]
             [result-path
              (build-path simulation-directory "port-results.csv")])
        (openems-sweep-result
         run
         (openems-result-port-name port)
         (openems-result-port-reference-impedance port)
         (parse-openems-port-results result-path)))
      (let ([names (map openems-result-port-name result-ports)])
        (openems-multiport-result
         run result-ports
         (parse-openems-s-parameter-results
          (build-path simulation-directory "s-parameters.csv") names)
         (for/hash ([name (in-list names)] [index (in-naturals 1)])
           (values
            name
            (parse-openems-port-results
             (build-path simulation-directory
                         (format "excitation-~a" index)
                         "port-results.csv"))))))))

;; Keep the solver's detailed result available while presenting the plotting
;; layer with a backend-independent one-port network sweep.
(define (openems-sweep->network-sweep result)
  (unless (or (openems-sweep-result? result)
              (openems-multiport-result? result))
    (raise-argument-error
     'openems-sweep->network-sweep
     "(or/c openems-sweep-result? openems-multiport-result?)"
     result))
  (define (convert name sample)
    (define gamma (openems-port-sample-reflection-coefficient sample))
    (network-sample
     name
     (openems-port-sample-frequency-mhz sample)
     gamma
     (openems-port-sample-impedance sample)
     (openems-port-sample-s11-db sample)
     (reflection-magnitude->vswr (magnitude gamma))))
  (cond
    [(openems-sweep-result? result)
     (define name (format "~a" (openems-sweep-result-port-name result)))
     (network-sweep
      'openems
      (openems-sweep-result-run result)
      (openems-sweep-result-reference-impedance result)
      (map (lambda (sample) (convert name sample))
           (openems-sweep-result-samples result)))]
    [else
     (define ports (openems-multiport-result-ports result))
     (define references
       (remove-duplicates
        (map openems-result-port-reference-impedance ports) =))
     (unless (= (length references) 1)
       (error 'openems-sweep->network-sweep
              (string-append
               "the legacy impedance, return-loss, and Smith-chart views "
               "require every port to use the same reference impedance; "
               "use the S-parameter views for mixed-impedance ports")))
     (network-sweep
      'openems
      (openems-multiport-result-run result)
      (first references)
      (append*
       (for/list ([port (in-list ports)])
         (define name (format "~a" (openems-result-port-name port)))
         (map (lambda (sample) (convert name sample))
              (hash-ref (openems-multiport-result-input-samples result)
                        (openems-result-port-name port))))))]))

(define (matrix-rotate transform vector)
  (for/vector ([row (in-list transform)])
    (for/sum ([coefficient (in-list (take row 3))]
              [value (in-vector vector)])
      (* coefficient value))))

(define (unit-vector vector)
  (define length
    (sqrt (for/sum ([value (in-vector vector)]) (sqr value))))
  (for/vector ([value (in-vector vector)]) (/ value length)))

(define (complex-dot left right)
  (for/sum ([a (in-vector left)] [b (in-vector right)]) (* a b)))

(define (spherical-direction theta phi)
  (vector (* (sin theta) (cos phi))
          (* (sin theta) (sin phi))
          (cos theta)))

(define (spherical-theta-basis theta phi)
  (vector (* (cos theta) (cos phi))
          (* (cos theta) (sin phi))
          (- (sin theta))))

(define (spherical-phi-basis _theta phi)
  (vector (- (sin phi)) (cos phi) 0))

(define (db-from-field amplitude reference directivity-db)
  (and (> amplitude 0)
       (+ directivity-db (* 20 (/ (log (/ amplitude reference)) (log 10))))))

;; The CSV deliberately retains the solver spherical basis. Racket performs
;; the rigid inverse transform on both the direction and complex E vector so
;; the resulting pattern shares the user's Antenna Turtle coordinate frame.
(define (parse-openems-nf2ff-results path frequency-mhz directivity-linear
                                      radiated-power transform run)
  (unless (file-exists? path)
    (raise-user-error 'parse-openems-nf2ff-results
                      "OpenEMS NF2FF result file does not exist: ~a" path))
  (define rows
    (for/list ([line (in-list (file->lines path))]
               #:unless (string=? (string-trim line) ""))
      (define fields (map string->number (string-split line ",")))
      (unless (and (= (length fields) 6) (andmap number? fields))
        (error 'parse-openems-nf2ff-results "invalid NF2FF row: ~e" line))
      fields))
  (when (null? rows)
    (error 'parse-openems-nf2ff-results "NF2FF result contains no samples"))
  (define field-norms
    (for/list ([row (in-list rows)])
      (match-define (list _theta _phi et-real et-imag ep-real ep-imag) row)
      (sqrt (+ (sqr (magnitude (make-rectangular et-real et-imag)))
               (sqr (magnitude (make-rectangular ep-real ep-imag)))))))
  (define maximum-field (apply max field-norms))
  (unless (> maximum-field 0)
    (error 'parse-openems-nf2ff-results "NF2FF result has zero field everywhere"))
  (define directivity-db (* 10 (/ (log directivity-linear) (log 10))))
  (define samples
    (for/list ([row (in-list rows)] [field-norm (in-list field-norms)])
      (match-define (list theta-deg phi-deg et-real et-imag ep-real ep-imag) row)
      (define theta (degrees->radians theta-deg))
      (define phi (degrees->radians phi-deg))
      (define solver-direction (spherical-direction theta phi))
      (define user-direction
        (unit-vector (matrix-rotate transform solver-direction)))
      (define solver-e-theta (make-rectangular et-real et-imag))
      (define solver-e-phi (make-rectangular ep-real ep-imag))
      (define solver-field
        (for/vector ([theta-component
                      (in-vector (spherical-theta-basis theta phi))]
                     [phi-component
                      (in-vector (spherical-phi-basis theta phi))])
          (+ (* solver-e-theta theta-component)
             (* solver-e-phi phi-component))))
      (define user-field (matrix-rotate transform solver-field))
      (define user-theta
        (acos (max -1.0 (min 1.0 (vector-ref user-direction 2)))))
      (define user-phi
        (let ([angle (atan (vector-ref user-direction 1)
                           (vector-ref user-direction 0))])
          (if (negative? angle) (+ angle (* 2 pi)) angle)))
      (define user-e-theta
        (complex-dot user-field (spherical-theta-basis user-theta user-phi)))
      (define user-e-phi
        (complex-dot user-field (spherical-phi-basis user-theta user-phi)))
      (define sample
        (nec2c-pattern-sample
         frequency-mhz theta-deg phi-deg
         (- 90 (radians->degrees user-theta))
         (radians->degrees user-phi)
         (db-from-field (magnitude user-e-theta) maximum-field directivity-db)
         (db-from-field (magnitude user-e-phi) maximum-field directivity-db)
         (db-from-field field-norm maximum-field directivity-db)
         #f #f #f user-e-theta user-e-phi))
      (set-nec2c-pattern-sample-direction! sample user-direction)
      sample))
  (define theta-values (remove-duplicates (map first rows)))
  (define phi-values (remove-duplicates (map second rows)))
  (nec2c-pattern-grid
   (hash 'backend 'openems
         'run run
         'frequency_mhz frequency-mhz
         'maximum_directivity_db directivity-db
         'radiated_power_w radiated-power)
   theta-values phi-values samples))

(define (angular-values who stop step #:include-stop? [include-stop? #t])
  (positive-real who step "angular step in degrees")
  (define quotient (/ stop step))
  (define count (inexact->exact (round quotient)))
  (unless (< (abs (- quotient count)) 1e-8)
    (raise-arguments-error who
                           "angular step must divide the angular range exactly"
                           "range" stop "step" step))
  (for/list ([index (in-range (if include-stop? (add1 count) count))])
    (* index step)))

(define (nf2ff-grid-matches? path theta-values phi-values)
  (and
   (file-exists? path)
   (with-handlers ([exn:fail? (lambda (_failure) #f)])
     (define actual
       (for/list ([line (in-list (file->lines path))]
                  #:unless (string=? (string-trim line) ""))
         (define fields (map string->number (string-split line ",")))
         (unless (and (= (length fields) 6) (andmap number? fields))
           (error 'nf2ff-grid-matches? "invalid NF2FF row"))
         (take fields 2)))
     (define expected
       (for*/list ([theta (in-list theta-values)]
                   [phi (in-list phi-values)])
         (list theta phi)))
     (and (= (length actual) (length expected))
          (for/and ([got (in-list actual)] [wanted (in-list expected)])
            (for/and ([a (in-list got)] [b (in-list wanted)])
              (< (abs (- a b)) 1e-8)))))))

(define (write-nf2ff-driver directory simulation-path frequency-hz
                            theta-values phi-values suffix)
  (define path (build-path directory (format "postprocess-nf2ff-~a.m" suffix)))
  (call-with-output-file path
    #:exists 'truncate/replace
    (lambda (out)
      (define (line format-string . values)
        (apply fprintf out (string-append format-string "\n") values))
      (write-octave-openems-loader line)
      (line "load('~a/nf2ff-box.mat');" simulation-path)
      (line "frequency = ~a;" (number-string frequency-hz))
      (line "theta = (~a) * pi / 180;" (octave-vector theta-values))
      (line "phi = (~a) * pi / 180;" (octave-vector phi-values))
      (line "nf2ff = CalcNF2FF(nf2ff, '~a', frequency, theta, phi, 'Center', [0 0 0], 'Mode', 1, 'Outfile', 'nf2ff-~a.h5');"
            simulation-path suffix)
      (line "fid = fopen('~a/nf2ff-~a.csv', 'w');" simulation-path suffix)
      (line "Etheta = nf2ff.E_theta{1}; Ephi = nf2ff.E_phi{1};")
      (line "for ti = 1:numel(theta)")
      (line "  for pi_idx = 1:numel(phi)")
      (line "    fprintf(fid, '%.17g,%.17g,%.17g,%.17g,%.17g,%.17g\\n', theta(ti)*180/pi, phi(pi_idx)*180/pi, real(Etheta(ti,pi_idx)), imag(Etheta(ti,pi_idx)), real(Ephi(ti,pi_idx)), imag(Ephi(ti,pi_idx)));")
      (line "  end")
      (line "end")
      (line "fclose(fid);")
      (line "fid = fopen('~a/nf2ff-~a-metadata.csv', 'w');"
            simulation-path suffix)
      (line "fprintf(fid, '%.17g,%.17g,%.17g\\n', frequency, nf2ff.Dmax(1), nf2ff.Prad(1));")
      (line "fclose(fid);")))
  path)

(define (best-match-frequency result)
  (openems-port-sample-frequency-mhz
   (argmin (lambda (sample)
             (magnitude
              (openems-port-sample-reflection-coefficient sample)))
           (openems-sweep-result-samples result))))

(define (openems-radiation-grid result
                                 #:frequency [requested-frequency #f]
                                 #:excitation [requested-excitation #f]
                                 #:theta-step [theta-step 2]
                                 #:phi-step [phi-step 2]
                                 #:octave [requested-octave #f]
                                 #:reuse? [reuse? #t]
                                 #:timeout [timeout #f])
  (unless (or (openems-sweep-result? result)
              (openems-multiport-result? result))
    (raise-argument-error
     'openems-radiation-grid
     "(or/c openems-sweep-result? openems-multiport-result?)" result))
  (unless (or (not timeout) (and (finite-real? timeout) (> timeout 0)))
    (raise-argument-error 'openems-radiation-grid
                          "(or/c #f positive-real?)" timeout))
  (unless (boolean? reuse?)
    (raise-argument-error 'openems-radiation-grid "boolean?" reuse?))
  (define multiport? (openems-multiport-result? result))
  (define run
    (if multiport?
        (openems-multiport-result-run result)
        (openems-sweep-result-run result)))
  (define result-ports
    (if multiport?
        (openems-multiport-result-ports result)
        (list
         (openems-result-port
          (openems-sweep-result-port-name result)
          (openems-sweep-result-reference-impedance result)))))
  (define excitation-port
    (if requested-excitation
        (or (for/first ([port (in-list result-ports)]
                        #:when
                        (equal? (format "~a" (openems-result-port-name port))
                                (format "~a" requested-excitation)))
              port)
            (raise-arguments-error
             'openems-radiation-grid
             "unknown excitation port"
             "excitation" requested-excitation
             "available ports" (map openems-result-port-name result-ports)))
        (first result-ports)))
  (define excitation-index
    (add1 (index-of result-ports excitation-port)))
  (define artifacts (openems-run-info-artifacts run))
  (unless (and (openems-artifacts-available? artifacts)
               (directory-exists? (openems-artifacts-directory artifacts)))
    (raise-user-error 'openems-radiation-grid
                      "the OpenEMS field artifacts have been released"))
  (define manifest (openems-run-info-manifest run))
  (define sweep (hash-ref manifest 'sweep))
  (define frequency
    (cond
      [(not requested-frequency) (hash-ref manifest 'model_frequency_mhz)]
      [(eq? requested-frequency 'best-match)
       (if multiport?
           (best-match-frequency
            (openems-sweep-result
             run
             (openems-result-port-name excitation-port)
             (openems-result-port-reference-impedance excitation-port)
             (hash-ref (openems-multiport-result-input-samples result)
                       (openems-result-port-name excitation-port))))
           (best-match-frequency result))]
      [(finite-real? requested-frequency) requested-frequency]
      [else
       (raise-argument-error 'openems-radiation-grid
                             "(or/c #f 'best-match positive-real?)"
                             requested-frequency)]))
  (unless (<= (hash-ref sweep 'start_mhz) frequency
              (hash-ref sweep 'stop_mhz))
    (raise-arguments-error
     'openems-radiation-grid
     "requested frequency is outside the recorded excitation sweep"
     "frequency" frequency
     "sweep" (list (hash-ref sweep 'start_mhz) (hash-ref sweep 'stop_mhz))))
  (define theta-values
    (angular-values 'openems-radiation-grid 180 theta-step))
  (define phi-values
    (angular-values 'openems-radiation-grid 360 phi-step #:include-stop? #f))
  (define suffix
    (regexp-replace*
     #px"[^0-9A-Za-z]+"
     (if multiport?
         (format "~a-~aMHz"
                 (openems-result-port-name excitation-port) frequency)
         (format "~aMHz" frequency))
     "_"))
  (define directory (openems-artifacts-directory artifacts))
  (define simulation-relative-path
    (if multiport?
        (format "simulation/excitation-~a" excitation-index)
        "simulation"))
  (define excitation-simulation-directory
    (build-path directory simulation-relative-path))
  (define stdout-path (build-path directory (format "nf2ff-~a.stdout" suffix)))
  (define stderr-path (build-path directory (format "nf2ff-~a.stderr" suffix)))
  (define result-path
    (build-path excitation-simulation-directory
                (format "nf2ff-~a.csv" suffix)))
  (define metadata-path
    (build-path excitation-simulation-directory
                (format "nf2ff-~a-metadata.csv" suffix)))
  (define reused?
    (and reuse?
         (file-exists? metadata-path)
         (nf2ff-grid-matches? result-path theta-values phi-values)))
  (define elapsed
    (if reused?
        0
        (let ()
          (define driver
            (write-nf2ff-driver directory simulation-relative-path
                                (* frequency 1e6)
                                theta-values phi-values suffix))
          (define octave
            (resolve-octave
             (or requested-octave (openems-run-info-octave-executable run))))
          (define-values (status timed-out? cancelled? elapsed)
            (run-command
             octave
             (list "--quiet" "--no-gui"
                   (path->string (file-name-from-path driver)))
             directory stdout-path stderr-path timeout))
          (when (or timed-out? cancelled? (not (zero? status)))
            (raise-user-error
             'openems-radiation-grid
             "NF2FF postprocessing ~a; artifacts retained in ~a\n~a"
             (cond
               [timed-out? "timed out"]
               [cancelled? "was cancelled"]
               [else (format "exited with status ~a" status)])
             directory
             (if (file-exists? stderr-path) (file->string stderr-path) "")))
          elapsed)))
  (define metadata (read-number-list metadata-path))
  (unless (= (length metadata) 3)
    (error 'openems-radiation-grid "invalid NF2FF metadata: ~e" metadata))
  (match-define (list _frequency-hz directivity radiated-power) metadata)
  (define updated-manifest
    (hash-set*
     manifest
     'nf2ff_last_postprocess
     (hash 'frequency_mhz (exact->inexact frequency)
           'excitation_port
           (format "~a" (openems-result-port-name excitation-port))
           'theta_step_deg (exact->inexact theta-step)
           'phi_step_deg (exact->inexact phi-step)
           'elapsed_ms elapsed
           'reused_existing reused?
           'maximum_directivity_linear directivity
           'radiated_power_w radiated-power)
     'artifacts (artifact-sizes directory)))
  ;; Loaded artifact directories are caller-owned and may be read-only. Keep
  ;; postprocessing metadata in the returned run without mutating them.
  (when (openems-artifacts-temporary? artifacts)
    (write-manifest directory updated-manifest))
  (define updated-run
    (struct-copy openems-run-info run [manifest updated-manifest]))
  (parse-openems-nf2ff-results
   result-path frequency directivity radiated-power
   (hash-ref manifest 'solver_to_user_transform)
   updated-run))

(define (make-progress-window title maximum-timesteps end-criteria directory)
  (with-handlers ([exn:fail?
                   (lambda (failure)
                     (fprintf (current-error-port)
                              "OpenEMS progress window unavailable: ~a\n"
                              (exn-message failure))
                     #f)])
    ((dynamic-require openems-progress-path 'make-openems-progress-window)
     title maximum-timesteps
     (* 10 (/ (log end-criteria) (log 10)))
     (path->string directory))))

(define (latest-progress-values path)
  (and (file-exists? path)
       (let-values
           ([(latest _excitation)
             (for/fold ([latest #f] [excitation #f])
                       ([line (in-list (file->lines path))])
               (define excitation-match
                 (regexp-match openems-excitation-line-rx line))
               (define next-excitation
                 (if excitation-match
                     (list (string->number (list-ref excitation-match 1))
                           (string->number (list-ref excitation-match 2)))
                     excitation))
               (define match (regexp-match openems-progress-line-rx line))
               (values
                (if match
                    (list line
                          (list-ref match 1)
                          (string->number (list-ref match 2))
                          (string->number (list-ref match 3))
                          (string->number
                           (regexp-replace*
                            #px"[[:space:]]"
                            (list-ref match 4)
                            ""))
                          next-excitation)
                    latest)
                next-excitation))])
         latest)))

(define (solver-finished? path)
  (and (file-exists? path)
       (for/or ([line (in-list (file->lines path))])
         (regexp-match? #px"^Time for [0-9]+ iterations" line))))

(define (run-command executable arguments directory stdout-path stderr-path timeout
                     [progress #f])
  (define started (current-inexact-milliseconds))
  (define environment
    (environment-variables-copy (current-environment-variables)))
  (environment-variables-set! environment #"LC_ALL" #"C")
  (define-values (process timed-out? cancelled?)
    (parameterize ([current-environment-variables environment]
                   [current-directory directory])
      (call-with-output-file stdout-path
        #:exists 'truncate/replace
        (lambda (stdout)
          (call-with-output-file stderr-path
            #:exists 'truncate/replace
            (lambda (stderr)
              ;; Octave launches OpenEMS as a child. A dedicated process group
              ;; lets cancellation, timeout, and Ctrl-C terminate the complete
              ;; solver tree instead of merely killing the Octave parent.
              (define-values (process _stdout stdin _stderr)
                (apply subprocess stdout #f stderr 'new executable arguments))
              (close-output-port stdin)
              (define stop-monitor? (box #f))
              (define monitor
                (and progress
                     (thread
                      (lambda ()
                        (let loop ([previous-line #f] [finishing? #f])
                          (unless (unbox stop-monitor?)
                            (define values
                              (with-handlers ([exn:fail? (lambda (_failure) #f)])
                                (latest-progress-values stdout-path)))
                            (define next-line
                              (if values (first values) previous-line))
                            (when (and values
                                       (not (equal? next-line previous-line)))
                              (apply (hash-ref progress 'update) (rest values)))
                            (define next-finishing?
                              (or finishing?
                                  (with-handlers
                                      ([exn:fail? (lambda (_failure) #f)])
                                    (solver-finished? stdout-path))))
                            (when (and next-finishing? (not finishing?))
                              ((hash-ref progress 'phase)
                               "FDTD complete; extracting port results…"))
                            (sleep 0.25)
                            (loop next-line next-finishing?)))))))
              (define (finish-progress!)
                (set-box! stop-monitor? #t)
                (when monitor (thread-wait monitor))
                (when progress ((hash-ref progress 'close))))
              (define process-event
                (handle-evt process (lambda (_process) 'completed)))
              (define cancel-event
                (and progress (hash-ref progress 'cancel-evt #f)))
              (define wait-events
                (if cancel-event
                    (list process-event
                          (handle-evt cancel-event
                                      (lambda (_event) 'cancelled)))
                    (list process-event)))
              (define outcome
                (with-handlers
                    ([exn:break?
                      (lambda (failure)
                        (subprocess-kill process #t)
                        (sync process)
                        (finish-progress!)
                        (raise failure))])
                  (if timeout
                      (apply sync/timeout timeout wait-events)
                      (apply sync wait-events))))
              (define timed-out? (not outcome))
              (define cancelled? (eq? outcome 'cancelled))
              (when (or timed-out? cancelled?)
                (subprocess-kill process #t)
                (sync process))
              (finish-progress!)
              (values process timed-out? cancelled?)))))))
  (values (subprocess-status process)
          timed-out?
          cancelled?
          (- (current-inexact-milliseconds) started)))

(define (artifact-sizes directory)
  (for/list ([path (in-directory directory)] #:when (file-exists? path))
    (hash 'path (path->string (find-relative-path directory path))
          'bytes (file-size path))))

(define (git-revision)
  (define git (find-executable-path "git"))
  (and git
       (let ([output (open-output-string)])
         (define success?
           (parameterize ([current-output-port output]
                          [current-error-port (open-output-nowhere)])
             (system* git "rev-parse" "HEAD")))
         (and success? (string-trim (get-output-string output))))))

(define (openems-sweep start-mhz stop-mhz
                       #:steps [steps 101]
                       #:cells-per-wavelength [cells-per-wavelength 20]
                       #:minimum-dielectric-cells
                       [minimum-dielectric-cells
                        default-minimum-dielectric-cells]
                       #:minimum-trace-cells
                       [minimum-trace-cells default-minimum-trace-cells]
                       #:metal-edge-resolution
                       [requested-metal-edge-resolution #f]
                       #:mesh-grading [mesh-grading 1.4]
                       #:padding-wavelengths [padding-wavelengths 0.5]
                       #:max-timesteps [maximum-timesteps
                                        default-maximum-timesteps]
                       #:end-criteria [end-criteria default-end-criteria]
                       #:wire-segments [wire-segments 24]
                       #:octave [requested-octave #f]
                       #:keep-artifacts? [keep? #t]
                       #:progress? [progress? #t]
                       #:timeout [timeout #f])
  (call-with-derived-wire-scene
   (lambda (derivation)
     (openems-sweep/prepared
      start-mhz stop-mhz
      #:steps steps
      #:cells-per-wavelength cells-per-wavelength
      #:minimum-dielectric-cells minimum-dielectric-cells
      #:minimum-trace-cells minimum-trace-cells
      #:metal-edge-resolution requested-metal-edge-resolution
      #:mesh-grading mesh-grading
      #:padding-wavelengths padding-wavelengths
      #:max-timesteps maximum-timesteps
      #:end-criteria end-criteria
      #:octave requested-octave
      #:keep-artifacts? keep?
      #:progress? progress?
      #:timeout timeout
      #:wire-derivation derivation))
   #:segments wire-segments))

(define (openems-sweep/prepared start-mhz stop-mhz
                       #:steps [steps 101]
                       #:cells-per-wavelength [cells-per-wavelength 20]
                       #:minimum-dielectric-cells
                       [minimum-dielectric-cells
                        default-minimum-dielectric-cells]
                       #:minimum-trace-cells
                       [minimum-trace-cells default-minimum-trace-cells]
                       #:metal-edge-resolution
                       [requested-metal-edge-resolution #f]
                       #:mesh-grading [mesh-grading 1.4]
                       #:padding-wavelengths [padding-wavelengths 0.5]
                       #:max-timesteps [maximum-timesteps
                                        default-maximum-timesteps]
                       #:end-criteria [end-criteria default-end-criteria]
                       #:octave [requested-octave #f]
                       #:keep-artifacts? [keep? #t]
                       #:progress? [progress? #t]
                       #:timeout [timeout #f]
                       #:wire-derivation [wire-derivation #f])
  (positive-real 'openems-sweep start-mhz "start frequency in MHz")
  (positive-real 'openems-sweep stop-mhz "stop frequency in MHz")
  (unless (> stop-mhz start-mhz)
    (raise-arguments-error 'openems-sweep
                           "stop frequency must be greater than start frequency"
                           "start" start-mhz "stop" stop-mhz))
  (unless (and (exact-integer? steps) (>= steps 2))
    (raise-argument-error 'openems-sweep "exact integer >= 2" steps))
  (positive-real 'openems-sweep cells-per-wavelength "cells per wavelength")
  (unless (exact-positive-integer? minimum-dielectric-cells)
    (raise-argument-error
     'openems-sweep "exact-positive-integer?" minimum-dielectric-cells))
  (unless (exact-positive-integer? minimum-trace-cells)
    (raise-argument-error
     'openems-sweep "exact-positive-integer?" minimum-trace-cells))
  (unless (or (not requested-metal-edge-resolution)
              (and (finite-real? requested-metal-edge-resolution)
                   (positive? requested-metal-edge-resolution)))
    (raise-argument-error
     'openems-sweep "(or/c #f positive-real?)"
     requested-metal-edge-resolution))
  (unless (and (finite-real? mesh-grading) (> mesh-grading 1))
    (raise-argument-error 'openems-sweep "real > 1" mesh-grading))
  (positive-real 'openems-sweep padding-wavelengths "padding wavelengths")
  (unless (exact-positive-integer? maximum-timesteps)
    (raise-argument-error 'openems-sweep "exact-positive-integer?" maximum-timesteps))
  (unless (and (finite-real? end-criteria) (> end-criteria 0) (< end-criteria 1))
    (raise-argument-error 'openems-sweep "real strictly between 0 and 1" end-criteria))
  (unless (boolean? keep?)
    (raise-argument-error 'openems-sweep "boolean?" keep?))
  (unless (boolean? progress?)
    (raise-argument-error 'openems-sweep "boolean?" progress?))
  (unless (or (not timeout) (and (finite-real? timeout) (> timeout 0)))
    (raise-argument-error 'openems-sweep "(or/c #f positive-real?)" timeout))
  (validate-model!)
  (validate-solid-scene!)
  (when (and (null? (model-bodies)) (null? (model-sheets)))
    (raise-user-error 'openems-sweep
                      "the physical scene has no volume bodies or sheets"))
  (when (null? (model-ports))
    (raise-user-error
     'openems-sweep
     "OpenEMS requires at least one explicit or wire-derived lumped port"))
  (define user-ports (model-ports))
  ;; One-port models retain automatic convenience alignment. Multiport models
  ;; deliberately preserve user coordinates and must already be grid-aligned.
  (define transform (simulation-transform user-ports))
  (define mesh-constraints
    (map (lambda (constraint)
           (transform-mesh-constraint constraint transform))
         (model-mesh-constraints)))
  (define octave (resolve-octave requested-octave))
  (define directory
    (make-temporary-file "antenna-turtle-openems~a" 'directory))
  (printf "OpenEMS artifacts: ~a\n" directory)
  (flush-output)
  (define simulation-directory (build-path directory "simulation"))
  (define driver-path (build-path directory "run-openems.m"))
  (define manifest-path (build-path directory "simulation-manifest.rktd"))
  (define artifacts
    (openems-artifacts directory driver-path simulation-directory
                       manifest-path #t #t))
  (define stdout-path (build-path directory "octave.stdout"))
  (define stderr-path (build-path directory "octave.stderr"))
  (define inverse-transform (inverse-rigid-transform transform))
  (define ports
    (map (lambda (port) (transform-port port transform)) user-ports))
  (define components
    (map (lambda (component) (transform-component component transform))
         (model-components)))
  (validate-component-alignment! components)
  (define bodies (transform-and-export-bodies directory transform))
  (define sheets (transform-and-export-sheets transform))
  (for ([sheet (in-list sheets)]
        #:when (exported-sheet-trace-width sheet))
    (define treatment (trace-mesh-treatment sheet))
    (printf "OpenEMS trace mesh: ~a -- ~a~a\n"
            (exported-sheet-name sheet)
            (case treatment
              [(ideal-orthogonal) "ideal orthogonal metal-edge treatment"]
              [(hybrid) "hybrid orthogonal/oblique treatment"]
              [else "oblique width-based Cartesian refinement"])
            (if (eq? treatment 'ideal-orthogonal)
                ""
                (format "; target ~a cells across width"
                        minimum-trace-cells))))
  (for ([body (in-list bodies)]
        #:when (em-material-loss-spec (exported-body-material body)))
    (define material (exported-body-material body))
    (printf
     (string-append
      "OpenEMS material notice: dielectric ~a uses loss tangent ~a at ~a MHz; "
      "the backend models it as constant conductivity, so loss is a narrowband approximation.\n")
     (em-material-name material)
     (material-loss-value (em-material-loss-spec material))
     (dielectric-reference-frequency-mhz material (model-frequency))))
  (for ([item (in-list (append bodies sheets))])
    (define material (geometry-material item))
    (define physical-thickness
      (cond [(exported-body? item) (exported-body-metal-thickness item)]
            [else (exported-sheet-thickness item)]))
    (when (and physical-thickness
               (memq (em-material-kind material) '(conductor conducting-sheet)))
      (define effective-thickness
        (conductor-effective-sheet-thickness
         material physical-thickness (model-frequency)))
      (when (< effective-thickness physical-thickness)
        (printf
         (string-append
          "OpenEMS material notice: conductor ~a is ~a m thick; using ~a m "
          "(ten skin depths at ~a MHz) for the narrowband sheet model.\n")
         (em-material-name material) physical-thickness effective-thickness
         (model-frequency)))))
  (flush-output)
  (define geometry (append bodies sheets))
  (define dielectric-loss-accounting?
    (for/or ([body (in-list bodies)])
      (and (eq? (em-material-kind (exported-body-material body)) 'dielectric)
           (> (dielectric-effective-conductivity
               (exported-body-material body) (model-frequency))
              0))))
  (validate-component-contacts! geometry components)
  (define-values (physical-minimum physical-maximum) (scene-bounds geometry))
  (define component-minima
    (for/list ([component (in-list components)])
      (define-values (minimum _maximum) (component-bounds component)) minimum))
  (define component-maxima
    (for/list ([component (in-list components)])
      (define-values (_minimum maximum) (component-bounds component)) maximum))
  (define minimum
    (for/list ([axis (in-range 3)])
      (apply min (cons (list-ref physical-minimum axis)
                       (map (lambda (bounds) (list-ref bounds axis))
                            component-minima)))))
  (define maximum
    (for/list ([axis (in-range 3)])
      (apply max (cons (list-ref physical-maximum axis)
                       (map (lambda (bounds) (list-ref bounds axis))
                            component-maxima)))))
  (define wavelength-min (/ speed-of-light (* stop-mhz 1e6)))
  (define maximum-index
    (sqrt
     (for/fold ([maximum 1]) ([body (in-list bodies)])
       (define material (exported-body-material body))
       (if (eq? (em-material-kind material) 'dielectric)
           (max maximum
                (* (em-material-relative-permittivity material)
                   (em-material-relative-permeability material)))
           maximum))))
  (define material-wavelength-min (/ wavelength-min maximum-index))
  (define max-resolution (/ material-wavelength-min cells-per-wavelength))
  (define metal-edge-resolution
    (or requested-metal-edge-resolution (/ max-resolution 2)))
  ;; Eight PML cells plus two ordinary cells must fit between every radiator
  ;; and the domain wall. Honor larger user padding, but silently enlarge a
  ;; too-small request rather than allowing conductors into the absorber.
  (define padding
    (max (* wavelength-min padding-wavelengths)
         (* 10 max-resolution)))
  (define domain-min (map (lambda (value) (- value padding)) minimum))
  (define domain-max (map (lambda (value) (+ value padding)) maximum))
  (validate-mesh-constraint-domain! mesh-constraints domain-min domain-max)
  (define critical-x
    (critical-axis-values geometry ports components mesh-constraints 0
                          (first domain-min) (first domain-max) max-resolution
                          minimum-dielectric-cells minimum-trace-cells
                          metal-edge-resolution))
  (define critical-y
    (critical-axis-values geometry ports components mesh-constraints 1
                          (second domain-min) (second domain-max) max-resolution
                          minimum-dielectric-cells minimum-trace-cells
                          metal-edge-resolution))
  (define critical-z
    (critical-axis-values geometry ports components mesh-constraints 2
                          (third domain-min) (third domain-max) max-resolution
                          minimum-dielectric-cells minimum-trace-cells
                          metal-edge-resolution))
  (define port-priorities
    (map (lambda (port) (derive-port-priority geometry port)) ports))
  (define component-priorities
    (map (lambda (component) (derive-component-priority geometry component))
         components))
  (write-octave-driver directory bodies sheets ports port-priorities
                       components component-priorities
                       start-mhz stop-mhz steps
                       critical-x critical-y critical-z max-resolution
                       (mesh-constraint-axis-values mesh-constraints 0)
                       (mesh-constraint-axis-values mesh-constraints 1)
                       (mesh-constraint-axis-values mesh-constraints 2)
                       mesh-grading maximum-timesteps end-criteria
                       minimum maximum wavelength-min)
  (define initial-manifest
    (hash
     'format_version 1
     'status "prepared"
     'antenna_turtle_version "0.5.0"
     'antenna_turtle_git_revision (or (git-revision) 'null)
     'manifold_version (format "~a" (m:manifold-version))
     'model_title (model-title)
     'model_frequency_mhz (exact->inexact (model-frequency))
     'sweep (hash 'start_mhz (exact->inexact start-mhz)
                  'stop_mhz (exact->inexact stop-mhz)
                  'steps steps)
     'user_to_solver_transform (matrix->lists transform)
     'solver_to_user_transform (matrix->lists inverse-transform)
     'geometry
     (append (map (lambda (body) (body-manifest body start-mhz stop-mhz)) bodies)
             (map (lambda (sheet) (sheet-manifest sheet start-mhz stop-mhz)) sheets))
     'lumped_elements
     (for/list ([component (in-list components)]
                [priority (in-list component-priorities)])
       (component-manifest component priority))
     'mesh_constraints (map mesh-constraint-manifest mesh-constraints)
     'wire_conversion
     (if wire-derivation
         (hash 'representation "capsule-union"
               'body_name
               (format "~a"
                       (solid-body-name
                        (wire-solid-derivation-body wire-derivation)))
               'edge_count (wire-solid-derivation-edge-count wire-derivation)
               'circular_segments (wire-solid-derivation-segments wire-derivation)
               'feed_edge_id
               (or (wire-solid-derivation-feed-edge-id wire-derivation) 'null)
               'derived_feed_gap_m
               (or (wire-solid-derivation-feed-gap wire-derivation) 'null)
               'feed_wire_radius_m
               (or (wire-solid-derivation-radius wire-derivation) 'null))
         'null)
     'port_count (length ports)
     'ports
     (for/list ([port (in-list ports)]
                [priority (in-list port-priorities)]
                [index (in-naturals 1)])
       (define-values (port-minimum port-maximum) (port-bounds port))
       (hash 'index index
             'name (format "~a" (lumped-port-name port))
             'impedance_ohms (exact->inexact (lumped-port-impedance port))
             'gap_m (exact->inexact (lumped-port-gap port))
             'width_m (exact->inexact (lumped-port-width port))
             'depth_m (exact->inexact (lumped-port-depth port))
             'minimum_m (map exact->inexact port-minimum)
             'maximum_m (map exact->inexact port-maximum)
             'direction (map exact->inexact
                             (point->list (lumped-port-direction port)))
             'priority priority
             'priority_source
             (if (lumped-port-priority port) "explicit" "automatic")))
     ;; Retain the original one-port key for artifact compatibility.
     'port
     (if (= (length ports) 1)
         (first
          (for/list ([port (in-list ports)]
                     [priority (in-list port-priorities)])
            (hash 'name (format "~a" (lumped-port-name port))
                  'impedance_ohms
                  (exact->inexact (lumped-port-impedance port))
                  'gap_m (exact->inexact (lumped-port-gap port))
                  'width_m (exact->inexact (lumped-port-width port))
                  'depth_m (exact->inexact (lumped-port-depth port))
                  'priority priority
                  'priority_source
                  (if (lumped-port-priority port)
                      "explicit" "automatic"))))
         'null)
     'mesh (hash 'policy "fixed-critical-coordinate-poc"
                 'minimum_dielectric_cells_per_extent
                 minimum-dielectric-cells
                 'minimum_trace_cells_across minimum-trace-cells
                 'metal_edge_resolution_m metal-edge-resolution
                 'critical_x (map exact->inexact critical-x)
                 'critical_y (map exact->inexact critical-y)
                 'critical_z (map exact->inexact critical-z)
                 'maximum_resolution_m max-resolution
                 'shortest_material_wavelength_m material-wavelength-min
                 'maximum_refractive_index maximum-index
                 'cells_per_wavelength (exact->inexact cells-per-wavelength)
                 'requested_padding_wavelengths
                 (exact->inexact padding-wavelengths)
                 'effective_padding_m padding
                 'grading (exact->inexact mesh-grading)
                 'boundary_conditions (make-list 6 "PML_8"))
     'nf2ff (hash 'recording "time-domain"
                  'name "nf2ff"
                  'box_policy "inner-PML-boundary"
                  'optimum_resolution_m (/ wavelength-min 15)
                  'postprocess_default_frequency_mhz
                  (exact->inexact (model-frequency)))
     'power_accounting
     (hash 'frequency_mhz (exact->inexact (model-frequency))
           'port_power "port-power.csv"
           'dielectric_power "dielectric-power.csv"
           'lumped_power "lumped-power.csv"
           'conductor_power "conservation remainder"
           'dielectric_method
           (if dielectric-loss-accounting?
               "openEMS raw SAR / CalcSAR"
               "zero"))
     'solver (hash 'octave_executable (path->string octave)
                   'driver "run-openems.m"
                   'excitation_center_hz 0.0
                   'excitation_bandwidth_hz (* (exact->inexact stop-mhz) 1e6)
                   'max_timesteps maximum-timesteps
                   'end_criteria end-criteria)))
  (write-manifest directory initial-manifest)
  (define progress
    (and progress?
         (make-progress-window (model-title) maximum-timesteps end-criteria
                               directory)))
  (define-values (status timed-out? cancelled? elapsed)
    (run-command octave '("--quiet" "--no-gui" "run-openems.m")
                 directory stdout-path stderr-path timeout progress))
  (define stdout (file->string stdout-path))
  (define stderr (file->string stderr-path))
  (define multiport? (> (length ports) 1))
  (define primary-simulation-directory
    (if multiport?
        (build-path simulation-directory "excitation-1")
        simulation-directory))
  (define mesh-available?
    (and (file-exists? (build-path simulation-directory "mesh-x.csv"))
         (file-exists? (build-path simulation-directory "mesh-y.csv"))
         (file-exists? (build-path simulation-directory "mesh-z.csv"))))
  (define solver-statistics
    (read-openems-statistics
     (build-path primary-simulation-directory "openEMS_stats.txt")
     maximum-timesteps))
  (define excitation-statistics
    (for/list ([port (in-list ports)] [index (in-naturals 1)])
      (define excitation-directory
        (if multiport?
            (build-path simulation-directory (format "excitation-~a" index))
            simulation-directory))
      (hash 'index index
            'port (format "~a" (lumped-port-name port))
            'statistics
            (read-openems-statistics
             (build-path excitation-directory "openEMS_stats.txt")
             maximum-timesteps))))
  (define versions
    (read-version-file (build-path simulation-directory "versions.txt")))
  (define mesh-values
    (and mesh-available?
         (list (read-number-list (build-path simulation-directory "mesh-x.csv"))
               (read-number-list (build-path simulation-directory "mesh-y.csv"))
               (read-number-list (build-path simulation-directory "mesh-z.csv")))))
  (define final-mesh
    (if mesh-values
        (match-let ([(list x y z) mesh-values])
          (define minimum-spacing
            (apply min
                   (append
                    (for/list ([first (in-list x)] [second (in-list (rest x))])
                      (- second first))
                    (for/list ([first (in-list y)] [second (in-list (rest y))])
                      (- second first))
                    (for/list ([first (in-list z)] [second (in-list (rest z))])
                      (- second first)))))
          (hash-set*
           (hash-ref initial-manifest 'mesh)
           'x x 'y y 'z z
           'minimum_cell_spacing_m minimum-spacing
           'cell_count (* (length x) (length y) (length z))))
        (hash-ref initial-manifest 'mesh)))
  (define final-nf2ff
    (if mesh-values
        (hash-set*
         (hash-ref initial-manifest 'nf2ff)
         'start_m
         (for/list ([axis (in-list mesh-values)]) (list-ref axis 8))
         'stop_m
         (for/list ([axis (in-list mesh-values)])
           (list-ref axis (- (length axis) 9))))
        (hash-ref initial-manifest 'nf2ff)))
  (define final-manifest
    (hash-set*
     initial-manifest
     'status (cond [cancelled? "cancelled"]
                   [timed-out? "timed-out"]
                   [(zero? status) "complete"]
                   [else "failed"])
     'elapsed_ms elapsed
     'exit_code status
     'software_versions versions
     'excitation_count (length ports)
     'solver_statistics solver-statistics
     'excitation_statistics excitation-statistics
     'mesh final-mesh
     'nf2ff final-nf2ff
     'artifacts (artifact-sizes directory)))
  (write-manifest directory final-manifest)
  (define run
    (openems-run-info octave elapsed status stdout stderr artifacts final-manifest))
  (cond
    [cancelled?
     (printf "OpenEMS simulation cancelled; ~a: ~a\n"
             (if keep? "artifacts retained" "removing artifacts")
             directory)
     (flush-output)
     (define result
       (if multiport?
           (openems-multiport-result
            run
            (map (lambda (port)
                   (openems-result-port
                    (lumped-port-name port) (lumped-port-impedance port)))
                 ports)
            '() (hash))
           (openems-sweep-result
            run (lumped-port-name (first ports))
            (lumped-port-impedance (first ports)) '())))
     (unless keep? (openems-close! result))
     result]
    [timed-out?
     (raise
      (exn:fail:openems
       (format "OpenEMS timed out after ~a seconds; artifacts retained in ~a"
               timeout directory)
       (current-continuation-marks)
       run))]
    [(not (zero? status))
     (raise
      (exn:fail:openems
       (format "OpenEMS/Octave exited with status ~a; artifacts retained in ~a"
               status directory)
       (current-continuation-marks)
       run))]
    [else
     (define s-parameter-path
       (build-path simulation-directory "s-parameters.csv"))
     (define input-result-paths
       (for/list ([index (in-range 1 (add1 (length ports)))])
         (build-path
          (if multiport?
              (build-path simulation-directory (format "excitation-~a" index))
              simulation-directory)
          "port-results.csv")))
     (unless (and (file-exists? s-parameter-path)
                  (andmap file-exists? input-result-paths))
       (raise
        (exn:fail:openems
         (format "OpenEMS did not create network results; artifacts retained in ~a"
                 directory)
         (current-continuation-marks)
         run)))
     (define result
       (if multiport?
           (let ([names (map lumped-port-name ports)])
             (openems-multiport-result
              run
              (map (lambda (port)
                     (openems-result-port
                      (lumped-port-name port) (lumped-port-impedance port)))
                   ports)
              (parse-openems-s-parameter-results s-parameter-path names)
              (for/hash ([name (in-list names)]
                         [path (in-list input-result-paths)])
                (values name (parse-openems-port-results path)))))
           (openems-sweep-result
            run (lumped-port-name (first ports))
            (lumped-port-impedance (first ports))
            (parse-openems-port-results (first input-result-paths)))))
     (unless keep? (openems-close! result))
     result]))

(define (openems-close! value)
  (define artifacts
    (cond
      [(openems-sweep-result? value)
       (openems-run-info-artifacts (openems-sweep-result-run value))]
      [(openems-multiport-result? value)
       (openems-run-info-artifacts (openems-multiport-result-run value))]
      [(openems-run-info? value) (openems-run-info-artifacts value)]
      [(openems-artifacts? value) value]
      [else
       (raise-argument-error
        'openems-close!
        (string-append
         "(or/c openems-sweep-result? openems-multiport-result? "
         "openems-run-info? openems-artifacts?)")
        value)]))
  (when (openems-artifacts-available? artifacts)
    (define directory (openems-artifacts-directory artifacts))
    (when (and (openems-artifacts-temporary? artifacts)
               (directory-exists? directory))
      (delete-directory/files directory))
    (set-openems-artifacts-available?! artifacts #f))
  (void))
