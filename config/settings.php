<?php

declare(strict_types=1);

// Paramètres lus depuis l'environnement (.env chargé par public/index.php)
$env   = $_ENV['APP_ENV'] ?? 'prod';
$debug = filter_var($_ENV['APP_DEBUG'] ?? false, FILTER_VALIDATE_BOOL);

return [
    'app' => [
        'name'  => 'Vélo libre-service',
        'env'   => $env,
        'debug' => $debug,
        'root'  => dirname(__DIR__),
    ],
    'db' => [
        'host' => $_ENV['DB_HOST'] ?? '127.0.0.1',
        'port' => (int) ($_ENV['DB_PORT'] ?? 3307),
        'name' => $_ENV['DB_NAME'] ?? 'velo_libre_service',
        'user' => $_ENV['DB_USER'] ?? '',
        'pass' => $_ENV['DB_PASS'] ?? '',
    ],
    'twig' => [
        'path'  => dirname(__DIR__) . '/templates',
        // Cache compilé uniquement en production (rechargement immédiat en dev)
        'cache' => $env === 'prod' ? dirname(__DIR__) . '/var/cache/twig' : false,
    ],
    'session' => [
        'name'     => 'velo_session',
        'lifetime' => 0,          // cookie de session (supprimé à la fermeture du navigateur)
        'idle'     => 3600,       // déconnexion après 1 h d'inactivité
    ],
    'pagination' => [
        'per_page' => 20,
    ],
];
