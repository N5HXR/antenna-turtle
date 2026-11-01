#lang racket/base

(require racket/list
         racket/math
         "core.rkt")

(provide
 (struct-out wire-port-declaration)
 (struct-out wire-transmission-line)
 (struct-out wire-y-network)
 (struct-out wire-coax-declaration)
 add-wire-port-declaration
 add-spread-wire-port-declaration
 add-transmission-line-declaration
 add-y-network-declaration
 add-ideal-transformer-declaration
 call-with-coax-declaration
 resolve-wire-port
 model-wire-ports
 model-wire-transmission-lines
 model-wire-y-networks
 model-wire-coaxes
 wire-port-negative-point
 wire-port-positive-point
 wire-port-edge?
 validate-wire-network-declarations!
 clear-wire-network-declarations)

;; A port is represented by an actual, dedicated one-segment wire edge. This
;; lets it participate naturally in conductor connectivity, feed discovery,
;; result naming, and model visualization. The exporter nevertheless forces
;; the edge to exactly one NEC segment so the TL terminal is unambiguous.
(struct wire-port-declaration
  (name edge direction gap diameter anchor generated?)
  #:transparent)

;; physical-length is the routed cable length. NEC's TL length is the
;; corresponding free-space electrical length: physical-length / VF.
(struct wire-transmission-line
  (name input-port output-port impedance physical-length velocity-factor)
  #:transparent)

;; A reciprocal, non-radiating two-port described by its short-circuit
;; admittance matrix.  NEC's NT card takes Y11, Y12, and Y22; reciprocity
;; supplies Y21 = Y12.
(struct wire-y-network (name input-port output-port y11 y12 y22)
  #:transparent)

(struct wire-coax-declaration
  (name input-port output-port line shield-edges diameter color)
  #:transparent)

(define current-wire-ports (make-parameter '()))
(define current-wire-port-index (make-parameter (make-hash)))
(define current-wire-transmission-lines (make-parameter '()))
(define current-wire-y-networks (make-parameter '()))
(define current-wire-coaxes (make-parameter '()))

(define (model-wire-ports) (current-wire-ports))
(define (model-wire-transmission-lines) (current-wire-transmission-lines))
(define (model-wire-y-networks) (current-wire-y-networks))
(define (model-wire-coaxes) (current-wire-coaxes))

(define (y-network-port? port)
  (for/or ([network (in-list (model-wire-y-networks))])
    (or (eq? port (wire-y-network-input-port network))
        (eq? port (wire-y-network-output-port network)))))

(define (transmission-line-output-port? port)
  (for/or ([line (in-list (model-wire-transmission-lines))])
    (eq? port (wire-transmission-line-output-port line))))

(define (transmission-line-input-port? port)
  (for/or ([line (in-list (model-wire-transmission-lines))])
    (eq? port (wire-transmission-line-input-port line))))

(define (downstream-network-port? port)
  ;; A coax output normally joins an antenna conductor. In a cascade it joins
  ;; the input terminal of the next TL instead, which supplies both terminals
  ;; electrically without requiring a radiating wire at that junction.
  (or (y-network-port? port)
      (transmission-line-input-port? port)))

(define (clear-wire-network-declarations)
  (current-wire-ports '())
  (current-wire-port-index (make-hash))
  (current-wire-transmission-lines '())
  (current-wire-y-networks '())
  (current-wire-coaxes '())
  (void))

(register-model-reset-hook! clear-wire-network-declarations)
(register-wire-clear-hook! clear-wire-network-declarations)

(define local-directions
  (hash 'forward '(1 0 0) 'forwards '(1 0 0)
        'back '(-1 0 0) 'backward '(-1 0 0) 'backwards '(-1 0 0)
        'left '(0 1 0) 'right '(0 -1 0)
        'up '(0 0 1) 'down '(0 0 -1)))

(define (finite-real? value)
  (and (real? value) (rational? value)))

(define (finite-complex? value)
  (and (number? value)
       (rational? (real-part value))
       (rational? (imag-part value))))

(define (positive-real who value description)
  (unless (and (finite-real? value) (positive? value))
    (raise-arguments-error
     who (format "~a must be a positive finite real" description)
     description value))
  value)

(define (transform-direction who direction)
  (define coordinates (hash-ref local-directions direction #f))
  (unless coordinates
    (raise-argument-error who "turtle direction" direction))
  (define transform (current-turtle-affine-transform who))
  (apply point3
         (for/list ([row (in-list transform)])
           (for/sum ([coefficient (in-list (take row 3))]
                     [coordinate (in-list coordinates)])
             (* coefficient coordinate)))))

(define (point+scaled point direction amount)
  (point3 (+ (point3-x point) (* amount (point3-x direction)))
          (+ (point3-y point) (* amount (point3-y direction)))
          (+ (point3-z point) (* amount (point3-z direction)))))

(define (wire-port-negative-point port)
  (vertex-point (wire-edge-start (wire-port-declaration-edge port))))

(define (wire-port-positive-point port)
  (vertex-point (wire-edge-end (wire-port-declaration-edge port))))

(define (registered-port? port)
  (and (wire-port-declaration? port)
       (memq port (model-wire-ports))))

(define (coax-input-port-by-name name)
  (for/first ([coax (in-list (model-wire-coaxes))]
              #:when (equal? name (wire-coax-declaration-name coax)))
    (wire-coax-declaration-input-port coax)))

(define (resolve-wire-port reference [who 'wire-port])
  (cond
    [(registered-port? reference) reference]
    [(or (symbol? reference) (string? reference))
     ;; A coax name is shorthand for that coax's generated input port. This
     ;; makes serial declarations read naturally: `output quarter-stub`.
     (or (hash-ref (current-wire-port-index) reference #f)
         (coax-input-port-by-name reference)
         (raise-arguments-error who "unknown wire port or coax terminal"
                                "port" reference))]
    [else
     (raise-argument-error who
                           "(or/c registered-wire-port? symbol? string?)"
                           reference)]))

(define (point=? a b)
  (and (= (point3-x a) (point3-x b))
       (= (point3-y a) (point3-y b))
       (= (point3-z a) (point3-z b))))

(define (point-distance a b)
  (sqrt (+ (sqr (- (point3-x a) (point3-x b)))
           (sqr (- (point3-y a) (point3-y b)))
           (sqr (- (point3-z a) (point3-z b))))))

(define (wire-port-anchor-point port)
  (define negative (wire-port-negative-point port))
  (define positive (wire-port-positive-point port))
  (case (wire-port-declaration-anchor port)
    [(start) negative]
    [(end) positive]
    [else
     (point3 (/ (+ (point3-x negative) (point3-x positive)) 2)
             (/ (+ (point3-y negative) (point3-y positive)) 2)
             (/ (+ (point3-z negative) (point3-z positive)) 2))]))

(define (resolve-coax-output-port requested-port)
  (cond
    [requested-port
     (resolve-wire-port requested-port 'coax)]
    [else
     ;; A bare coax form connects to the port placed at the turtle's current
     ;; position.  This makes `(coax type rg58 ...)` pleasant for the common
     ;; one-feedpoint case without guessing when several ports are nearby.
     (define matches
       (filter (lambda (port)
                 (point=? (wire-port-anchor-point port) (current-position)))
               (model-wire-ports)))
     (case (length matches)
       [(1) (car matches)]
       [(0) (raise-arguments-error
             'coax "no output port was supplied or found at the current turtle position"
             "current position" (current-position))]
       [else (raise-arguments-error
              'coax "more than one port is at the current turtle position; specify output"
              "current position" (current-position)
              "ports" (map wire-port-declaration-name matches))])]))

(define (wire-port-edge? edge)
  (for/or ([port (in-list (model-wire-ports))])
    (eq? edge (wire-port-declaration-edge port))))

(define (edge-touches-vertex? edge model-vertex)
  (or (eq? (wire-edge-start edge) model-vertex)
      (eq? (wire-edge-end edge) model-vertex)))

(define (other-incident-edges port model-vertex)
  (filter
   (lambda (edge)
     (and (not (eq? edge (wire-port-declaration-edge port)))
          (edge-touches-vertex? edge model-vertex)))
   (model-edges)))

(define (validate-wire-network-declarations! [who 'antenna-turtle])
  (for ([coax (in-list (model-wire-coaxes))])
    (define output (wire-coax-declaration-output-port coax))
    (define input (wire-coax-declaration-input-port coax))
    (define shield (wire-coax-declaration-shield-edges coax))
    (define output-edge (wire-port-declaration-edge output))
    (define input-edge (wire-port-declaration-edge input))
    (define output-negative (wire-edge-start output-edge))
    (define output-positive (wire-edge-end output-edge))
    (define input-negative (wire-edge-start input-edge))
    (when (pair? shield)
      (define first-shield (car shield))
      (define last-shield (last shield))
      (unless (edge-touches-vertex? first-shield output-negative)
        (raise-arguments-error
         who "coax shield route is detached from the output negative terminal"
         "coax" (wire-coax-declaration-name coax)))
      (unless (edge-touches-vertex? last-shield input-negative)
        (raise-arguments-error
         who "coax shield route is detached from the input negative terminal"
         "coax" (wire-coax-declaration-name coax))))
    ;; A coax may terminate at an NT port or at the input of a downstream TL
    ;; instead of directly at an antenna wire. In that case the network
    ;; supplies the output circuit.
    (when (and (not (downstream-network-port? output))
               (null? (filter (lambda (edge) (not (memq edge shield)))
                              (other-incident-edges output output-negative))))
      (raise-arguments-error
       who "coax output negative terminal is not connected to an antenna conductor"
       "coax" (wire-coax-declaration-name coax)
       "port" (wire-port-declaration-name output)))
    (when (and (not (downstream-network-port? output))
               (null? (other-incident-edges output output-positive)))
      (raise-arguments-error
       who "coax output positive terminal is not connected to an antenna conductor"
       "coax" (wire-coax-declaration-name coax)
       "port" (wire-port-declaration-name output)))
    (when (wire-edge-feed? output-edge)
      (raise-arguments-error
       who "coax output port must not also contain an excitation"
       "coax" (wire-coax-declaration-name coax)
       "port" (wire-port-declaration-name output)))
    ;; An input is either the model excitation or the output of an upstream
    ;; line.  The latter permits coax sections to be cascaded at a generated
    ;; `<coax-name>-input` port.
    (unless (or (wire-edge-feed? input-edge)
                (transmission-line-output-port? input))
      (raise-arguments-error
       who "coax input port is missing an excitation or upstream transmission line"
       "coax" (wire-coax-declaration-name coax)
       "port" (wire-port-declaration-name input))))
  (void))

(define (fresh-name prefix declarations accessor)
  (let loop ([index (add1 (length declarations))])
    (define candidate (string->symbol (format "~a-~a" prefix index)))
    (if (for/or ([declaration (in-list declarations)])
          (equal? candidate (accessor declaration)))
        (loop (add1 index))
        candidate)))

(define (ensure-unique-name who name declarations accessor description)
  (when (for/or ([declaration (in-list declarations)])
          (equal? name (accessor declaration)))
    (raise-arguments-error who (format "~a names must be unique" description)
                           "name" name)))

(define (add-wire-port-declaration direction
                                   #:name [requested-name #f]
                                   #:gap gap
                                   #:diameter [diameter #f]
                                   #:anchor [anchor 'center]
                                   #:feed-name [feed-name #f]
                                   #:generated? [generated? #f])
  (define who 'wire-port)
  (when (current-wire-active?)
    (error who "wire must be off while placing a differential port"))
  (when (current-reflection-context)
    (error who "wire ports cannot yet be declared inside reflect"))
  (positive-real who gap "gap")
  (when diameter (positive-real who diameter "diameter"))
  (unless (memq anchor '(start center end))
    (raise-argument-error who "(or/c 'start 'center 'end)" anchor))
  (unless (boolean? generated?)
    (raise-argument-error who "boolean?" generated?))
  (unless (or (not feed-name)
              (and (string? feed-name) (not (string=? feed-name ""))))
    (raise-argument-error who "(or/c #f non-empty-string?)" feed-name))
  (define direction-vector (transform-direction who direction))
  (define effective-gap (* gap (current-geometry-scale)))
  (define origin (current-position))
  (define-values (negative positive)
    (case anchor
      [(start) (values origin (point+scaled origin direction-vector effective-gap))]
      [(end) (values (point+scaled origin direction-vector (- effective-gap)) origin)]
      [else
       (values (point+scaled origin direction-vector (- (/ effective-gap 2)))
               (point+scaled origin direction-vector (/ effective-gap 2)))]))
  (define ports (model-wire-ports))
  (define name
    (or requested-name
        (fresh-name "port" ports wire-port-declaration-name)))
  (ensure-unique-name who name ports wire-port-declaration-name "wire port")
  (define edge #f)
  (define effective-diameter #f)
  (call-from-here
   (lambda ()
     (when diameter (wire-diameter diameter))
     (set! effective-diameter (current-wire-diameter))
     (goto negative)
     (when feed-name
       (mark-feed (make-feed-spec 'center feed-name)))
     (define old-count (length (model-edges)))
     (call-with-wire (lambda () (goto positive)))
     (define new-edges (drop (model-edges) old-count))
     (unless (= (length new-edges) 1)
       (error who "port placement did not create exactly one wire edge"))
     (set! edge (car new-edges))))
  (define port
    (wire-port-declaration name edge direction-vector effective-gap
                           effective-diameter anchor generated?))
  (current-wire-ports (append ports (list port)))
  (hash-set! (current-wire-port-index) name port)
  port)

;; Insert a port while constructing one centered `spread` wire.  The caller's
;; turtle state is restored just as spread-local restores it, but the original
;; conductor is emitted as zero, one, or two edges around the port instead of
;; one edge that overlaps it.
(define (add-spread-wire-port-declaration direction distance
                                           #:name requested-name
                                           #:gap gap
                                           #:diameter [diameter #f]
                                           #:anchor [anchor 'center]
                                           #:feed-name [feed-name #f])
  (define who 'spread)
  (unless (current-wire-active?)
    (error who "a port clause requires an enclosing with-wire"))
  (positive-real who distance "spread distance")
  (positive-real who gap "port gap")
  (unless (memq anchor '(start center end))
    (raise-argument-error who "(or/c 'start 'center 'end)" anchor))
  (define direction-vector (transform-direction who direction))
  (define scale (current-geometry-scale))
  (define effective-distance (* distance scale))
  (define effective-gap (* gap scale))
  (when (> effective-gap effective-distance)
    (raise-arguments-error
     who "port gap may not exceed spread distance"
     "gap" gap
     "spread distance" distance))
  (define center (current-position))
  (define start (point+scaled center direction-vector (- (/ effective-distance 2))))
  (define end (point+scaled center direction-vector (/ effective-distance 2)))
  (define anchor-point
    (case anchor
      [(start) start]
      [(end) end]
      [else center]))
  (define result #f)
  (call-from-here
   (lambda ()
     ;; The ordinary port constructor owns registration, port geometry, and
     ;; feed marking. Temporarily lift the pen so it can do that work.
     (wire-off)
     (goto anchor-point)
     (set! result
           (add-wire-port-declaration
            direction
            #:name requested-name
            #:gap gap
            #:diameter diameter
            #:anchor anchor
            #:feed-name feed-name))
     (define negative (wire-port-negative-point result))
     (define positive (wire-port-positive-point result))
     (unless (point=? start negative)
       (goto start)
       (wire-on)
       (goto negative)
       (wire-off))
     (unless (point=? positive end)
       (goto positive)
       (wire-on)
       (goto end)
       (wire-off))))
  result)

(define (add-transmission-line-declaration
         #:name [requested-name #f]
         #:input input-reference
         #:output output-reference
         #:impedance [impedance 50]
         #:physical-length physical-length
         #:velocity-factor velocity-factor)
  (define who 'transmission-line)
  (define input-port (resolve-wire-port input-reference who))
  (define output-port (resolve-wire-port output-reference who))
  (when (eq? input-port output-port)
    (raise-arguments-error who "input and output must be different ports"))
  (positive-real who impedance "impedance")
  (positive-real who physical-length "physical length")
  (positive-real who velocity-factor "velocity factor")
  (when (> velocity-factor 1)
    (raise-arguments-error who "velocity factor may not exceed 1"
                           "velocity factor" velocity-factor))
  (define lines (model-wire-transmission-lines))
  (define name
    (or requested-name
        (fresh-name "line" lines wire-transmission-line-name)))
  (ensure-unique-name who name lines wire-transmission-line-name
                      "transmission line")
  (for ([line (in-list lines)])
    (when (eq? input-port (wire-transmission-line-input-port line))
      (raise-arguments-error
       who "only one transmission line may originate at a wire port"
       "port" (wire-port-declaration-name input-port)))
    (when (eq? output-port (wire-transmission-line-output-port line))
      (raise-arguments-error
       who "only one transmission line may terminate at a wire port"
       "port" (wire-port-declaration-name output-port))))
  (define line
    (wire-transmission-line name input-port output-port impedance
                            physical-length velocity-factor))
  (current-wire-transmission-lines (append lines (list line)))
  line)

(define (add-y-network-declaration
         #:name [requested-name #f]
         #:input input-reference
         #:output output-reference
         #:y11 y11
         #:y12 y12
         #:y22 y22)
  (define who 'two-port-y)
  (define input-port (resolve-wire-port input-reference who))
  (define output-port (resolve-wire-port output-reference who))
  (when (eq? input-port output-port)
    (raise-arguments-error who "input and output must be different ports"))
  (for ([value (in-list (list y11 y12 y22))]
        [label (in-list '(y11 y12 y22))])
    (unless (finite-complex? value)
      (raise-arguments-error
       who "finite complex admittance in siemens" label value)))
  (define networks (model-wire-y-networks))
  (define name
    (or requested-name
        (fresh-name "network" networks wire-y-network-name)))
  (ensure-unique-name who name networks wire-y-network-name "two-port Y network")
  (define network
    (wire-y-network name input-port output-port y11 y12 y22))
  (current-wire-y-networks (append networks (list network)))
  network)

;; An exact ideal transformer has a singular Y matrix and cannot be written on
;; a finite NEC NT card. A small primary-referred series resistance makes the
;; constraint finite. For n = Voutput/Vinput, the resulting matrix is
;;
;;   [ 1/r       -1/(n r)   ]
;;   [ -1/(n r)   1/(n^2 r) ]
;;
;; and a load Z at the output is seen as Z/n^2 + r at the input.
(define (add-ideal-transformer-declaration
         #:name [requested-name #f]
         #:input input-port
         #:output output-port
         #:turns-ratio turns-ratio
         #:series-resistance [series-resistance 0.001])
  (define who 'ideal-transformer)
  (positive-real who turns-ratio "turns ratio")
  (positive-real who series-resistance "series resistance")
  (define n turns-ratio)
  (define r series-resistance)
  (add-y-network-declaration
   #:name requested-name
   #:input input-port
   #:output output-port
   #:y11 (/ 1 r)
   #:y12 (- (/ 1 (* n r)))
   #:y22 (/ 1 (* n n r))))

(define (call-with-coax-declaration thunk
                                    #:name [requested-name #f]
                                    #:output [requested-output-port #f]
                                    #:impedance [impedance 50]
                                    #:velocity-factor velocity-factor
                                    #:diameter diameter
                                    #:color [color #f]
                                    #:input-gap input-gap
                                    #:input-direction [input-direction 'forward]
                                    #:feed? [feed? #t]
                                    #:shield? [shield? #t])
  (define who 'coax)
  (unless (and (procedure? thunk) (procedure-arity-includes? thunk 0))
    (raise-argument-error who "(procedure-arity-includes/c 0)" thunk))
  (define output-port (resolve-coax-output-port requested-output-port))
  (when (current-wire-active?)
    (error who "wire must be off while entering coax"))
  (when (current-reflection-context)
    (error who "coax cannot yet be declared inside reflect"))
  (positive-real who diameter "diameter")
  (positive-real who input-gap "input gap")
  (positive-real who impedance "impedance")
  (positive-real who velocity-factor "velocity factor")
  (unless (or (not color) (string? color) (symbol? color))
    (raise-argument-error who "(or/c #f string? symbol?)" color))
  (unless (boolean? feed?)
    (raise-argument-error who "boolean?" feed?))
  (unless (boolean? shield?)
    (raise-argument-error who "boolean?" shield?))
  (when (> velocity-factor 1)
    (raise-arguments-error who "velocity factor may not exceed 1"
                           "velocity factor" velocity-factor))
  (define coaxes (model-wire-coaxes))
  (define name
    (or requested-name
        (fresh-name "coax" coaxes wire-coax-declaration-name)))
  (ensure-unique-name who name coaxes wire-coax-declaration-name "coax")
  (define result #f)
  (call-from-here
   (lambda ()
     (goto (wire-port-negative-point output-port))
     (define old-count (length (model-edges)))
     (define invisible-length 0)
     (if shield?
         (begin
           (wire-diameter diameter)
           (call-with-wire thunk))
         (let ([previous-handler (current-turtle-event-handler)])
           (parameterize
               ([current-turtle-event-handler
                 (lambda (event . arguments)
                   (when previous-handler
                     (apply previous-handler event arguments))
                   (when (eq? event 'move)
                     (set! invisible-length
                           (+ invisible-length
                              (point-distance (first arguments)
                                              (second arguments))))))])
             ;; Run the same route with the pen up: it supplies TL physical
             ;; length but intentionally creates no shield-exterior wire.
             (thunk))))
     (define shield-edges (drop (model-edges) old-count))
     (when (and shield? (null? shield-edges))
       (error who "coax body must draw a nonzero shield route"))
     (define physical-length
       (if shield?
           (for/sum ([edge (in-list shield-edges)]) (edge-length edge))
           invisible-length))
     (when (zero? physical-length)
       (error who "coax body must trace a nonzero route"))
     (define input-name (string->symbol (format "~a-input" name)))
     (define input-port
       (add-wire-port-declaration
        input-direction
        #:name input-name
        #:gap input-gap
        #:anchor 'start
        #:feed-name (and feed? (format "~a" name))
        #:generated? #t))
     (define line
       (add-transmission-line-declaration
        #:name name #:input input-port #:output output-port
        #:impedance impedance #:physical-length physical-length
        #:velocity-factor velocity-factor))
     (set! result
           (wire-coax-declaration name input-port output-port line
                                  shield-edges
                                   diameter
                                  color))))
  (current-wire-coaxes (append coaxes (list result)))
  result)
