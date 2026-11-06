# Données des graphiques du rapport

- `procedures.csv`, `contexte.csv` : produits par `php bin/bench-stats.php` (branche `dev`),
  copiés depuis `var/bench/`. Relancer le script puis recopier les fichiers pour mettre
  à jour les graphiques et tableaux de la partie « Analyse des performances ».
- `optimisations.csv`, `flotte_periodes.csv`, `buffer_pool.csv`, `page_http.csv` :
  mesures ponctuelles relevées pendant l'optimisation du 06/11/2026 (base complète,
  période de 30 jours sauf mention contraire, cache applicatif désactivé).
  « OD avant = 60 » est une borne inférieure : la requête a été interrompue après 60 s.
