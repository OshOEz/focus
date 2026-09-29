# Spike AX — panneaux (2026-09-29)

Outil : `swift run ax-dump [bundle.id ...]` (Accessibility accordée à Xirp, qui héberge le terminal).
Apps testées : celles ouvertes sur la machine de l'utilisateur. Les autres apps de `PaneApps` restent à tester.

| App | Panneaux visibles en AX ? | Élément panneau | focusable=true ? | Stratégie |
|---|---|---|---|---|
| Xirp (`com.spotify.xirp`, Electron) — 1 session | oui | `AXGroup` sous `AXWebArea`, 1258×747 | oui | AX focus |
| Xirp — mode grille, 2 sessions | oui, 2 frères côte à côte | `AXGroup` 605×223 chacun, sous `AXWebArea` | oui | AX focus |
| Xcode (fenêtre d'accueil seulement) | non testé en split | `AXScrollArea` > `AXOutline` focusable | — | à refaire avec un éditeur splitté |

## Observations
- Electron : l'arbre sous `AXWindow` est vide au premier appel après `AXManualAccessibility = true` ;
  il est complet au second (~secondes plus tard). `ax-dump` n'attend que 0,5 s → lancer deux fois.
- Dans Xirp, beaucoup de `AXGroup` englobants sont aussi `focusable=true` (la chaîne racine
  1512×859). Le panneau utile est le **focusable le plus profond** ; les englobants doivent être ignorés.

## Conclusion
- Règle générique retenue pour `AXPaneProvider` (plan 4) : sous `AXWebArea` (ou la fenêtre pour
  les apps natives), collecter les éléments `focusable=true` d'au moins 200×150 pt qui n'ont
  **aucun descendant focusable de même taille minimale** ; ce sont les panneaux.
- Ajouter `com.spotify.xirp` à `PaneApps.bundleIDs` (plan 4).
- Electron : réessayer la lecture de l'arbre après ~1 s si elle est vide.
- Apps qui exigent le clic synthétique : aucune constatée à ce stade (Xirp n'en a pas besoin).
