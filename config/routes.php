<?php

declare(strict_types=1);

use App\Controller\AuthController;
use App\Controller\HomeController;
use App\Controller\ProfileController;
use App\Controller\RentalController;
use App\Controller\ReportController;
use App\Controller\StationController;
use App\Controller\StatsController;
use App\Controller\SubscriptionController;
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

        $g->get('/stations', [StationController::class, 'index'])->setName('stations');
        $g->get('/stations/{id:[0-9]+}', [StationController::class, 'show'])->setName('stations.show');

        $g->get('/signalements', [ReportController::class, 'index'])->setName('reports');
        $g->post('/signalements', [ReportController::class, 'create'])->setName('reports.create');
    })->add($require());

    // ---- Usagers
    $app->group('', function (RouteCollectorProxy $g): void {
        $g->get('/abonnement', [SubscriptionController::class, 'index'])->setName('subscriptions');
        $g->post('/abonnement', [SubscriptionController::class, 'subscribe'])->setName('subscriptions.subscribe');
        $g->post('/abonnement/{id:[0-9]+}/renouveler', [SubscriptionController::class, 'renew'])->setName('subscriptions.renew');
        $g->post('/abonnement/{id:[0-9]+}/resilier', [SubscriptionController::class, 'cancel'])->setName('subscriptions.cancel');

        $g->get('/trajets', [RentalController::class, 'index'])->setName('rentals');
        $g->post('/trajets/emprunt', [RentalController::class, 'borrow'])->setName('rentals.borrow');
        $g->post('/trajets/retour', [RentalController::class, 'giveBack'])->setName('rentals.return');
    })->add($require([Auth::USAGER]));

    // ---- Opérateurs (et administrateurs, qui en héritent)
    $app->group('', function (RouteCollectorProxy $g): void {
        $g->get('/locations', [RentalController::class, 'admin'])->setName('rentals.admin');
        $g->post('/signalements/{id:[0-9]+}/prise-en-charge', [ReportController::class, 'takeCharge'])->setName('reports.take');
        $g->post('/signalements/{id:[0-9]+}/cloture', [ReportController::class, 'close'])->setName('reports.close');
        $g->get('/statistiques', [StatsController::class, 'index'])->setName('stats');
        $g->get('/statistiques/export/{rapport:[a-z-]+}.csv', [StatsController::class, 'export'])->setName('stats.export');
    })->add($require([Auth::OPERATEUR]));

    // ---- Administrateurs
    $app->group('', function (RouteCollectorProxy $g): void {
        $g->get('/stations/nouvelle', [StationController::class, 'createForm'])->setName('stations.create');
        $g->post('/stations', [StationController::class, 'create'])->setName('stations.store');
        $g->get('/stations/{id:[0-9]+}/modifier', [StationController::class, 'editForm'])->setName('stations.edit');
        $g->post('/stations/{id:[0-9]+}', [StationController::class, 'update'])->setName('stations.update');
        $g->post('/stations/{id:[0-9]+}/supprimer', [StationController::class, 'delete'])->setName('stations.delete');
        $g->post('/stations/{id:[0-9]+}/bornes/{borne:[0-9]+}', [StationController::class, 'borneEtat'])->setName('stations.borne');
    })->add($require([Auth::ADMIN]));
};
