<?php

declare(strict_types=1);

/*
 * Diagnostic de la connexion MySQL définie dans .env.
 * Usage : php bin/check-db.php
 * N'affiche jamais le mot de passe.
 */

use Dotenv\Dotenv;

$root = dirname(__DIR__);
require $root . '/vendor/autoload.php';

Dotenv::createImmutable($root)->safeLoad();

$host = $_ENV['DB_HOST'] ?? '127.0.0.1';
$port = (int) ($_ENV['DB_PORT'] ?? 3307);
$name = $_ENV['DB_NAME'] ?? 'velo_libre_service';
$user = $_ENV['DB_USER'] ?? '';
$pass = $_ENV['DB_PASS'] ?? '';

printf("Connexion à %s:%d, base « %s », utilisateur « %s » (mot de passe : %d caractères)\n", $host, $port, $name, $user, strlen($pass));

if ($pass === 'CHANGER_CE_MOT_DE_PASSE') {
    echo "✗ DB_PASS contient encore la valeur par défaut : renseignez le mot de passe de velo_app dans .env.\n";
    exit(1);
}

try {
    $pdo = new PDO("mysql:host=$host;port=$port;dbname=$name;charset=utf8mb4", $user, $pass, [
        PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
    ]);
} catch (PDOException $e) {
    $code = (int) ($e->errorInfo[1] ?? $e->getCode());
    echo '✗ ', $e->getMessage(), "\n\n";
    echo match ($code) {
        1045 => "Le serveur refuse ce couple utilisateur / mot de passe :\n"
              . "  - le mot de passe de DB_PASS ne correspond pas à celui de database/app_user.sql ;\n"
              . "  - ou le compte a été créé sur un autre serveur (script lancé sans -P $port ?).\n"
              . "Relancez : mysql -h $host -P $port -u root -p < database/app_user.sql\n",
        1044 => "Le compte existe mais n'a aucun droit sur « $name » : relancez database/app_user.sql.\n",
        1049 => "La base « $name » n'existe pas sur ce serveur : exécutez d'abord database/schema.sql.\n",
        2002 => "Aucun serveur MySQL ne répond sur $host:$port : vérifiez qu'il est démarré et le port.\n",
        default => "Erreur inattendue (code $code).\n",
    };
    exit(1);
}

echo '✓ Connecté en tant que ', $pdo->query('SELECT CURRENT_USER()')->fetchColumn(),
     ' (MySQL ', $pdo->query('SELECT VERSION()')->fetchColumn(), ")\n";

$checks = [
    'lecture de la vue v_stations_occupation' => 'SELECT COUNT(*) FROM v_stations_occupation',
    'appel d\'une fonction stockée'           => 'SELECT fn_cout_formule(0, \'mecanique\', 0)',
    'stations'                                => 'SELECT COUNT(*) FROM station',
    'locations'                               => 'SELECT COUNT(*) FROM location',
    'comptes de démonstration'                => "SELECT COUNT(*) FROM utilisateur WHERE email LIKE '%@velo.local'",
];
$hints = [
    'stations'                 => 'aucune donnée : exécutez database/seed.sql puis CALL sp_seed_petit();',
    'locations'                => 'aucune donnée : exécutez database/seed.sql puis CALL sp_seed_petit();',
    'comptes de démonstration' => 'exécutez database/demo_accounts.sql pour pouvoir vous connecter',
];
$ok = true;
foreach ($checks as $label => $sql) {
    try {
        $value = $pdo->query($sql)->fetchColumn();
        if (isset($hints[$label])) {
            $missing = (int) $value === 0;
            $ok      = $ok && !$missing;
            printf("%s %s : %s%s\n", $missing ? '✗' : '✓', $label, $value, $missing ? ' → ' . $hints[$label] : '');
            continue;
        }
        printf("✓ %s\n", $label);
    } catch (PDOException $e) {
        $ok = false;
        printf("✗ %s : %s\n", $label, $e->errorInfo[2] ?? $e->getMessage());
    }
}

exit($ok ? 0 : 1);
