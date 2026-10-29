<?php
require __DIR__ . '/includes/db.php';

function retour(string $cle, string $msg): void
{
    header('Location: fonctionnalites.php?' . $cle . '=' . urlencode($msg));
    exit;
}

/* ============================ TRAITEMENT DES FORMULAIRES ============================ */
if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    try {
        $action = $_POST['action'] ?? '';

        if ($action === 'signalement') {
            $desc = trim($_POST['description'] ?? '');
            [$type, $id] = array_pad(explode(':', $_POST['cible'] ?? ''), 2, null);
            if ($desc === '' || !in_array($type, ['velo', 'station'], true) || !$id) {
                throw new RuntimeException('Description et cible obligatoires.');
            }
            $pdo->prepare("INSERT INTO signalement (description, id_utilisateur, id_velo, id_station)
                           VALUES (?, ?, ?, ?)")
                ->execute([$desc, (int) $_POST['id_utilisateur'],
                           $type === 'velo' ? (int) $id : null,
                           $type === 'station' ? (int) $id : null]);
            retour('ok', 'Signalement enregistré.');
        }

        if ($action === 'emprunt') {
            $pdo->beginTransaction();
            $st = $pdo->prepare("SELECT id_borne FROM velo
                                  WHERE id_velo = ? AND etat_velo = 'disponible' AND id_borne IS NOT NULL FOR UPDATE");
            $st->execute([(int) $_POST['id_velo']]);
            $borne = $st->fetchColumn();
            if (!$borne) {
                throw new RuntimeException("Ce vélo n'est pas disponible.");
            }
            // Les triggers vérifient abonnement actif, vélo libre et usager sans emprunt en cours
            $pdo->prepare("INSERT INTO location (date_heure_emprunt, id_abonnement, id_velo, id_borne_depart)
                           VALUES (NOW(), ?, ?, ?)")
                ->execute([(int) $_POST['id_abonnement'], (int) $_POST['id_velo'], $borne]);
            $pdo->prepare("UPDATE velo SET id_borne = NULL, etat_velo = 'en_location' WHERE id_velo = ?")
                ->execute([(int) $_POST['id_velo']]);
            $pdo->commit();
            retour('ok', 'Emprunt enregistré : le vélo a quitté sa borne (voir les historiques).');
        }

        if ($action === 'restitution') {
            $pdo->beginTransaction();
            $st = $pdo->prepare("SELECT id_velo FROM location WHERE id_location = ? AND date_heure_restitution IS NULL FOR UPDATE");
            $st->execute([(int) $_POST['id_location']]);
            $velo = $st->fetchColumn();
            if (!$velo) {
                throw new RuntimeException('Location introuvable ou déjà terminée.');
            }
            $st = $pdo->prepare("SELECT COUNT(*) FROM velo WHERE id_borne = ?");
            $st->execute([(int) $_POST['id_borne']]);
            if ($st->fetchColumn() > 0) {
                throw new RuntimeException('Cette borne est déjà occupée.');
            }
            // Le trigger calcule duree_min et cout
            $pdo->prepare("UPDATE location SET date_heure_restitution = NOW(), id_borne_arrivee = ? WHERE id_location = ?")
                ->execute([(int) $_POST['id_borne'], (int) $_POST['id_location']]);
            $pdo->prepare("UPDATE velo SET id_borne = ?, etat_velo = 'disponible' WHERE id_velo = ?")
                ->execute([(int) $_POST['id_borne'], $velo]);
            $pdo->commit();
            retour('ok', 'Vélo restitué : durée et coût calculés par le trigger.');
        }
    } catch (Throwable $ex) {
        if ($pdo->inTransaction()) {
            $pdo->rollBack();
        }
        // Les messages des triggers (SIGNAL) sont affichés tels quels
        retour('err', $ex instanceof PDOException ? ($ex->errorInfo[2] ?? $ex->getMessage()) : $ex->getMessage());
    }
}

/* ============================ AFFICHAGE ============================ */
$titre = 'Fonctionnalités';
require __DIR__ . '/includes/header.php';

$k = $pdo->query("SELECT
    (SELECT COUNT(*) FROM station) AS stations,
    (SELECT COUNT(*) FROM velo) AS velos,
    (SELECT COUNT(*) FROM location) AS locations,
    (SELECT COALESCE(SUM(cout), 0) FROM location) AS recettes,
    (SELECT COALESCE(ROUND(AVG(duree_min)), 0) FROM location WHERE duree_min IS NOT NULL) AS duree_moy")->fetch();

$filtre = $_GET['type'] ?? '';
if (!in_array($filtre, ['mecanique', 'electrique'], true)) {
    $filtre = '';
}
?>
  <h1>Fonctionnalités</h1>
  <p><a class="btn secondaire" href="index.php">← Retour aux données</a></p>

  <?php if (isset($_GET['ok'])): ?><div class="msg ok"><?= e($_GET['ok']) ?></div><?php endif; ?>
  <?php if (isset($_GET['err'])): ?><div class="msg err"><?= e($_GET['err']) ?></div><?php endif; ?>

  <div class="kpis">
    <div class="kpi"><b><?= e($k['stations']) ?></b><span>stations</span></div>
    <div class="kpi"><b><?= e($k['velos']) ?></b><span>vélos</span></div>
    <div class="kpi"><b><?= e($k['locations']) ?></b><span>locations</span></div>
    <div class="kpi"><b><?= e(number_format((float) $k['recettes'], 2, ',', ' ')) ?> €</b><span>recettes</span></div>
    <div class="kpi"><b><?= e($k['duree_moy']) ?> min</b><span>durée moyenne</span></div>
  </div>

<?php
tableau($pdo, 'Occupation des stations',
    "SELECT s.nom AS station,
            COUNT(b.id_borne) AS bornes,
            COUNT(v.id_velo) AS bornes_occupees,
            COUNT(b.id_borne) - COUNT(v.id_velo) AS bornes_libres,
            SUM(v.type_velo = 'mecanique') AS mecaniques,
            SUM(v.type_velo = 'electrique') AS electriques
       FROM station s
       LEFT JOIN borne b ON b.id_station = s.id_station
       LEFT JOIN velo v  ON v.id_borne = b.id_borne
      GROUP BY s.id_station, s.nom");
?>

  <section class="carte">
    <h2>Filtrer les vélos</h2>
    <div class="chips">
      <a href="fonctionnalites.php" class="<?= $filtre === '' ? 'actif' : '' ?>">Tous</a>
      <a href="fonctionnalites.php?type=mecanique" class="<?= $filtre === 'mecanique' ? 'actif' : '' ?>">Mécaniques</a>
      <a href="fonctionnalites.php?type=electrique" class="<?= $filtre === 'electrique' ? 'actif' : '' ?>">Électriques</a>
    </div>
  </section>
<?php
tableau($pdo, 'Vélos' . ($filtre ? " ($filtre)" : ''),
    "SELECT v.id_velo, v.type_velo, v.etat_velo, v.niveau_batterie, s.nom AS station
       FROM velo v
       LEFT JOIN borne b   ON b.id_borne = v.id_borne
       LEFT JOIN station s ON s.id_station = b.id_station
      WHERE (? = '' OR v.type_velo = ?)
      ORDER BY v.id_velo", [$filtre, $filtre]);

tableau($pdo, 'Locations en cours',
    "SELECT l.id_location, u.prenom, u.nom, l.id_velo, l.date_heure_emprunt
       FROM location l
       JOIN abonnement a  ON a.id_abonnement = l.id_abonnement
       JOIN utilisateur u ON u.id_utilisateur = a.id_utilisateur
      WHERE l.date_heure_restitution IS NULL");

$abos    = $pdo->query("SELECT a.id_abonnement, u.prenom, u.nom FROM abonnement a
                          JOIN utilisateur u ON u.id_utilisateur = a.id_utilisateur
                         WHERE a.statut = 'actif' ORDER BY u.nom")->fetchAll();
$dispos  = $pdo->query("SELECT v.id_velo, v.type_velo, s.nom AS station FROM velo v
                          JOIN borne b ON b.id_borne = v.id_borne
                          JOIN station s ON s.id_station = b.id_station
                         WHERE v.etat_velo = 'disponible' ORDER BY v.id_velo")->fetchAll();
$encours = $pdo->query("SELECT l.id_location, l.id_velo, u.prenom FROM location l
                          JOIN abonnement a ON a.id_abonnement = l.id_abonnement
                          JOIN utilisateur u ON u.id_utilisateur = a.id_utilisateur
                         WHERE l.date_heure_restitution IS NULL")->fetchAll();
$libres  = $pdo->query("SELECT b.id_borne, b.num_borne, s.nom AS station FROM borne b
                          JOIN station s ON s.id_station = b.id_station
                          LEFT JOIN velo v ON v.id_borne = b.id_borne
                         WHERE v.id_velo IS NULL AND b.etat_borne = 'en_service'
                         ORDER BY s.nom, b.num_borne")->fetchAll();
$users   = $pdo->query("SELECT id_utilisateur, prenom, nom FROM utilisateur ORDER BY nom")->fetchAll();
$velos   = $pdo->query("SELECT id_velo, type_velo FROM velo ORDER BY id_velo")->fetchAll();
$stations = $pdo->query("SELECT id_station, nom FROM station ORDER BY nom")->fetchAll();
?>

  <section class="carte">
    <h2>Emprunter un vélo</h2>
    <form method="post" class="grille">
      <input type="hidden" name="action" value="emprunt">
      <label>Abonné
        <select name="id_abonnement" required>
          <?php foreach ($abos as $a): ?><option value="<?= e($a['id_abonnement']) ?>"><?= e($a['prenom'] . ' ' . $a['nom']) ?></option><?php endforeach; ?>
        </select></label>
      <label>Vélo disponible
        <select name="id_velo" required>
          <?php foreach ($dispos as $d): ?><option value="<?= e($d['id_velo']) ?>">#<?= e($d['id_velo']) ?> <?= e($d['type_velo']) ?> (<?= e($d['station']) ?>)</option><?php endforeach; ?>
        </select></label>
      <button class="btn" type="submit">Emprunter</button>
    </form>
  </section>

  <section class="carte">
    <h2>Restituer un vélo</h2>
    <form method="post" class="grille">
      <input type="hidden" name="action" value="restitution">
      <label>Location en cours
        <select name="id_location" required>
          <?php foreach ($encours as $l): ?><option value="<?= e($l['id_location']) ?>">#<?= e($l['id_location']) ?> : <?= e($l['prenom']) ?>, vélo <?= e($l['id_velo']) ?></option><?php endforeach; ?>
        </select></label>
      <label>Borne d'arrivée
        <select name="id_borne" required>
          <?php foreach ($libres as $b): ?><option value="<?= e($b['id_borne']) ?>"><?= e($b['station']) ?>, borne <?= e($b['num_borne']) ?></option><?php endforeach; ?>
        </select></label>
      <button class="btn" type="submit">Restituer</button>
    </form>
  </section>

  <section class="carte">
    <h2>Créer un signalement</h2>
    <form method="post" class="grille">
      <input type="hidden" name="action" value="signalement">
      <label>Auteur
        <select name="id_utilisateur" required>
          <?php foreach ($users as $u): ?><option value="<?= e($u['id_utilisateur']) ?>"><?= e($u['prenom'] . ' ' . $u['nom']) ?></option><?php endforeach; ?>
        </select></label>
      <label>Concerne
        <select name="cible" required>
          <?php foreach ($velos as $v): ?><option value="velo:<?= e($v['id_velo']) ?>">Vélo #<?= e($v['id_velo']) ?> (<?= e($v['type_velo']) ?>)</option><?php endforeach; ?>
          <?php foreach ($stations as $s): ?><option value="station:<?= e($s['id_station']) ?>">Station <?= e($s['nom']) ?></option><?php endforeach; ?>
        </select></label>
      <label>Description <input name="description" required maxlength="200"></label>
      <button class="btn" type="submit">Envoyer</button>
    </form>
  </section>
<?php
tableau($pdo, 'Derniers signalements',
    "SELECT id_signalement, date_heure, description, statut, id_velo, id_station
       FROM signalement ORDER BY id_signalement DESC LIMIT 5");
tableau($pdo, 'Historique de position des vélos (alimenté par trigger)',
    "SELECT id_hist_pos, id_velo, id_borne, type_position, date_heure_debut, date_heure_fin
       FROM historique_position ORDER BY id_hist_pos DESC LIMIT 10");

require __DIR__ . '/includes/footer.php';
