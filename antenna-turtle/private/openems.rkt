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
  (name filename material priority minimum maximum sha1 triangles)
  #:transparent)

(struct exported-sheet
  (name material priority points-2d transform minimum maximum)
  #:transparent)

(define octave-executable
  (make-parameter
   #f
   (lambda (value)
     (unless (or (not value) (path-string? value))
       (raise-argument-error 'octave-executable "(or/c #f path-string?)" value))
     value)))

(define speed-of-light 299792458.0)
(define default-maximum-timesteps 100000)
(define default-end-criteria 1e-5)
(define minimum-dielectric-cells-per-extent 4)
(define identity-rigid-transform
  '((1 0 0 0) (0 1 0 0) (0 0 1 0)))
(define-runtime-path openems-progress-path "openems-progress.rkt")

(define openems-progress-line-rx
  #px"\\[@[[:space:]]+([^]]+)\\][[:space:]]+Timestep:[[:space:]]+([0-9]+).*Speed:[[:space:]]+([0-9.]+)[[:space:]]+MC/s.*Energy:.*\\([[:space:]]*([+-]?[0-9.]+)dB\\)")
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

(define (material-manifest material)
  (hash 'name (format "~a" (em-material-name material))
        'kind (format "~a" (em-material-kind material))
        'relative_permittivity (or (em-material-relative-permittivity material) 'null)
        'relative_permeability (or (em-material-relative-permeability material) 'null)
        'electric_conductivity_s_per_m (or (em-material-electric-conductivity material) 'null)
        'magnetic_conductivity (or (em-material-magnetic-conductivity material) 'null)
        'thickness_m (or (em-material-thickness material) 'null)))

