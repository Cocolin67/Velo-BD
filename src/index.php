<?php
require __DIR__ . '/includes/db.php';
$titre = 'Données';
require __DIR__ . '/includes/header.php';
?>
  <h1>Connexion réussie à <?= e($base) ?></h1>
  <p><a class="btn" href="fonctionnalites.php">Voir les fonctionnalités →</a></p>
<?php
tableau($pdo, 'Stations',
    "SELECT id_station, nom, adresse, etat_station FROM station");

tableau($pdo, 'Vélos et leur borne',
    "SELECT v.id_velo, v.type_velo, v.etat_velo, v.niveau_batterie, s.nom AS station, b.num_borne
       FROM velo v
       LEFT JOIN borne b   ON b.id_borne = v.id_borne
       LEFT JOIN station s ON s.id_station = b.id_station");

tableau($pdo, 'Locations (durée et coût calculés par trigger)',
    "SELECT l.id_location, u.prenom, u.nom, l.id_velo, l.date_heure_emprunt,
            l.date_heure_restitution, l.duree_min, l.cout
       FROM location l
       JOIN abonnement a  ON a.id_abonnement = l.id_abonnement
       JOIN utilisateur u ON u.id_utilisateur = a.id_utilisateur
      ORDER BY l.date_heure_emprunt");

tableau($pdo, 'Historique des états',
    "SELECT id_hist_etat, id_velo, date_heure, etat_velo FROM historique_etat ORDER BY id_hist_etat");

tableau($pdo, 'Signalements',
    "SELECT id_signalement, date_heure, description, statut, id_velo, id_station FROM signalement");

require __DIR__ . '/includes/footer.php';
