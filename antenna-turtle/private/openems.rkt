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
         racket/string
         racket/system
         (prefix-in m: manifold)
         "core.rkt"
         "network.rkt"
         "solid-core.rkt")

(provide
 octave-executable
 (struct-out openems-artifacts)
 (struct-out openems-run-info)
 (struct-out openems-port-sample)
 (struct-out openems-sweep-result)
 (struct-out exn:fail:openems)
 openems-sweep
 openems-sweep->network-sweep
 openems-close!
 parse-openems-port-results)

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

(struct exn:fail:openems exn:fail (run-info) #:transparent)

(struct exported-body
  (name filename priority minimum maximum sha1 triangles)
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

(define (matrix->lists matrix)
  (for/list ([row (in-list matrix)])
    (map exact->inexact row)))

(define (sanitize-label value)
  (define source (if (symbol? value) (symbol->string value) value))
  (define cleaned (regexp-replace* #px"[^A-Za-z0-9_]+" source "_"))
  (if (regexp-match? #px"^[A-Za-z]" cleaned)
      cleaned
      (string-append "g_" cleaned)))

(define (file-sha1 path)
  (call-with-input-file path sha1))

(define (geometry-manifest body)
  (hash 'name (format "~a" (exported-body-name body))
        'file (exported-body-filename body)
        'sha1 (exported-body-sha1 body)
        'priority (exported-body-priority body)
        'material "pec"
        'minimum (map exact->inexact (exported-body-minimum body))
        'maximum (map exact->inexact (exported-body-maximum body))
        'triangle_count (exported-body-triangles body)))

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
    (unless (eq? (em-material-kind (solid-body-material body)) 'pec)
      (raise-arguments-error
       'openems-sweep
       "the first OpenEMS milestone supports PEC volume bodies only"
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
         (or (solid-body-priority body) 10)
         (m-point->list minimum)
         (m-point->list maximum)
         (file-sha1 path)
         (m:solid-num-triangles transformed)))
      (lambda () (m:solid-close! transformed)))))

(define (axis-values bodies accessor axis)
  (for/list ([body (in-list bodies)])
    (list-ref (accessor body) axis)))

(define (critical-axis-values bodies axis domain-min domain-max port-low port-high)
  (sort
   (remove-duplicates
    (append (list domain-min domain-max 0 port-low port-high)
            (axis-values bodies exported-body-minimum axis)
            (axis-values bodies exported-body-maximum axis)))
   <))

(define (scene-bounds bodies)
  (values
   (for/list ([axis (in-range 3)])
     (apply min (axis-values bodies exported-body-minimum axis)))
   (for/list ([axis (in-range 3)])
     (apply max (axis-values bodies exported-body-maximum axis)))))

(define (write-octave-driver directory bodies port start-mhz stop-mhz steps
                             critical-x critical-y critical-z max-resolution
                             mesh-grading maximum-timesteps end-criteria)
  (define path (build-path directory "run-openems.m"))
  (define simulation-name "simulation")
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
      (line "FDTD = InitFDTD('NrTS', max_timesteps, 'EndCriteria', end_criteria);")
      (line "FDTD = SetGaussExcite(FDTD, f0, fc);")
      (line "FDTD = SetBoundaryCond(FDTD, {'PML_8' 'PML_8' 'PML_8' 'PML_8' 'PML_8' 'PML_8'});")
      (line "CSX = InitCSX();")
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
      (line "CSX = DefineRectGrid(CSX, unit, mesh);")
      (line "Sim_Path = '~a';" simulation-name)
      (line "Sim_XML = 'model.xml';")
      (line "if exist(Sim_Path, 'dir'), rmdir(Sim_Path, 's'); end")
      (line "mkdir(Sim_Path);")
      (for ([body (in-list bodies)] [index (in-naturals 1)])
        (define property (format "body_~a" index))
        (line "copyfile('~a', [Sim_Path '/~a']);"
              (exported-body-filename body) (exported-body-filename body))
        (line "CSX = AddMetal(CSX, '~a');" property)
        (line "CSX = ImportSTL(CSX, '~a', ~a, '~a');"
              property (exported-body-priority body)
              (exported-body-filename body)))
      (define half-width (/ (lumped-port-width port) 2))
      (define half-depth (/ (lumped-port-depth port) 2))
      (define half-gap (/ (lumped-port-gap port) 2))
      (line "port_start = ~a;"
            (octave-vector (list (- half-width) (- half-depth) (- half-gap))))
      (line "port_stop = ~a;"
            (octave-vector (list half-width half-depth half-gap)))
      (line "[CSX, port] = AddLumpedPort(CSX, 1000, 1, ~a, port_start, port_stop, [0 0 1], true);"
            (number-string (lumped-port-impedance port)))
      (line "dlmwrite([Sim_Path '/mesh-x.csv'], mesh.x(:)', 'precision', '%.17g');")
      (line "dlmwrite([Sim_Path '/mesh-y.csv'], mesh.y(:)', 'precision', '%.17g');")
      (line "dlmwrite([Sim_Path '/mesh-z.csv'], mesh.z(:)', 'precision', '%.17g');")
      (line "fid = fopen([Sim_Path '/versions.txt'], 'w');")
      (line "fprintf(fid, 'octave=%s\\n', version);")
      (line "packages = pkg('list');")
      (line "for k = 1:numel(packages), fprintf(fid, '%s=%s\\n', packages{k}.name, packages{k}.version); end")
      (line "fclose(fid);")
      (line "WriteOpenEMS([Sim_Path '/' Sim_XML], FDTD, CSX);")
      (line "settings.LogFile = 'openems.log'; settings.Silent = 0;")
      (line "RunOpenEMS(Sim_Path, Sim_XML, '--dump-statistics', settings);")
      (line "freq = linspace(f_start, f_stop, ~a);" steps)
      (line "port = calcPort(port, Sim_Path, freq);")
      (line "s11 = port.uf.ref ./ port.uf.inc;")
      (line "zin = port.uf.tot ./ port.if.tot;")
      (line "s11_db = 20 * log10(abs(s11));")
      (line "results = [freq(:), real(s11(:)), imag(s11(:)), real(zin(:)), imag(zin(:)), s11_db(:)];")
      (line "dlmwrite([Sim_Path '/port-results.csv'], results, 'precision', '%.17g');")))
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

;; Keep the solver's detailed result available while presenting the plotting
;; layer with a backend-independent one-port network sweep.
(define (openems-sweep->network-sweep result)
  (unless (openems-sweep-result? result)
    (raise-argument-error
     'openems-sweep->network-sweep "openems-sweep-result?" result))
  (define name (format "~a" (openems-sweep-result-port-name result)))
  (define reference (openems-sweep-result-reference-impedance result))
  (define (convert sample)
    (define gamma (openems-port-sample-reflection-coefficient sample))
    (network-sample
     name
     (openems-port-sample-frequency-mhz sample)
     gamma
     (openems-port-sample-impedance sample)
     (openems-port-sample-s11-db sample)
     (reflection-magnitude->vswr (magnitude gamma))))
  (network-sweep
   'openems (openems-sweep-result-run result) reference
   (map convert (openems-sweep-result-samples result))))

(define (run-command executable arguments directory stdout-path stderr-path timeout)
  (define started (current-inexact-milliseconds))
  (define environment
    (environment-variables-copy (current-environment-variables)))
  (environment-variables-set! environment #"LC_ALL" #"C")
  (define-values (process timed-out?)
    (parameterize ([current-environment-variables environment]
                   [current-directory directory])
      (call-with-output-file stdout-path
        #:exists 'truncate/replace
        (lambda (stdout)
          (call-with-output-file stderr-path
            #:exists 'truncate/replace
            (lambda (stderr)
              (define-values (process _stdout stdin _stderr)
                (apply subprocess stdout #f stderr executable arguments))
              (close-output-port stdin)
              (define completed
                (with-handlers
                    ([exn:break?
                      (lambda (failure)
                        (subprocess-kill process #t)
                        (sync process)
                        (raise failure))])
                  (if timeout
                      (sync/timeout timeout process)
                      (sync process))))
              (unless completed
                (subprocess-kill process #t)
                (sync process))
              (values process (and timeout (not completed)))))))))
  (values (subprocess-status process)
          timed-out?
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
                       #:octave [requested-octave #f]
                       #:keep-artifacts? [keep? #t]
                       #:timeout [timeout #f])
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
  (unless (or (not timeout) (and (finite-real? timeout) (> timeout 0)))
    (raise-argument-error 'openems-sweep "(or/c #f positive-real?)" timeout))
  (validate-model!)
  (validate-solid-scene!)
  (when (pair? (model-edges))
    (raise-user-error
     'openems-sweep
     "wire-to-capsule conversion is not implemented in this milestone; use explicit bodies"))
  (when (pair? (model-sheets))
    (raise-user-error
     'openems-sweep
     "conducting-sheet export is not implemented in this milestone"))
  (when (null? (model-bodies))
    (raise-user-error 'openems-sweep "the physical scene has no volume bodies"))
  (unless (= (length (model-ports)) 1)
    (raise-user-error
     'openems-sweep
     "the first OpenEMS milestone requires exactly one explicit lumped port"))
  (define port (first (model-ports)))
  (define octave (resolve-octave requested-octave))
  (define directory
    (make-temporary-file "antenna-turtle-openems~a" 'directory))
  (define simulation-directory (build-path directory "simulation"))
  (define driver-path (build-path directory "run-openems.m"))
  (define manifest-path (build-path directory "simulation-manifest.rktd"))
  (define artifacts
    (openems-artifacts directory driver-path simulation-directory
                       manifest-path #t #t))
  (define stdout-path (build-path directory "octave.stdout"))
  (define stderr-path (build-path directory "octave.stderr"))
  (define transform (port-user->solver-transform port))
  (define inverse-transform (inverse-rigid-transform transform))
  (define bodies (transform-and-export-bodies directory transform))
  (define-values (minimum maximum) (scene-bounds bodies))
  (define wavelength-min (/ speed-of-light (* stop-mhz 1e6)))
  (define padding (* wavelength-min padding-wavelengths))
  (define domain-min (map (lambda (value) (- value padding)) minimum))
  (define domain-max (map (lambda (value) (+ value padding)) maximum))
  (define half-gap (/ (lumped-port-gap port) 2))
  (define half-width (/ (lumped-port-width port) 2))
  (define half-depth (/ (lumped-port-depth port) 2))
  (define critical-x
    (critical-axis-values bodies 0 (first domain-min) (first domain-max)
                          (- half-width) half-width))
  (define critical-y
    (critical-axis-values bodies 1 (second domain-min) (second domain-max)
                          (- half-depth) half-depth))
  (define critical-z
    (critical-axis-values bodies 2 (third domain-min) (third domain-max)
                          (- half-gap) half-gap))
  (define max-resolution (/ wavelength-min cells-per-wavelength))
  (write-octave-driver directory bodies port start-mhz stop-mhz steps
                       critical-x critical-y critical-z max-resolution
                       mesh-grading maximum-timesteps end-criteria)
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
     'geometry (map geometry-manifest bodies)
     'port (hash 'name (format "~a" (lumped-port-name port))
                 'impedance_ohms (exact->inexact (lumped-port-impedance port))
                 'gap_m (exact->inexact (lumped-port-gap port))
                 'width_m (exact->inexact (lumped-port-width port))
                 'depth_m (exact->inexact (lumped-port-depth port))
                 'priority 1000)
     'mesh (hash 'policy "fixed-critical-coordinate-poc"
                 'critical_x (map exact->inexact critical-x)
                 'critical_y (map exact->inexact critical-y)
                 'critical_z (map exact->inexact critical-z)
                 'maximum_resolution_m max-resolution
                 'cells_per_wavelength (exact->inexact cells-per-wavelength)
                 'padding_wavelengths (exact->inexact padding-wavelengths)
                 'grading (exact->inexact mesh-grading)
                 'boundary_conditions (make-list 6 "PML_8"))
     'solver (hash 'octave_executable (path->string octave)
                   'driver "run-openems.m"
                   'excitation_center_hz 0.0
                   'excitation_bandwidth_hz (* (exact->inexact stop-mhz) 1e6)
                   'max_timesteps maximum-timesteps
                   'end_criteria end-criteria)))
  (write-manifest directory initial-manifest)
  (define-values (status timed-out? elapsed)
    (run-command octave '("--quiet" "--no-gui" "run-openems.m")
                 directory stdout-path stderr-path timeout))
  (define stdout (file->string stdout-path))
  (define stderr (file->string stderr-path))
  (define mesh-available?
    (and (file-exists? (build-path simulation-directory "mesh-x.csv"))
         (file-exists? (build-path simulation-directory "mesh-y.csv"))
         (file-exists? (build-path simulation-directory "mesh-z.csv"))))
  (define solver-statistics
    (read-openems-statistics
     (build-path simulation-directory "openEMS_stats.txt")
     maximum-timesteps))
  (define versions
    (read-version-file (build-path simulation-directory "versions.txt")))
  (define final-manifest
    (hash-set*
     initial-manifest
     'status (cond [timed-out? "timed-out"] [(zero? status) "complete"] [else "failed"])
     'elapsed_ms elapsed
     'exit_code status
     'software_versions versions
     'solver_statistics solver-statistics
     'mesh
     (if mesh-available?
         (let* ([x (read-number-list (build-path simulation-directory "mesh-x.csv"))]
                [y (read-number-list (build-path simulation-directory "mesh-y.csv"))]
                [z (read-number-list (build-path simulation-directory "mesh-z.csv"))])
           (hash-set*
            (hash-ref initial-manifest 'mesh)
            'x x 'y y 'z z
            'cell_count (* (sub1 (length x)) (sub1 (length y)) (sub1 (length z)))))
         (hash-ref initial-manifest 'mesh))
     'artifacts (artifact-sizes directory)))
  (write-manifest directory final-manifest)
  (define run
    (openems-run-info octave elapsed status stdout stderr artifacts final-manifest))
  (when timed-out?
    (raise
     (exn:fail:openems
      (format "OpenEMS timed out after ~a seconds; artifacts retained in ~a"
              timeout directory)
      (current-continuation-marks)
      run)))
  (unless (zero? status)
    (raise
     (exn:fail:openems
      (format "OpenEMS/Octave exited with status ~a; artifacts retained in ~a"
              status directory)
      (current-continuation-marks)
      run)))
  (define result-path (build-path simulation-directory "port-results.csv"))
  (unless (file-exists? result-path)
    (raise
     (exn:fail:openems
      (format "OpenEMS did not create port results; artifacts retained in ~a"
              directory)
      (current-continuation-marks)
      run)))
  (define result
    (openems-sweep-result
     run (lumped-port-name port) (lumped-port-impedance port)
     (parse-openems-port-results result-path)))
  (unless keep? (openems-close! result))
  result)

(define (openems-close! value)
  (define artifacts
    (cond
      [(openems-sweep-result? value)
       (openems-run-info-artifacts (openems-sweep-result-run value))]
      [(openems-run-info? value) (openems-run-info-artifacts value)]
      [(openems-artifacts? value) value]
      [else
       (raise-argument-error
        'openems-close!
        "(or/c openems-sweep-result? openems-run-info? openems-artifacts?)"
        value)]))
  (when (openems-artifacts-available? artifacts)
    (define directory (openems-artifacts-directory artifacts))
    (when (directory-exists? directory) (delete-directory/files directory))
    (set-openems-artifacts-available?! artifacts #f))
  (void))
