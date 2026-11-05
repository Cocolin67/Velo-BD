<?php

declare(strict_types=1);

use App\Handler\HttpErrorHandler;
use App\Middleware\SecurityHeadersMiddleware;
use App\Middleware\SessionMiddleware;
use Slim\App;
use Slim\Views\Twig;
use Slim\Views\TwigMiddleware;

/*
 * Slim exécute les middlewares dans l'ordre INVERSE de leur ajout.
 * Ordre d'exécution obtenu :
 *   erreurs → en-têtes de sécurité → Twig → session → routage → route
 * Twig et la session sont prêts avant le routage, donc disponibles aussi pour
 * les pages d'erreur 404 / 405.
 */
return static function (App $app): void {
    $container = $app->getContainer();
    $settings  = $container->get('settings');

    $app->addRoutingMiddleware();
    $app->add(new SessionMiddleware($settings['session']));
    $app->add(TwigMiddleware::create($app, $container->get(Twig::class)));
    $app->add(new SecurityHeadersMiddleware());

    $debug  = $settings['app']['debug'];
    $errors = $app->addErrorMiddleware($debug, true, $debug);
    $errors->setDefaultErrorHandler($container->get(HttpErrorHandler::class));
};
