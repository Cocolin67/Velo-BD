<?php

declare(strict_types=1);

/*
 * Banc de mesure des procédures statistiques (rapport de performances).
 *
 * Usage : php bin/bench-stats.php [--repetitions=5] [--fin=AAAA-MM-JJ]
 *                                 [--periodes=7,30,90,365] [--sortie=var/bench]
 *
 * Chaque procédure est appelée directement (sans le cache de l'application) pour
 * chaque longueur de période se terminant à --fin (exclu). Le premier appel est
 * noté à part (« premier ») : il inclut le chargement des pages en mémoire ;
 * la médiane, le minimum et le maximum portent sur les appels suivants.
 *
 * Fichiers produits (séparateur « , », lisibles par pgfplots) :
 *   - procedures.csv : procedure,jours,premier_s,mediane_s,min_s,max_s,lignes
 *   - echelle.csv    : jours + une colonne de temps médian par statistique
 *                      (même contenu que procedures.csv, une ligne par période)
 *   - contexte.csv   : cle,valeur (versions, configuration InnoDB, volumes) ; le
 *                      rapport lit les valeurs par numéro de ligne : garder l'ordre.
 */

use Dotenv\Dotenv;

$root = dirname(__DIR__);
require $root . '/vendor/autoload.php';
Dotenv::createImmutable($root)->safeLoad();

// Une variable d'environnement déjà définie l'emporte sur .env (Dotenv immuable)
$env = static fn (string $k, string $default = ''): string
    => (string) ($_SERVER[$k] ?? $_ENV[$k] ?? (getenv($k) !== false ? getenv($k) : $default));

$opts        = getopt('', ['repetitions:', 'fin:', 'periodes:', 'sortie:']);
$repetitions = max(2, (int) ($opts['repetitions'] ?? 5));
$fin         = new DateTimeImmutable(($opts['fin'] ?? date('Y-m-d', strtotime('+1 day'))) . ' 00:00:00');
$periodes    = array_map('intval', explode(',', $opts['periodes'] ?? '7,30,90,365'));
$sortie      = $opts['sortie'] ?? $root . '/var/bench';

$pdo = new PDO(
    sprintf('mysql:host=%s;port=%d;dbname=%s;charset=utf8mb4',
        $env('DB_HOST', '127.0.0.1'), (int) $env('DB_PORT', '3307'), $env('DB_NAME', 'velo_libre_service')),
    $env('DB_USER'),
    $env('DB_PASS'),
    [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION],
);

/** Procédures mesurées : nom => paramètres en fonction de la période. */
$procedures = [
    'sp_stat_trajets_par_periode'   => static fn (string $d, string $f): array => [$d, $f, 'jour'],
    'sp_stat_heures_pointe'         => static fn (string $d, string $f): array => [$d, $f],
    'sp_stat_trajets_od'            => static fn (string $d, string $f): array => [$d, $f, 500],
    'sp_stat_remplissage_stations'  => static fn (string $d, string $f): array => [$d, $f],
    'sp_stat_recettes_par_formule'  => static fn (string $d, string $f): array => [$d, $f],
    'sp_stat_indisponibilite_flotte'=> static fn (string $d, string $f): array => [$d, $f],
    // Temps réel : indépendantes de la période (mesurées une fois par période pour comparaison)
    'sp_stations_a_reequilibrer'    => static fn (): array => [0.2, 0.8],
    'sp_proposer_deplacements'      => static fn (): array => [0.2, 0.8],
];

/** Appelle une procédure et renvoie [durée en secondes, nombre de lignes]. */
$call = static function (string $procedure, array $params) use ($pdo): array {
    $sql   = sprintf('CALL %s(%s)', $procedure, implode(', ', array_fill(0, count($params), '?')));
    $start = hrtime(true);
    $stmt  = $pdo->prepare($sql);
    $stmt->execute($params);
    $rows = count($stmt->fetchAll());
    while ($stmt->nextRowset()) {
        // vide les jeux de résultats suivants (statut du CALL)
    }
    $stmt->closeCursor();

    return [(hrtime(true) - $start) / 1e9, $rows];
};

$median = static function (array $v): float {
    sort($v);
    $n = count($v);

    return $n % 2 ? $v[intdiv($n, 2)] : ($v[$n / 2 - 1] + $v[$n / 2]) / 2;
};

