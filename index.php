<?php
// Page de test : affiche quelques données de la base velo_libre_service.
// Adaptez les 4 lignes ci-dessous à votre configuration (XAMPP/WAMP : root sans mot de passe).
$hote = 'localhost';
$base = 'velo_libre_service';
$user = 'root';
$mdp  = '';

try {
    $pdo = new PDO("mysql:host=$hote;dbname=$base;charset=utf8mb4", $user, $mdp, [
        PDO::ATTR_ERRMODE            => PDO::ERRMODE_EXCEPTION,
        PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
    ]);
} catch (PDOException $e) {
    die('<p style="color:red">Connexion impossible : ' . htmlspecialchars($e->getMessage()) . '</p>');
}

function tableau(PDO $pdo, string $titre, string $sql): void
{
    $lignes = $pdo->query($sql)->fetchAll();
    echo '<h2>' . htmlspecialchars($titre) . ' (' . count($lignes) . ')</h2>';
    if (!$lignes) {
        echo '<p><em>Aucune donnée.</em></p>';
        return;
    }
    echo '<table><tr>';
    foreach (array_keys($lignes[0]) as $col) {
        echo '<th>' . htmlspecialchars($col) . '</th>';
    }
    echo '</tr>';
    foreach ($lignes as $l) {
        echo '<tr>';
        foreach ($l as $v) {
            echo '<td>' . ($v === null ? '<em>NULL</em>' : htmlspecialchars((string) $v)) . '</td>';
        }
        echo '</tr>';
    }
    echo '</table>';
}
?>
<!DOCTYPE html>
<html lang="fr">
<head>
  <meta charset="utf-8">
  <title>Test velo_libre_service</title>
  <style>
    body { font-family: sans-serif; margin: 2rem; color: #222; }
    h1 { color: #173; }
    table { border-collapse: collapse; margin-bottom: 1.5rem; }
    th, td { border: 1px solid #bbb; padding: 4px 10px; text-align: left; }
    th { background: #eef6ee; }
  </style>
</head>
<body>
  <h1>Connexion réussie à <?= htmlspecialchars($base) ?></h1>
  <?php
  tableau($pdo, 'Stations',
      "SELECT id_station, nom, adresse, etat_station FROM station");

  tableau($pdo, 'Vélos et leur borne',
      "SELECT v.id_velo, v.type_velo, v.etat_velo, v.niveau_batterie,
              s.nom AS station, b.num_borne
         FROM velo v
         LEFT JOIN borne b   ON b.id_borne = v.id_borne
         LEFT JOIN station s ON s.id_station = b.id_station");

  tableau($pdo, 'Locations (durée et coût calculés par trigger)',
      "SELECT l.id_location, u.prenom, u.nom, l.id_velo,
              l.date_heure_emprunt, l.date_heure_restitution, l.duree_min, l.cout
         FROM location l
         JOIN abonnement a ON a.id_abonnement = l.id_abonnement
         JOIN utilisateur u ON u.id_utilisateur = a.id_utilisateur
        ORDER BY l.date_heure_emprunt");

  tableau($pdo, 'Historique des états',
      "SELECT id_hist_etat, id_velo, date_heure, etat_velo FROM historique_etat ORDER BY id_hist_etat");

  tableau($pdo, 'Signalements',
      "SELECT id_signalement, date_heure, description, statut, id_velo, id_station FROM signalement");
  ?>
</body>
</html>
