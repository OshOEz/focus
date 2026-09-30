# Tests manuels

Lancer en release (le debug est ~15× plus lent) depuis un terminal qui a l'accès Caméra.

## focus-gaze probe
`swift run -c release focus-gaze probe 10`
- [ ] Face à la caméra : une ligne ~toutes les 0,5 s, `conf` ≥ 0,5, `yaw`/`pitch` proches de 0°.
- [ ] Tourner la tête à gauche puis à droite : `yaw` change de signe, amplitude ≥ 15°.
- [ ] `lag` reste entre 0 et 150 ms pendant 10 s (négatif = mauvaise horloge).
- [ ] Fin : ~15 échantillons/s (jamais plus de 15).
- [ ] Main devant la caméra : des lignes `no face` (jamais de NaN affiché).

## focus-gaze screens (≥ 2 écrans)
`swift run -c release focus-gaze screens`
- [ ] Suivre les consignes pour chaque écran ; chaque écran affiche `ok`.
- [ ] Regarder chaque écran à tour de rôle : `→ écran N` correct à chaque fois, sans clignotement au milieu.
- [ ] Regarder son téléphone ou le plafond : `→ hors écran`.

## Caméra (reprise)
- [ ] `focus-gaze cameras` liste la caméra intégrée et toute caméra USB branchée.
- [ ] Pendant `probe 60`, débrancher la caméra USB choisie : pas de crash ; la rebrancher : les échantillons reprennent.
- [ ] Sur un Mac sans caméra intégrée (une seule caméra USB) : débrancher puis rebrancher cette même caméra reprend aussi (pas seulement le cas où elle bascule vers une intégrée).
- [ ] Pendant `probe 60`, ouvrir FaceTime (caméra prise) puis le fermer : les échantillons reprennent seuls.

## Erreurs
- [ ] Caméra refusée (Réglages > Confidentialité > Caméra, décocher le terminal) : message clair, code de sortie 1.
- [ ] Caméra occupée par une visio : message clair ou attente, pas de crash.