if (!is_dir($sortie) && !mkdir($sortie, 0775, true) && !is_dir($sortie)) {
    fwrite(STDERR, "Impossible de créer $sortie\n");
    exit(1);
}

// ---- Contexte de la mesure -------------------------------------------------
// Heure locale (PHP en ligne de commande est en UTC par défaut), sans espace ni « : »
// pour que la valeur reste lisible telle quelle par pgfplots et babel (français).
$maintenant = new DateTimeImmutable('now', new DateTimeZone($env('APP_TIMEZONE', 'Europe/Paris')));
$contexte = [
    'date_mesure'             => $maintenant->format('Y-m-d'),
    'heure_mesure'            => $maintenant->format('H\hi'),
    'fin_periode'             => $fin->format('Y-m-d'),
    'repetitions'             => $repetitions,
    'serveur'                 => $pdo->query('SELECT VERSION()')->fetchColumn(),
    'php'                     => PHP_VERSION,
    'innodb_buffer_pool_mo'   => (int) $pdo->query('SELECT @@innodb_buffer_pool_size')->fetchColumn() / 1048576,
    'taille_base_mo'          => (int) $pdo->query('SELECT ROUND(SUM(data_length + index_length) / 1048576)
                                                     FROM information_schema.TABLES WHERE table_schema = DATABASE()')->fetchColumn(),
];
foreach (['location', 'historique_etat', 'historique_position', 'facture', 'abonnement', 'releve_station', 'velo', 'station'] as $table) {
    $contexte['lignes_' . $table] = (int) $pdo->query("SELECT COUNT(*) FROM `$table`")->fetchColumn();
}

$f = fopen($sortie . '/contexte.csv', 'wb');
fputcsv($f, ['cle', 'valeur'], ',', '"', '');
foreach ($contexte as $k => $v) {
    fputcsv($f, [$k, $v], ',', '"', '');
}
fclose($f);

// ---- Mesures ------------------------------------------------------------------
/** Colonnes de echelle.csv : statistique => nom de colonne */
$colonnesEchelle = [
    'sp_stat_trajets_par_periode'    => 'trajets',
    'sp_stat_heures_pointe'          => 'pointe',
    'sp_stat_trajets_od'             => 'od',
    'sp_stat_remplissage_stations'   => 'remplissage',
    'sp_stat_recettes_par_formule'   => 'recettes',
    'sp_stat_indisponibilite_flotte' => 'indisponibilite',
];
$echelle = [];   // [jours][colonne] => temps médian

$f = fopen($sortie . '/procedures.csv', 'wb');
fputcsv($f, ['procedure', 'jours', 'premier_s', 'mediane_s', 'min_s', 'max_s', 'lignes'], ',', '"', '');

foreach ($periodes as $jours) {
    $debut = $fin->modify("-$jours days")->format('Y-m-d H:i:s');
    $finS  = $fin->format('Y-m-d H:i:s');
    printf("== %d jours (%s -> %s)\n", $jours, substr($debut, 0, 10), substr($finS, 0, 10));

    foreach ($procedures as $procedure => $params) {
        $p = $params($debut, $finS);
        [$premier, $lignes] = $call($procedure, $p);
        $temps = [];
        for ($i = 1; $i < $repetitions; $i++) {
            $temps[] = $call($procedure, $p)[0];
        }
        $row = [$procedure, $jours, round($premier, 3), round($median($temps), 3),
                round(min($temps), 3), round(max($temps), 3), $lignes];
        fputcsv($f, $row, ',', '"', '');
        printf("  %-32s premier %7.3f s  médiane %7.3f s  (%d lignes)\n", $procedure, $row[2], $row[3], $lignes);
        if (isset($colonnesEchelle[$procedure])) {
            $echelle[$jours][$colonnesEchelle[$procedure]] = $row[3];
        }
    }
}
fclose($f);

$f = fopen($sortie . '/echelle.csv', 'wb');
fputcsv($f, ['jours', ...array_values($colonnesEchelle)], ',', '"', '');
ksort($echelle);
foreach ($echelle as $jours => $temps) {
    fputcsv($f, [$jours, ...array_map(static fn (string $c) => $temps[$c], array_values($colonnesEchelle))], ',', '"', '');
}
fclose($f);

echo "Résultats écrits dans $sortie\n";
