<?php

declare(strict_types=1);

namespace App\Controller;

use App\Database\Database;
use App\Repository\BikeRepository;
use App\Repository\RentalRepository;
use App\Repository\ReportRepository;
use App\Repository\StatsRepository;
use App\Repository\SubscriptionRepository;
use App\Security\Auth;
use App\Support\Flash;
use Psr\Http\Message\ResponseInterface as Response;
use Psr\Http\Message\ServerRequestInterface as Request;
use Slim\Views\Twig;

/** Page d'accueil : vitrine pour les visiteurs, tableau de bord selon le rôle sinon. */
final class HomeController extends Controller
{
    public function __construct(
        Twig $view,
        Flash $flash,
        private readonly Database $db,
        private readonly Auth $auth,
        private readonly RentalRepository $rentals,
        private readonly SubscriptionRepository $subscriptions,
        private readonly StatsRepository $stats,
        private readonly BikeRepository $bikes,
        private readonly ReportRepository $reports,
    ) {
        parent::__construct($view, $flash);
    }

    public function index(Request $request, Response $response): Response
    {
        // Chiffres publics du réseau (vue v_stations_occupation, temps réel)
        $data = ['network' => $this->db->fetchOne(
            "SELECT COUNT(*)                               AS stations,
                    COALESCE(SUM(nb_velos_disponibles), 0) AS velos_disponibles,
                    COALESCE(SUM(nb_velos_electriques), 0) AS velos_electriques,
                    COALESCE(SUM(nb_bornes_libres), 0)     AS bornes_libres
               FROM v_stations_occupation
              WHERE etat_station = 'en_service'"
        )];

        if ($this->auth->isUsager()) {
            $id    = (int) $this->auth->id();
            $data += [
                'current'      => $this->rentals->current($id),
                'subscription' => $this->subscriptions->current($id),
                'summary'      => $this->rentals->summary($id),
                'recent'       => $this->rentals->history($id, 1, 3)['rows'],
            ];
        } elseif ($this->auth->isStaff()) {
            $data += [
                'today'     => $this->stats->today(),
                'fleet'     => $this->bikes->countByState(),
                'rebalance' => count($this->stats->stationsToRebalance()),
                'queue'     => $this->reports->search(['statut' => 'ouvert', 'cible' => null], 1, 5)['rows'],
            ];
        }

        return $this->render($response, 'home.twig', $data);
    }
}
