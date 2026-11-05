<?php

declare(strict_types=1);

use App\Controller\AuthController;
use App\Controller\HomeController;
use App\Controller\ProfileController;
use App\Middleware\RequireRole;
use App\Security\Auth;
use App\Support\Flash;
use Psr\Http\Message\ResponseFactoryInterface;
use Slim\App;
use Slim\Routing\RouteCollectorProxy;

return static function (App $app): void {
    $c = $app->getContainer();

    // Contrôle d'accès : $require() = connecté ; $require([rôles]) = rôle exigé
    $require = static fn (array $roles = []): RequireRole => new RequireRole(
        $c->get(Auth::class), $c->get(Flash::class), $c->get(ResponseFactoryInterface::class), $roles,
    );

    // ---- Pages publiques
    $app->get('/', [HomeController::class, 'index'])->setName('home');
    $app->get('/connexion', [AuthController::class, 'loginForm'])->setName('login');
    $app->post('/connexion', [AuthController::class, 'login'])->setName('login.submit');
    $app->get('/inscription', [AuthController::class, 'registerForm'])->setName('register');
    $app->post('/inscription', [AuthController::class, 'register'])->setName('register.submit');

    // ---- Tout utilisateur connecté
    $app->group('', function (RouteCollectorProxy $g): void {
        $g->post('/deconnexion', [AuthController::class, 'logout'])->setName('logout');
        $g->get('/profil', [ProfileController::class, 'show'])->setName('profile');
        $g->post('/profil', [ProfileController::class, 'update'])->setName('profile.update');
        $g->post('/profil/mot-de-passe', [ProfileController::class, 'password'])->setName('profile.password');
    })->add($require());
};
