#lang antenna-turtle

(define (build with-boom?)
  (model title "Three-element Yagi geometry"
         frequency 150.0
         max-length (/ wavelength 200)
         wire-diameter (* 6 millimeter))

  (define boom-pitch (/ wavelength 200))
  (define boom-thick (* 2 boom-pitch))

  ;; Keep each element's role, boom position, and total length together. LOOP
  ;; destructuring makes those columns explicit at the point of use.
  (define element-layout
    (list (list 'reflector  0                   (* 0.52 wavelength))
          (list 'driven    (* 1/5 wavelength)   (* 0.48 wavelength))
          (list 'director  (* 2/5 wavelength)   (* 0.45 wavelength))))

  (define (element role boom-position length)
    (from-here
      (move forward boom-position)
      (when (eq? role 'driven) (feed center))
      (with-wire
        ;; Center every transverse element on its boom attachment point.
        (spread right length))))

  (loop for (role boom-position length) in element-layout
        do (element role boom-position length))

  ;(export-mmana "mmana/yagi.maa")

  (define wood
    (dielectric name wood er 80.0 loss-tangent 0.01))
  (move forward {1 * wavelength / 5} down inch)
  (turn left 90)
  (cuboid name boom
          size (list {wavelength / 2} boom-thick boom-thick)
          material wood
          anchor center))

(build #t)
(define reference-pattern
  (nec2c-radiation-grid
   #:frequency 150 #:theta-step 2 #:phi-step 2
   #:dielectrics? #f))

(show-model)

(nec2c-dielectric-mesh
 mode auto
 max-cells 2000)

(define sweep
  (nec2c-vswr-sweep 150 180 #:steps 5))
(impedance-at sweep 150 #:interpolate? #t)

(when #t
  (define loaded-pattern
    (nec2c-radiation-grid
     #:frequency 150 #:theta-step 2 #:phi-step 2
     #:dielectrics? #t
     #:dielectric-solver 'fft
     #:solver-iterations 10000))

  (show-radiation-comparison
   (list (radiation-case "reference: no boom" reference-pattern)
         (radiation-case "loaded: wood boom" loaded-pattern))
   #:aspect-ratio 16/9
   #:palette 'electric
   ;#:difference? #t
   #:scale 'arrl)
  )
