#lang antenna-turtle

(model
 title "Folded Dipole"
 frequency 146
 max-length centimeter)

(with-scale 0.938
  (with-wire
    (move right half-wave feed 'center)
    (move up (* 2 centimeters))
    (move left half-wave)
    (move down (* 2 centimeters))))

(export-mmana "mmana/folded-dipole.maa")