(define (body-manifest body)
  (hash 'representation "volume-stl"
        'name (format "~a" (exported-body-name body))
        'file (exported-body-filename body)
        'sha1 (exported-body-sha1 body)
        'priority (exported-body-priority body)
        'material (material-manifest (exported-body-material body))
        'minimum (map exact->inexact (exported-body-minimum body))
        'maximum (map exact->inexact (exported-body-maximum body))
        'triangle_count (exported-body-triangles body)))

(define (sheet-manifest sheet)
  (hash 'representation "planar-polygon"
        'name (format "~a" (exported-sheet-name sheet))
        'priority (exported-sheet-priority sheet)
        'material (material-manifest (exported-sheet-material sheet))
        'points_2d (map (lambda (point) (map exact->inexact point))
                        (exported-sheet-points-2d sheet))
        'local_to_solver_transform (matrix->lists (exported-sheet-transform sheet))
        'minimum (map exact->inexact (exported-sheet-minimum sheet))
        'maximum (map exact->inexact (exported-sheet-maximum sheet))))

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
    (unless (memq (em-material-kind (solid-body-material body)) '(pec dielectric))
      (raise-arguments-error
       'openems-sweep
       "OpenEMS volume bodies must use PEC or lossless dielectric material"
       "body" (solid-body-name body)
       "material" (solid-body-material body)))
    (define transformed (m:transform (solid-body-solid body) transform))
    (dynamic-wind
      void
      (lambda ()
        (define filename (format "body-~a.stl" index))
        (define path (build-path directory filename))
        (m:write-stl transformed path #:name (sanitize-label (solid-body-name body)))
        (define-values (minimum maximum) (m:solid-bounds transformed))
        (exported-body
         (solid-body-name body)
         filename
         (solid-body-material body)
         (or (solid-body-priority body) 10)
         (m-point->list minimum)
         (m-point->list maximum)
         (file-sha1 path)
         (m:solid-num-triangles transformed)))
      (lambda () (m:solid-close! transformed)))))

(define (list-subtract first second)
  (map - first second))

(define (transform-and-export-sheets transform)
  (for/list ([sheet (in-list (model-sheets))])
    (define points (map (lambda (point) (transform-point transform point))
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
    ;; The polygon lives in local z=0, so the transform's basis columns are u,
    ;; v, and n; csx-matrix-string serializes the matrix row-major for CSXCAD.
    (define local-to-solver
      (list (list (first u) (first v) (first transformed-normal) (first origin))
            (list (second u) (second v) (second transformed-normal) (second origin))
            (list (third u) (third v) (third transformed-normal) (third origin))))
    (define minimum
      (for/list ([axis (in-range 3)]) (apply min (map (lambda (p) (list-ref p axis)) points))))
    (define maximum
      (for/list ([axis (in-range 3)]) (apply max (map (lambda (p) (list-ref p axis)) points))))
    (exported-sheet (planar-sheet-name sheet)
                    (planar-sheet-material sheet)
                    (or (planar-sheet-priority sheet) 10)
                    points-2d local-to-solver minimum maximum)))

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

(define (bounds-intersect? geometry minimum maximum)
  (for/and ([low (in-list (geometry-minimum geometry))]
            [high (in-list (geometry-maximum geometry))]
            [other-low (in-list minimum)]
            [other-high (in-list maximum)])
    (and (<= low other-high) (<= other-low high))))

(define (port-bounds port)
  (define center (point->list (lumped-port-center port)))
  (define axes
    (list (point->list (lumped-port-transverse-u port))
          (point->list (lumped-port-transverse-v port))
          (point->list (lumped-port-direction port))))
  (define half-extents
    (list (/ (lumped-port-width port) 2)
          (/ (lumped-port-depth port) 2)
          (/ (lumped-port-gap port) 2)))
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
                               '(pec conducting-sheet)))
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

(define (axis-values geometry accessor axis)
  (for/list ([item (in-list geometry)])
    (list-ref (accessor item) axis)))

(define (dielectric-subdivision-values geometry axis max-resolution)
  ;; SmoothMeshLines limits large cells but does not guarantee that an
  ;; electrically thin material gets enough cells between its interfaces.
  ;; Add interior critical coordinates only where the wavelength-based limit
  ;; would otherwise permit fewer than the minimum number of cells.  In the
  ;; port-aligned solver coordinates this gives an ordinary planar substrate
  ;; four cells through its thickness without imposing that resolution on the
  ;; entire simulation domain.
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
                 (* minimum-dielectric-cells-per-extent max-resolution)))
         (for/list ([index
                     (in-range 1 minimum-dielectric-cells-per-extent)])
           (+ low (* extent
                     (/ index minimum-dielectric-cells-per-extent))))
         '()))))

(define (critical-axis-values geometry ports axis domain-min domain-max
                              max-resolution)
  (define port-values
    (append*
     (for/list ([port (in-list ports)])
       (define-values (minimum maximum) (port-bounds port))
       (list (list-ref minimum axis) (list-ref maximum axis)))))
  (sort
   (remove-duplicates
    (append (list domain-min domain-max 0)
            port-values
            (axis-values geometry geometry-minimum axis)
            (axis-values geometry geometry-maximum axis)
            (dielectric-subdivision-values geometry axis max-resolution))
    =)
   <))

(define (scene-bounds geometry)
  (values
   (for/list ([axis (in-range 3)])
     (apply min (axis-values geometry geometry-minimum axis)))
   (for/list ([axis (in-range 3)])
     (apply max (axis-values geometry geometry-maximum axis)))))

(define (write-octave-driver directory bodies sheets ports port-priorities
                             start-mhz stop-mhz steps
                             critical-x critical-y critical-z max-resolution
                             mesh-grading maximum-timesteps end-criteria
                             geometry-minimum geometry-maximum wavelength-min)
  (define path (build-path directory "run-openems.m"))
  (define port-count (length ports))
  (call-with-output-file path
    #:exists 'truncate/replace
    (lambda (out)
      (define (line format-string . values)
        (apply fprintf out (string-append format-string "\n") values))
      (line "pkg load openems;")
      (line "pkg load csxcad;")
      (line "physical_constants;")
      (line "unit = 1.0;")
      (line "f_start = ~a;" (number-string (* start-mhz 1e6)))
      (line "f_stop = ~a;" (number-string (* stop-mhz 1e6)))
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
      (line "mesh_cells = (numel(mesh.x)-1) * (numel(mesh.y)-1) * (numel(mesh.z)-1);")
      (line "fprintf('Antenna Turtle mesh: %d x %d x %d lines; %d cells; max resolution %.6g m\\n', numel(mesh.x), numel(mesh.y), numel(mesh.z), mesh_cells, ~a);"
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
          (line "copyfile('~a', [Sim_Path '/~a']);"
                (exported-body-filename body) (exported-body-filename body))
          (case (em-material-kind material)
            [(pec) (line "CSX = AddMetal(CSX, '~a');" property)]
            [(dielectric)
             (line "CSX = AddMaterial(CSX, '~a');" property)
             (line "CSX = SetMaterialProperty(CSX, '~a', 'Epsilon', ~a, 'Mue', ~a);"
                   property
                   (number-string (em-material-relative-permittivity material))
                   (number-string (em-material-relative-permeability material)))])
          (line "CSX = ImportSTL(CSX, '~a', ~a, '~a');"
                property (exported-body-priority body)
                (exported-body-filename body)))
        (for ([sheet (in-list sheets)] [index (in-naturals 1)])
          (define property (format "sheet_~a" index))
          (define material (exported-sheet-material sheet))
          (case (em-material-kind material)
            [(pec) (line "CSX = AddMetal(CSX, '~a');" property)]
            [(conducting-sheet)
             (line "CSX = AddConductingSheet(CSX, '~a', ~a, ~a);"
                   property
                   (number-string (em-material-electric-conductivity material))
                   (number-string (em-material-thickness material)))])
          (line "sheet_points_~a = ~a;" index
                (octave-point-matrix (exported-sheet-points-2d sheet)))
          (line "CSX = AddPolygon(CSX, '~a', ~a, 2, 0, sheet_points_~a, 'Transform', {'Matrix', '~a'});"
                property (exported-sheet-priority sheet) index
                (csx-matrix-string (exported-sheet-transform sheet))))
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
        (line "WriteOpenEMS([Sim_Path '/' Sim_XML], FDTD, CSX);")
        (line "settings.LogFile = 'openems.log'; settings.Silent = 0;")
        (line "RunOpenEMS(Sim_Path, Sim_XML, '--dump-statistics', settings);")
        (for ([port-index (in-range 1 (add1 port-count))])
          (line "port{~a} = calcPort(port{~a}, Sim_Path, freq);"
                port-index port-index))
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
      (line "pkg load openems;")
      (line "pkg load csxcad;")
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
                          (string->number (list-ref match 4))
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
  (define bodies (transform-and-export-bodies directory transform))
  (define sheets (transform-and-export-sheets transform))
  (define geometry (append bodies sheets))
  (define-values (minimum maximum) (scene-bounds geometry))
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
  ;; Eight PML cells plus two ordinary cells must fit between every radiator
  ;; and the domain wall. Honor larger user padding, but silently enlarge a
  ;; too-small request rather than allowing conductors into the absorber.
  (define padding
    (max (* wavelength-min padding-wavelengths)
         (* 10 max-resolution)))
  (define domain-min (map (lambda (value) (- value padding)) minimum))
  (define domain-max (map (lambda (value) (+ value padding)) maximum))
  (define critical-x
    (critical-axis-values geometry ports 0
                          (first domain-min) (first domain-max) max-resolution))
  (define critical-y
    (critical-axis-values geometry ports 1
                          (second domain-min) (second domain-max) max-resolution))
  (define critical-z
    (critical-axis-values geometry ports 2
                          (third domain-min) (third domain-max) max-resolution))
  (define port-priorities
    (map (lambda (port) (derive-port-priority geometry port)) ports))
  (write-octave-driver directory bodies sheets ports port-priorities
                       start-mhz stop-mhz steps
                       critical-x critical-y critical-z max-resolution
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
     'geometry (append (map body-manifest bodies) (map sheet-manifest sheets))
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
                 minimum-dielectric-cells-per-extent
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
          (hash-set*
           (hash-ref initial-manifest 'mesh)
           'x x 'y y 'z z
           'cell_count (* (sub1 (length x)) (sub1 (length y)) (sub1 (length z)))))
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
