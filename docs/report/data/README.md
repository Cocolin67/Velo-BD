# Données des graphiques du rapport

- `procedures.csv`, `echelle.csv`, `contexte.csv` : produits par `php bin/bench-stats.php`
  (branche `dev`), copiés depuis `var/bench/`. Relancer le script avec les procédures de
  `dev` chargées, puis recopier les trois fichiers pour mettre à jour les graphiques et
  tableaux de la partie « Analyse des performances ».
  `contexte.csv` est lu ligne par ligne (tableau des volumes) : garder l'ordre des clés
  écrit par le script.
- `optimisations.csv`, `flotte_periodes.csv`, `buffer_pool.csv`, `page_http.csv` :
  mesures ponctuelles relevées pendant l'optimisation (base complète, période de 30 jours
  sauf mention contraire, cache applicatif désactivé ; `page_http.csv` : médiane de
  3 requêtes HTTP, le 07/11/2026).
  « OD avant = 60 » est une borne inférieure : la requête a été interrompue après 60 s.
