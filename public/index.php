<?php

declare(strict_types=1);

use DI\ContainerBuilder;
use Dotenv\Dotenv;
use Slim\Factory\AppFactory;

$root = dirname(__DIR__);

require $root . '/vendor/autoload.php';

// Serveur PHP intégré : laisse passer les fichiers statiques (favicon...)
if (PHP_SAPI === 'cli-server' && is_file(__DIR__ . parse_url($_SERVER['REQUEST_URI'], PHP_URL_PATH))) {
    return false;
}

// Configuration (.env non versionné)
$dotenv = Dotenv::createImmutable($root);
$dotenv->safeLoad();
$dotenv->required(['DB_HOST', 'DB_PORT', 'DB_NAME', 'DB_USER', 'DB_PASS']);

$builder = new ContainerBuilder();
$builder->addDefinitions($root . '/config/container.php');
if (($_ENV['APP_ENV'] ?? 'prod') === 'prod') {
    $builder->enableCompilation($root . '/var/cache/di');
}

AppFactory::setContainer($builder->build());
$app = AppFactory::create();

// Sous-dossier (ex. WAMP : http://localhost/velo-bd/public/) : le chemin de base est
// déduit de l'emplacement de index.php ; vide avec `php -S` ou un vhost sur public/.
$basePath = rtrim(str_replace('\\', '/', dirname($_SERVER['SCRIPT_NAME'] ?? '')), '/');
$app->setBasePath($basePath);

(require $root . '/config/middleware.php')($app);
(require $root . '/config/routes.php')($app);

$app->run();
